import Foundation
import Observation

enum DeviceMode: String, CaseIterable, Sendable {
    case demo
    case live

    var displayName: String {
        switch self {
        case .demo: return "Demo 模式"
        case .live: return "實機連線"
        }
    }
}

/// UI 的唯一資料來源。負責訂閱 backend 的事件流並轉成可觀察狀態。
///
/// 所有屬性都是 `private(set)` —— View 只能透過方法修改，避免 UI 直接改寫
/// 「裝置回報的事實」而造成畫面與實際狀態不一致。
@MainActor
@Observable
final class ToiletController {
    private(set) var mode: DeviceMode = .demo
    private(set) var state: ToiletState = .offline
    private(set) var connection: ConnectionStatus = .disconnected
    private(set) var settings = DeviceSettings()
    /// 最近一次沖水。從活動紀錄推導，而不是直接用裝置送來的字串。
    ///
    /// 裝置送的是「裝置所在時區的牆上時間」（例如 "2026-08-23 22:28:59 手動"），
    /// 手機若在其他時區就會顯示錯誤的時間。活動紀錄裡存的是絕對時間，
    /// 顯示時會依手機自己的時區正確換算。
    var lastFlush: ActivityEntry? {
        activity.entries.first(where: \.isFlush)
    }

    private(set) var diagnostics = Diagnostics()
    private(set) var schedule = FlushSchedule()
    /// 白白的使用紀錄。只放真正發生在裝置上的事件（使用、沖水），會持久化並保留兩週。
    let activity = ActivityStore()

    /// 技術訊息（Demo 模式提示、送出失敗、排程已更新…）。
    ///
    /// 刻意與 `activity` 分開且**不持久化**：這些訊息每次啟動都會重複產生，
    /// 混進兩週的使用紀錄裡只會把它洗成雜訊。只在診斷區塊顯示。
    private(set) var notices: [String] = []

    private(set) var isLoadingHistory = false

    private(set) var credentials = CredentialStore.load()

    private var backend: (any DeviceBackend)?
    private var pump: Task<Void, Never>?
    private var scheduleDebounce: Task<Void, Never>?

    /// 連線後回填「目前值」的期間。這段期間收到的訊息是快照而不是剛發生的事件，
    /// 不可以記進活動紀錄。
    private var isSyncing = false

    /// 從背景回到前景時呼叫。
    ///
    /// iOS 會在 App 進背景後很快掛起行程，WebSocket 因此中斷，而排在
    /// `scheduleReconnect()` 裡的重試 Task 在掛起期間也不會執行。回前景時主動
    /// 重建連線，比等待那個 Task 自己醒來快得多。
    func resumeIfNeeded() async {
        guard mode == .live else { return }
        if connection.isConnected {
            await loadHistory()
        } else {
            await start(mode: mode)
        }
    }

    /// 使用者上次選擇的模式。有設定憑證就預設連實機，否則走 Demo。
    var preferredMode: DeviceMode {
        credentials.isComplete ? .live : .demo
    }

    func saveCredentials(_ new: Credentials) async {
        credentials = new
        CredentialStore.save(new)
        await start(mode: new.isComplete ? .live : .demo)
    }

    func clearCredentials() async {
        CredentialStore.clear()
        credentials = CredentialStore.load()
        await start(mode: .demo)
    }

    // MARK: - 生命週期

    func start(mode: DeviceMode) async {
        await stop()
        self.mode = mode

        let backend: any DeviceBackend
        switch mode {
        case .demo:
            backend = SimulatedDevice()
        case .live:
            guard credentials.isComplete else {
                // 沒有憑證就連不上，退回 Demo 比讓畫面永遠卡在「連線中」好
                note("尚未設定 Adafruit IO 帳號，改用 Demo 模式")
                self.mode = .demo
                backend = SimulatedDevice()
                break
            }
            backend = MQTTDevice(credentials: credentials)
        }
        self.backend = backend

        pump = Task { [weak self] in
            for await event in backend.events {
                guard let self else { return }
                self.apply(event)
            }
        }
        await backend.start()
    }

    func stop() async {
        pump?.cancel()
        pump = nil
        if let backend { await backend.stop() }
        backend = nil
    }

    // MARK: - 指令

    func flushNow() {
        guard let backend else { return }
        Task { await backend.flushNow() }
    }

    func triggerOTA() {
        guard let backend else { return }
        Task { await backend.triggerOTA() }
    }

    /// 滑桿拖曳時只更新本地值，放開才送出 —— 否則每移動一格就發一次 MQTT，
    /// 會瞬間吃光 Adafruit IO 免費版每分鐘 30 筆的配額。
    func previewEntryThreshold(_ v: Int)    { settings.entryThreshold = DeviceSettings.clampEntry(v) }
    func previewExitThreshold(_ v: Int)     { settings.exitThreshold = DeviceSettings.clampExit(v) }
    func previewFlushDuration(_ v: Int)     { settings.flushDuration = DeviceSettings.clampDuration(v) }

    func commitEntryThreshold() {
        guard let backend else { return }
        let v = settings.entryThreshold
        Task { await backend.setEntryThreshold(v) }
    }

    func commitExitThreshold() {
        guard let backend else { return }
        let v = settings.exitThreshold
        Task { await backend.setExitThreshold(v) }
    }

