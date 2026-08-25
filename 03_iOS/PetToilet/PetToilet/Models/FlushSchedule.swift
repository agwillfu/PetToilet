import Foundation

/// 一個排定的清洗時刻。
///
/// 用 hour/minute 而非 Date 儲存 —— 這是「每天的某個時刻」，不是某個絕對時間點。
/// 存成 Date 會在跨日、跨時區、日光節約時間時產生錯誤的語意。
struct ScheduledTime: Sendable, Equatable, Identifiable, Comparable {
    let id: UUID
    var hour: Int
    var minute: Int

    init(id: UUID = UUID(), hour: Int, minute: Int) {
        self.id = id
        self.hour = min(max(hour, 0), 23)
        self.minute = min(max(minute, 0), 59)
    }

    init?(hhmm: String) {
        let parts = hhmm.split(separator: ":")
        guard parts.count == 2,
              let h = Int(parts[0]), let m = Int(parts[1]),
              (0...23).contains(h), (0...59).contains(m) else { return nil }
        self.init(hour: h, minute: m)
    }

    var hhmm: String { String(format: "%02d:%02d", hour, minute) }

    var minuteOfDay: Int { hour * 60 + minute }

    static func < (a: ScheduledTime, b: ScheduledTime) -> Bool {
        a.minuteOfDay < b.minuteOfDay
    }

    /// 給 DatePicker 用的橋接。日期部分無意義，只取時分。
    var asDate: Date {
        Calendar.current.date(from: DateComponents(hour: hour, minute: minute)) ?? Date()
    }

    static func from(date: Date) -> (hour: Int, minute: Int) {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0, c.minute ?? 0)
    }
}

/// 定時清洗設定。與韌體的 `schedule` feed 共用同一份 JSON 格式：
///
///     {"on":true,"dur":120,"times":["08:00","14:00","20:00"]}
struct FlushSchedule: Sendable, Equatable {
    var enabled: Bool = false
    var durationSeconds: Int = 120
    var times: [ScheduledTime] = []

    static let maxEntries = 6
    static let durationRange = 10...300

    /// 排程用的時間長度跟「狗狗用完後沖水」是分開的參數。共用一個的話，
    /// 把清洗設成兩分鐘會連帶讓每次狗狗上完廁所都沖兩分鐘。
    static func clampDuration(_ v: Int) -> Int {
        min(max(v, durationRange.lowerBound), durationRange.upperBound)
    }

    var durationDescription: String {
        let m = durationSeconds / 60, s = durationSeconds % 60
        if m > 0 && s > 0 { return "\(m) 分 \(s) 秒" }
        if m > 0 { return "\(m) 分鐘" }
        return "\(s) 秒"
    }

    var summary: String {
        guard enabled, !times.isEmpty else { return "未啟用" }
        let list = times.sorted().map(\.hhmm).joined(separator: "、")
        return "每天 \(list)，每次 \(durationDescription)"
    }

    // MARK: - JSON

    func jsonPayload() -> String {
        let obj: [String: Any] = [
            "on": enabled,
            "dur": FlushSchedule.clampDuration(durationSeconds),
            "times": times.sorted().map(\.hhmm),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    init() {}

    init?(json: String) {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        enabled = obj["on"] as? Bool ?? false
        durationSeconds = FlushSchedule.clampDuration(obj["dur"] as? Int ?? 120)
        let raw = obj["times"] as? [String] ?? []
        times = raw.compactMap(ScheduledTime.init(hhmm:))
                   .prefix(FlushSchedule.maxEntries)
                   .sorted()
    }
}
