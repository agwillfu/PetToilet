import Foundation
import Observation

/// 活動紀錄的一筆事件。
///
/// `id` 對雲端來的紀錄是 Adafruit IO 的 data point id（ULID），對 App 自己產生的
/// 訊息則是 UUID。用它來去重 —— 每次回填歷史時會與既有紀錄大量重疊。
struct ActivityEntry: Identifiable, Codable, Sendable, Equatable {
    let id: String
    let date: Date
    let message: String
    let isFromDevice: Bool

    init(id: String = UUID().uuidString, date: Date = Date(),
         message: String, isFromDevice: Bool = false) {
        self.id = id
        self.date = date
        self.message = message
        self.isFromDevice = isFromDevice
    }

    static let flushPrefix = "沖水完成"

    var isFlush: Bool { message.hasPrefix(Self.flushPrefix) }

    /// 從「沖水完成（手動）」取出「手動」。
    var flushReason: String? {
        guard isFlush,
              let open = message.firstIndex(of: "（"),
              let close = message.lastIndex(of: "）"),
              open < close
        else { return nil }
        return String(message[message.index(after: open)..<close])
    }
}

/// 活動紀錄的儲存與保留策略。
///
/// 為什麼需要持久化：原本紀錄只存在記憶體，App 一關就全部消失。
/// 為什麼還要從雲端回填：狗狗上廁所時使用者不會正好開著 App，只記錄
/// 「App 觀察到的事件」的話，兩週的紀錄裡幾乎不會有東西。真正的歷史在
/// Adafruit IO 的 feed 上（免費版保留 30 天）。
@MainActor
@Observable
final class ActivityStore {
    private(set) var entries: [ActivityEntry] = []

    /// 「清除紀錄」的實作方式：記下清除當下的時間，早於它的紀錄一律不顯示。
    ///
    /// 不能真的刪掉就算了 —— 紀錄是從雲端回填的，下次同步又會全部回來。
    /// 也刻意不去刪 Adafruit IO 上的資料：那是裝置的原始紀錄，不該被 App 的
    /// 一個按鈕破壞。
    private(set) var clearedBefore: Date?

    static let retention: TimeInterval = 14 * 24 * 60 * 60

    private let fileURL: URL
    private let clearedKey = "PetToilet.activityClearedBefore"

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("activity-log.json")
        if let t = UserDefaults.standard.object(forKey: clearedKey) as? Date {
            clearedBefore = t
        }
        load()
    }

    // MARK: - 變更

    /// 合併從雲端撈回來的紀錄。
    ///
    /// 去重分兩層：
    ///   1. 依 id —— 每次回填都會與既有的雲端紀錄大量重疊
    ///   2. 依「訊息相同且時間接近」—— 同一個事件可能已經透過 MQTT 即時記錄過
    ///      一次（本機 UUID），現在又從 REST 撈回來一次（Adafruit IO 的 id）。
    ///      兩者 id 不同，只能靠內容比對。以雲端版本為準。
    func merge(_ incoming: [ActivityEntry]) {
        guard !incoming.isEmpty else { return }

        var byId = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for e in incoming { byId[e.id] = e }

        let incomingIds = Set(incoming.map(\.id))
        let deduped = byId.values.filter { existing in
            guard !existing.isFromDevice, !incomingIds.contains(existing.id) else { return true }
            // 本機紀錄若在雲端有對應事件（同訊息、15 秒內），就丟掉本機那筆
            return !incoming.contains { remote in
                remote.message == existing.message &&
                abs(remote.date.timeIntervalSince(existing.date)) < 15
            }
        }

        entries = Array(deduped)
        prune()
        save()
    }

    func append(_ message: String) {
        entries.append(ActivityEntry(message: message))
        prune()
        save()
    }

    func clear() {
        let now = Date()
        clearedBefore = now
        UserDefaults.standard.set(now, forKey: clearedKey)
        entries.removeAll()
        save()
    }

    /// 保留期外的紀錄一律丟棄。上限同時擋筆數，避免裝置異常狂送訊息時把檔案撐爆。
    private func prune() {
        let cutoff = max(Date().addingTimeInterval(-Self.retention),
                         clearedBefore ?? .distantPast)
        entries = entries
            .filter { $0.date > cutoff }
            .sorted { $0.date > $1.date }
        if entries.count > 2000 { entries.removeLast(entries.count - 2000) }
    }

    // MARK: - 持久化

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([ActivityEntry].self, from: data)
        else { return }
        entries = decoded
        prune()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
