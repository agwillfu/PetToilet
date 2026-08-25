import SwiftUI

/// 裝置狀態。字串值必須與韌體 `stateName()` 的輸出完全一致。
enum ToiletState: String, Sendable, CaseIterable {
    case idle
    case detecting
    case inuse
    case flushing
    case cooldown
    case ota
    case offline

    /// 韌體送來未知字串時的保底值 —— 不要因為多了一個新狀態就讓 App 崩潰或卡住。
    case unknown

    init(rawValueOrUnknown raw: String) {
        self = ToiletState(rawValue: raw) ?? .unknown
    }

    var displayName: String {
        switch self {
        case .idle:      return "等待中"
        case .detecting: return "偵測到活動"
        case .inuse:     return "白白使用中"
        case .flushing:  return "沖水中"
        case .cooldown:  return "靜置中"
        case .ota:       return "更新模式"
        case .offline:   return "裝置離線"
        case .unknown:   return "未知狀態"
        }
    }

    var symbol: String {
        switch self {
        case .idle:      return "moon.zzz"
        case .detecting: return "sensor"
        case .inuse:     return "pawprint.fill"
        case .flushing:  return "drop.fill"
        case .cooldown:  return "hourglass"
        case .ota:       return "arrow.down.circle"
        case .offline:   return "wifi.slash"
        case .unknown:   return "questionmark.circle"
        }
    }

    var tint: Color {
        switch self {
        case .idle:      return .secondary
        case .detecting: return .yellow
        case .inuse:     return .orange
        case .flushing:  return .blue
        case .cooldown:  return .teal
        case .ota:       return .purple
        case .offline:   return .red
        case .unknown:   return .gray
        }
    }

    /// 只有閒置時才接受手動沖水 —— 與韌體的判斷一致，避免送出注定被忽略的指令。
    var acceptsManualFlush: Bool { self == .idle }
}