    func commitFlushDuration() {
        guard let backend else { return }
        let v = settings.flushDuration
        Task { await backend.setFlushDuration(v) }
    }

    // MARK: - 定時清洗
    //
    // 排程的每次修改都會整包送出（啟用狀態 + 時長 + 所有時間點），因為韌體端
    // 是用單一 feed 存整份 JSON —— Adafruit IO 免費版只有 10 個 feed，沒有額度
    // 讓每個時間點各佔一個。

    func setScheduleEnabled(_ on: Bool) {
        schedule.enabled = on
        pushSchedule()
    }

    func setScheduleDuration(_ seconds: Int) {
        schedule.durationSeconds = FlushSchedule.clampDuration(seconds)
    }

    func addScheduleTime() {
        guard schedule.times.count < FlushSchedule.maxEntries else { return }
        schedule.times.append(ScheduledTime(hour: 12, minute: 0))
        schedule.times.sort()
        pushSchedule()
    }

    func updateScheduleTime(id: UUID, hour: Int, minute: Int) {
        guard let i = schedule.times.firstIndex(where: { $0.id == id }) else { return }
        schedule.times[i].hour = hour
        schedule.times[i].minute = minute
    }

    func removeScheduleTimes(at offsets: IndexSet) {
        schedule.times.remove(atOffsets: offsets)
        pushSchedule()
    }

    func pushSchedule() {
        guard let backend else { return }
        scheduleDebounce?.cancel()
        scheduleDebounce = nil
        schedule.times.sort()
        let s = schedule
        Task { await backend.setSchedule(s) }
    }

    /// DatePicker 的滾輪在拖曳過程會連續回報新值，沒有「結束編輯」的回呼可用。
    /// 直接每次都送會在幾秒內打出數十筆 MQTT —— Adafruit IO 免費版每分鐘只有
    /// 30 筆配額，會被限流。這裡等使用者停手 1 秒才真正送出。
    func pushScheduleDebounced() {
        scheduleDebounce?.cancel()
        scheduleDebounce = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            self.pushSchedule()
        }
    }

    // MARK: - 事件套用

    private func apply(_ event: DeviceEvent) {
        switch event {
        case .connection(let c):
            connection = c
            // 連線狀態刻意不寫進活動紀錄。這裡是「白白的使用紀錄」而不是技術日誌，
            // 而手機休眠、切換網路都會造成正常的斷線重連 —— 記進去只是把兩週的
            // 紀錄洗成一堆雜訊。目前的連線狀態在狀態卡片上已經看得到。
            //
            // 一連上就把歷史補齊，不必等使用者手動下拉刷新
            if c.isConnected { Task { await loadHistory() } }
        case .syncing(let syncing):
            isSyncing = syncing

        case .state(let s):
            // 只記錄真正有意義的狀態。idle / cooldown 是流程雜訊，
            // flushing 則會與 last-flush 的紀錄重複。
            // 訊息文字必須與 AdafruitHistory 產生的完全一致，否則去重會失效。
            if s != state, s == .inuse, !isSyncing { append("白白開始使用") }
            state = s
        case .entryThreshold(let v):
            settings.entryThreshold = v
        case .exitThreshold(let v):
            settings.exitThreshold = v
        case .flushDuration(let v):
            settings.flushDuration = v
        case .lastFlush(let t):
            // 回填期間收到的是「上次沖水」的舊值快照，不是剛發生的沖水。
            // 少了這個判斷，每次開 App 都會多記一筆假的沖水紀錄，
            // 而且時間是 App 開啟的時間而非實際沖水時間。
            guard !isSyncing else { break }
            // 值的格式是 "2026-08-23 22:28:59 手動"，只取最後一段當觸發來源。
            // 前面的時間戳刻意不用 —— 那是裝置所在時區的牆上時間，沒有時區資訊。
            // 這則訊息是即時收到的，用當下時間當絕對時間戳更準確也更好換算。
            let reason = t.split(separator: " ").last.map(String.init) ?? "未知"
            append("\(ActivityEntry.flushPrefix)（\(reason)）")
        case .diagnostics(let d):
            diagnostics = d
        case .schedule(let s):
            schedule = s
        case .log(let m):
            note(m)
        }
    }

    /// 寫進持久化的使用紀錄。只有真正發生在裝置上的事件該走這裡。
    private func append(_ message: String) {
        activity.append(message)
    }

    /// 記一則技術訊息。純記憶體、不持久化。
    private func note(_ message: String) {
        notices.insert(message, at: 0)
        if notices.count > 20 { notices.removeLast(notices.count - 20) }
    }

    // MARK: - 活動紀錄

    /// 從 Adafruit IO 回填過去兩週的歷史。
    ///
    /// MQTT 只收得到訂閱之後的事件，而狗狗上廁所時使用者不會正好開著 App ——
    /// 沒有這一步，活動紀錄裡幾乎不會有東西。
    func loadHistory() async {
        guard mode == .live, credentials.isComplete else { return }
        isLoadingHistory = true
        defer { isLoadingHistory = false }
        let fetched = await AdafruitHistory(credentials: credentials).fetch(days: 14)
        activity.merge(fetched)
    }

    func clearActivity() {
        activity.clear()
    }
}
