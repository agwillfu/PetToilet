import Foundation

/// 從 Adafruit IO 的 REST API 撈 feed 歷史，回填活動紀錄。
///
/// MQTT 只能收到「訂閱之後」發生的事件。要看得到過去兩週白白用了幾次，
/// 必須另外從 REST 撈歷史 —— 免費版保留 30 天。
struct AdafruitHistory: Sendable {
    let credentials: Credentials

    private static let host = "https://io.adafruit.com/api/v2"

    /// 撈取指定天數內的活動紀錄。失敗時回傳空陣列而不是拋錯 ——
    /// 歷史回填是加分項，不該讓它的失敗影響即時控制功能。
    func fetch(days: Int = 14) async -> [ActivityEntry] {
        async let flushes = entries(feed: "last-flush", days: days) { value, _ in
            // 值的格式是 "2026-08-23 22:28:59 手動"，最後一段是觸發來源
            let reason = value.split(separator: " ").last.map(String.init) ?? "未知"
            return "\(ActivityEntry.flushPrefix)（\(reason)）"
        }
        async let uses = entries(feed: "state", days: days) { value, _ in
            // 只取真正有意義的狀態。idle / cooldown 是流程雜訊，
            // flushing 則會與 last-flush 重複。
            value == "inuse" ? "白白開始使用" : nil
        }
        return await (flushes + uses).sorted { $0.date > $1.date }
    }

    private func entries(feed: String, days: Int,
                         transform: @Sendable (String, Date) -> String?) async -> [ActivityEntry] {
        guard credentials.isComplete else { return [] }

        let since = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-Double(days) * 86400))
        var comps = URLComponents(string: "\(Self.host)/\(credentials.username)/feeds/\(feed)/data")
        comps?.queryItems = [
            URLQueryItem(name: "start_time", value: since),
            URLQueryItem(name: "limit", value: "1000"),
        ]
        guard let url = comps?.url else { return [] }

        var request = URLRequest(url: url)
        request.setValue(credentials.key, forHTTPHeaderField: "X-AIO-Key")
        request.timeoutInterval = 20

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }

        let parser = ISO8601DateFormatter()
        return rows.compactMap { row in
            guard let id = row["id"] as? String,
                  let value = row["value"] as? String,
                  let createdAt = row["created_at"] as? String,
                  let date = parser.date(from: createdAt),
                  let message = transform(value, date)
            else { return nil }
            return ActivityEntry(id: id, date: date, message: message, isFromDevice: true)
        }
    }
}
