import Foundation

/// 透過 Adafruit IO 連上真實裝置。
///
/// Topic 格式是 Adafruit IO 固定的 `<username>/feeds/<key>`。
/// Feed key 必須與韌體 PetToilet.ino 裡的 F_* 巨集完全一致。
actor MQTTDevice: DeviceBackend {

    nonisolated let events: AsyncStream<DeviceEvent>
    private let emit: AsyncStream<DeviceEvent>.Continuation

    private let credentials: Credentials
    private let client = MQTTWebSocketClient()
    private var pump: Task<Void, Never>?
    private var reconnect: Task<Void, Never>?
    private var stopped = false

    /// 還在等 `/get` 回應的 feed。空了（或逾時）就結束回填階段。
    private var pendingPrimes: Set<String> = []
    private var primeTimeout: Task<Void, Never>?
    private var hasFinishedPriming = true

    private static let host = "io.adafruit.com"

    private enum Feed {
        static let state     = "state"
        static let flush     = "flush"
        static let entry     = "entry-threshold"
        static let exit      = "exit-threshold"
        static let duration  = "flush-duration"
        static let lastFlush = "last-flush"
        static let schedule  = "schedule"
        static let ota       = "ota"
        static let diag      = "diag"
    }

    init(credentials: Credentials) {
        self.credentials = credentials
        (events, emit) = AsyncStream<DeviceEvent>.makeStream(bufferingPolicy: .bufferingNewest(128))
    }

    private func topic(_ feed: String) -> String { "\(credentials.username)/feeds/\(feed)" }
    private func getTopic(_ feed: String) -> String { "\(credentials.username)/feeds/\(feed)/get" }

    // MARK: - 生命週期

    func start() async {
        stopped = false
        startEventPump()
        await attemptConnect()
    }

    func stop() async {
        stopped = true
        reconnect?.cancel(); reconnect = nil
        pump?.cancel();      pump = nil
        await client.disconnect()
        emit.yield(.state(.offline))
        emit.yield(.connection(.disconnected))
    }

    private func startEventPump() {
        guard pump == nil else { return }
        pump = Task { [weak self] in
            guard let self else { return }
            for await event in self.client.events {
                await self.handle(event)
            }
        }
    }

    private func attemptConnect() async {
        emit.yield(.connection(.connecting))
        do {
            // client id 每次連線都不同：Adafruit IO 對同一個 client id 的重複連線
            // 會踢掉前一條，App 前景/背景切換時容易自己踢自己。
            let clientId = "pettoilet-ios-\(UUID().uuidString.prefix(8))"
            try await client.connect(host: Self.host,
                                     clientId: clientId,
                                     username: credentials.username,
                                     password: credentials.key)
        } catch {
            let message = (error as? MQTTError)?.errorDescription ?? error.localizedDescription
            emit.yield(.connection(.failed(message)))
            scheduleReconnect()
        }
    }

    private func scheduleReconnect() {
        guard !stopped else { return }
        reconnect?.cancel()
        reconnect = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self, await !self.stopped else { return }
            await self.attemptConnect()
        }
    }

    // MARK: - 傳輸事件

    private func handle(_ event: MQTTWebSocketClient.Event) async {
        switch event {
        case .connected:
            emit.yield(.connection(.connected))
            hasFinishedPriming = false
            await subscribeAll()
            await requestCurrentValues()

        case .message(let topic, let payload):
            apply(topic: topic, payload: payload)

        case .disconnected:
            finishPriming()
            // 已建立過的連線中斷，多半是手機休眠或切換網路造成的，而且我們馬上就會
            // 自動重連。顯示成「連線失敗」會讓使用者以為出了問題 —— 用「連線中」
            // 才符合實際發生的事。真正的失敗（例如帳密錯誤）由 attemptConnect() 回報。
            emit.yield(.connection(.connecting))
            emit.yield(.state(.offline))
            scheduleReconnect()
        }
    }

    private func subscribeAll() async {
        let topics = [Feed.state, Feed.entry, Feed.exit, Feed.duration,
                      Feed.lastFlush, Feed.schedule, Feed.diag].map(topic)
        do { try await client.subscribe(topics) }
        catch { emit.yield(.log("訂閱失敗：\(error.localizedDescription)")) }
    }

    /// Adafruit IO 不支援 MQTT 的 retain flag，所以訂閱後不會自動收到目前的值。
    /// 對 `<feed>/get` 發一則空訊息，broker 會把最後一筆值推回來。
    ///
    /// 這些回應在 MQTT 上與「剛發生的事件」無法區分，所以整段期間用 `.syncing(true)`
    /// 標示，讓上層知道收到的是快照而不是事件。
    private func requestCurrentValues() async {
        let feeds = [Feed.state, Feed.entry, Feed.exit, Feed.duration,
                     Feed.lastFlush, Feed.schedule, Feed.diag]
        pendingPrimes = Set(feeds)
        emit.yield(.syncing(true))

        for feed in feeds {
            try? await client.publish(topic: getTopic(feed), payload: "", qos: 0)
        }

        // 沒有資料的 feed 不會回應 /get，光等回應會永遠等不完，必須有逾時。
        primeTimeout?.cancel()
        primeTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            await self?.finishPriming()
        }
    }

    private func markPrimed(_ feed: String) {
        guard !pendingPrimes.isEmpty else { return }
        pendingPrimes.remove(feed)
        if pendingPrimes.isEmpty { finishPriming() }
    }

    private func finishPriming() {
        guard !hasFinishedPriming else { return }
        hasFinishedPriming = true
        pendingPrimes.removeAll()
        primeTimeout?.cancel()
        primeTimeout = nil
        emit.yield(.syncing(false))
    }

    private func apply(topic: String, payload: String) {
        guard let feed = topic.split(separator: "/").last.map(String.init) else { return }
        markPrimed(feed)
        switch feed {
        case Feed.state:
            emit.yield(.state(ToiletState(rawValueOrUnknown: payload)))
        case Feed.entry:
            if let v = Int(payload) { emit.yield(.entryThreshold(v)) }
        case Feed.exit:
            if let v = Int(payload) { emit.yield(.exitThreshold(v)) }
        case Feed.duration:
            if let v = Int(payload) { emit.yield(.flushDuration(v)) }
        case Feed.lastFlush:
            emit.yield(.lastFlush(payload))
        case Feed.schedule:
            if let s = FlushSchedule(json: payload) { emit.yield(.schedule(s)) }
        case Feed.diag:
            if let data = payload.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                emit.yield(.diagnostics(Diagnostics(json: obj)))
            }
        default:
            break
        }
    }

    // MARK: - 指令

    private func publish(_ feed: String, _ value: String) async {
        do { try await client.publish(topic: topic(feed), payload: value) }
        catch { emit.yield(.log("送出失敗：\(error.localizedDescription)")) }
    }

    func flushNow() async                     { await publish(Feed.flush, "1") }
    func setEntryThreshold(_ s: Int) async    { await publish(Feed.entry, String(s)) }
    func setExitThreshold(_ s: Int) async     { await publish(Feed.exit, String(s)) }
    func setFlushDuration(_ s: Int) async     { await publish(Feed.duration, String(s)) }
    func setSchedule(_ s: FlushSchedule) async { await publish(Feed.schedule, s.jsonPayload()) }

    func triggerOTA() async {
        await publish(Feed.ota, "1")
        emit.yield(.log("已送出更新指令，裝置將開啟 5 分鐘的更新視窗"))
    }
}
