import Foundation

extension Bundle {
    /// 「1.0.0 (1)」—— 行銷版本加上建置編號。
    ///
    /// 被退件重送時行銷版本通常不變，但建置編號一定會遞增，所以除錯時
    /// 需要兩個都看得到才知道使用者手上是哪一份 build。
    var appVersionDescription: String {
        let marketing = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(marketing) (\(build))"
    }
}

extension Locale {
    /// 沿用系統地區設定，但強制 24 小時制。
    ///
    /// 為什麼不用 `.hour(.twoDigits(amPM: .omitted))`：那個參數只是把 AM/PM 標記
    /// 藏起來，時鐘本身仍然是 12 小時制 —— 在 12 小時制的地區設定下，22:29 會被
    /// 顯示成 10:29，是錯誤的時間而不只是少了標記。
    ///
    /// 正確做法是透過 Unicode 的 hour cycle 設定真正切換時鐘。
    static let hour24: Locale = {
        var components = Locale.Components(locale: .autoupdatingCurrent)
        components.hourCycle = .zeroToTwentyThree
        return Locale(components: components)
    }()
}

extension Date {
    /// 「8/23 22:29」。日期與時間都會依手機所在時區換算。
    ///
    /// 手動串接而不是讓 FormatStyle 一次輸出：後者會在日期與時間之間補一個逗號
    /// （"8/23, 22:29"），在這個位置讀起來很雜。
    var shortDateTime24: String {
        "\(shortDate) \(time24)"
    }

    /// 「22:29」
    var time24: String {
        formatted(.dateTime
            .hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
            .locale(.hour24))
    }

    /// 「8/23」
    var shortDate: String {
        formatted(.dateTime.month(.defaultDigits).day().locale(.hour24))
    }
}
