import Foundation

/// 不需要任何硬體或網路的模擬裝置。
///
/// 它完整重現韌體的狀態機（含防誤觸與沖水後靜置），並且會週期性地自己「製造」
/// 一次狗狗如廁事件，讓使用者不必等真的有狗狗上廁所也能看到完整流程。
///
/// 這是 App Store 送審的關鍵：審查員手上沒有這台尿盆，Demo 模式讓他們能實際
/// 操作每一個功能，而不是對著「連線中…」的轉圈畫面。
actor SimulatedDevice: DeviceBackend {
    nonisolated let events: AsyncStream<DeviceEvent>
    private let emit: AsyncStream<DeviceEvent>.Continuation

    private var loop: Task<Void, Never>?
    private var state: ToiletState = .idle
    private var settings = DeviceSettings()
    private var schedule = FlushSchedule()

    /// 這次沖水要跑幾秒。排程清洗與日常沖水的長度不同，不能共用 settings。
    private var activeFlushSeconds: Int = 10
    private var activeFlushReason: String = "自動"
    private var lastScheduleRunMinute: Int?

    private var elapsedInState: Double = 0
    private var secondsUntilNextVisit: Double = 12   // 開啟後很快就有第一次，不讓人乾等
    private var visitDuration: Double = 0
    private var uptime: Int = 0
    private var tickCount: Int = 0

    private let tick: Double = 0.5

    init() {
        (events, emit) = AsyncStream<DeviceEvent>.makeStream(bufferingPolicy: .bufferingNewest(64))
        // 預先帶一份實際的排程設定。空白的設定畫面看起來像壞掉的功能，
        // 對 App Store 審查員尤其不利 —— 他們沒有硬體，只能從畫面判斷功能是否完整。
        schedule.enabled = true
        schedule.durationSeconds = 120
        schedule.times = [
            ScheduledTime(hour: 8,  minute: 0),
            ScheduledTime(hour: 14, minute: 0),
            ScheduledTime(hour: 20, minute: 0),
        ]
    }

    func start() {
        guard loop == nil else { return }
        emit.yield(.connection(.connecting))
        emit.yield(.log("Demo 模式：使用模擬裝置，不會連上任何伺服器"))

        loop = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))   // 假裝在連線，讓 UI 轉場自然
            guard let self else { return }
            await self.didConnect()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                if Task.isCancelled { break }
                await self.advance()
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        state = .offline
        emit.yield(.state(.offline))
        emit.yield(.connection(.disconnected))
    }

    private func didConnect() {
        emit.yield(.connection(.connected))
        // 與 MQTTDevice 一致：這一段送的是「目前值快照」而不是剛發生的事件
        emit.yield(.syncing(true))
        emit.yield(.state(state))
        emit.yield(.entryThreshold(settings.entryThreshold))
        emit.yield(.exitThreshold(settings.exitThreshold))
        emit.yield(.flushDuration(settings.flushDuration))
        emit.yield(.schedule(schedule))
        emitDiagnostics()
        emit.yield(.syncing(false))
    }

    /// 與韌體一致：時間到但狗狗正在使用時不沖水（此處直接跳過，不做延後 ——
    /// Demo 的目的是展示行為，不需要完整重現延後佇列）。
    private func checkSchedule() {
        guard schedule.enabled, !schedule.times.isEmpty else { return }
        let c = Calendar.current.dateComponents([.hour, .minute, .second], from: Date())
        guard let h = c.hour, let m = c.minute, let sec = c.second, sec < 20 else { return }
        let nowMinute = h * 60 + m
        guard lastScheduleRunMinute != nowMinute else { return }
        guard schedule.times.contains(where: { $0.minuteOfDay == nowMinute }) else { return }
        guard state == .idle else { return }

        lastScheduleRunMinute = nowMinute
        emit.yield(.log("定時清洗（\(schedule.durationDescription)）"))
        activeFlushSeconds = schedule.durationSeconds
        activeFlushReason  = "排程"
        enter(.flushing)
    }

    // MARK: - 指令

    func flushNow() {
        guard state.acceptsManualFlush else {
            emit.yield(.log("目前狀態為「\(state.displayName)」，忽略手動沖水"))
            return
        }
        emit.yield(.log("手動沖水"))
        activeFlushSeconds = settings.flushDuration
        activeFlushReason  = "手動"
        enter(.flushing)
    }

    func setEntryThreshold(_ seconds: Int) {
        settings.entryThreshold = DeviceSettings.clampEntry(seconds)
        emit.yield(.entryThreshold(settings.entryThreshold))
    }

    func setExitThreshold(_ seconds: Int) {
        settings.exitThreshold = DeviceSettings.clampExit(seconds)
        emit.yield(.exitThreshold(settings.exitThreshold))
    }

    func setFlushDuration(_ seconds: Int) {
        settings.flushDuration = DeviceSettings.clampDuration(seconds)
        emit.yield(.flushDuration(settings.flushDuration))
    }

    func setSchedule(_ newValue: FlushSchedule) {
        var s = newValue
        s.durationSeconds = FlushSchedule.clampDuration(s.durationSeconds)
        s.times = Array(s.times.sorted().prefix(FlushSchedule.maxEntries))
        schedule = s
        emit.yield(.schedule(s))
        emit.yield(.log("排程已更新：\(s.summary)"))
    }

    func triggerOTA() {
        emit.yield(.log("Demo 模式不會真的更新韌體"))
        enter(.ota)
    }

    // MARK: - 狀態機

    private func enter(_ next: ToiletState) {
        state = next
        elapsedInState = 0
        emit.yield(.state(next))
    }

    private func advance() {
        elapsedInState += tick
        tickCount += 1
        uptime = tickCount / 2

        switch state {
        case .idle:
            checkSchedule()
            guard state == .idle else { break }      // checkSchedule 可能已經開始沖水
            secondsUntilNextVisit -= tick
            if secondsUntilNextVisit <= 0 {
                // 每次造訪停留時間不同，讓 demo 看起來像真的
                visitDuration = Double.random(in: 8...20)
                enter(.detecting)
            }

        case .detecting:
            if elapsedInState >= Double(settings.entryThreshold) {
                enter(.inuse)
            }

        case .inuse:
            if elapsedInState >= visitDuration {
                // 狗狗離開後還要再等 exitThreshold 秒才確定，這裡直接併入沖水前的等待
                activeFlushSeconds = settings.flushDuration
                activeFlushReason  = "自動"
                enter(.flushing)
            }

        case .flushing:
            if elapsedInState >= Double(activeFlushSeconds) {
                // 格式必須與韌體一致（"時間戳 觸發來源"），否則 App 端解析出來的
                // 觸發來源會變成時間字串。
                emit.yield(.lastFlush("\(Self.timestamp()) \(activeFlushReason)"))
                enter(.cooldown)
            }

        case .cooldown:
            if elapsedInState >= 8 {
                secondsUntilNextVisit = Double.random(in: 45...110)
                enter(.idle)
            }

        case .ota:
            if elapsedInState >= 6 {
                emit.yield(.log("Demo 更新完成"))
                enter(.idle)
            }

        case .offline, .unknown:
            break
        }

        if tickCount % 60 == 0 { emitDiagnostics() }   // 每 30 秒
    }

    private func emitDiagnostics() {
        var d = Diagnostics()
        d.firmwareVersion = "0.1.3-demo"
        d.freeHeap        = Int.random(in: 32100...32500)
        d.maxFreeBlock    = 32256
        d.fragmentation   = 1
        d.rssi            = Int.random(in: -62 ... -54)
        d.uptimeSeconds   = uptime
        d.mflnActive      = true
        d.ipAddress       = "10.20.30.181"
        emit.yield(.diagnostics(d))
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: Date())
    }
}
