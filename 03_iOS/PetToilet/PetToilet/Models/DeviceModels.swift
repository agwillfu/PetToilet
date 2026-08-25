import Foundation

enum ConnectionStatus: Sendable, Equatable {
    case disconnected
    case connecting
    case connected
    case failed(String)

    var isConnected: Bool { self == .connected }

    var displayName: String {
        switch self {
        case .disconnected:  return "未連線"
        case .connecting:    return "連線中…"
        case .connected:     return "已連線"
        case .failed(let m): return "連線失敗：\(m)"
        }
    }
}

/// 這個版本的 App 能理解的通訊協定版本。
///
/// 韌體可以 OTA 在幾分鐘內全部更新，但家人手機上的 App 什麼時候更新無法控制。
/// 裝置回報的版本比這個大時，代表韌體改了 feed 格式而這支 App 還看不懂 ——
/// 與其默默出錯，不如明白提示使用者更新。
///
/// 對應韌體 PetToilet.ino 的 `PROTOCOL_VERSION`。兩邊要一起改。
enum DeviceProtocol {
    static let supported = 1
}

/// 韌體 `diag` feed 的內容。欄位全部 optional —— 韌體版本演進時會增減欄位，
/// App 不該因為少了一個欄位就解析失敗。
struct Diagnostics: Sendable, Equatable {
    var firmwareVersion: String?
    /// 裝置回報的協定版本。舊韌體沒有這個欄位，視為第 1 版。
    var protocolVersion: Int = DeviceProtocol.supported

    /// 裝置的格式比這支 App 新，代表 App 該更新了。
    var needsAppUpdate: Bool { protocolVersion > DeviceProtocol.supported }

    var freeHeap: Int?
    var maxFreeBlock: Int?
    var fragmentation: Int?
    var rssi: Int?
    var uptimeSeconds: Int?
    var mflnActive: Bool?
    var ipAddress: String?

    init(json: [String: Any]) {
        firmwareVersion = json["fw"] as? String
        // 缺欄位時退回 1：那是還沒有這個欄位的舊韌體，格式與第 1 版相同
        protocolVersion = json["proto"] as? Int ?? 1
        freeHeap        = json["heap"] as? Int
        maxFreeBlock    = json["maxblock"] as? Int
        fragmentation   = json["frag"] as? Int
        rssi            = json["rssi"] as? Int
        uptimeSeconds   = json["uptime"] as? Int
        mflnActive      = (json["mfln"] as? Int).map { $0 != 0 }
        ipAddress       = json["ip"] as? String
    }

    init() {}

    var uptimeDescription: String? {
        guard let s = uptimeSeconds else { return nil }
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "\(d) 天 \(h) 小時" }
        if h > 0 { return "\(h) 小時 \(m) 分" }
        return "\(m) 分鐘"
    }

    /// WiFi 訊號強度分級。-70dBm 以下在實務上就開始出現斷線。
    var signalDescription: String? {
        guard let r = rssi else { return nil }
        switch r {
        case (-60)...:      return "良好 (\(r) dBm)"
        case (-70)..<(-60): return "普通 (\(r) dBm)"
        default:            return "微弱 (\(r) dBm)"
        }
    }
}

/// 三個可調參數的合法範圍。必須與韌體的 clampInt 上下界一致 ——
/// 這裡先擋住，使用者就不會送出一個會被裝置默默改掉的值。
enum SettingRange {
    static let entry    = 1...30
    static let exit     = 5...60
    static let duration = 10...120     // 10 秒 ~ 2 分鐘
}

struct DeviceSettings: Sendable, Equatable {
    var entryThreshold: Int = 5
    var exitThreshold: Int = 15
    var flushDuration: Int = 10

    static func clampEntry(_ v: Int) -> Int    { min(max(v, SettingRange.entry.lowerBound), SettingRange.entry.upperBound) }
    static func clampExit(_ v: Int) -> Int     { min(max(v, SettingRange.exit.lowerBound), SettingRange.exit.upperBound) }
    static func clampDuration(_ v: Int) -> Int { min(max(v, SettingRange.duration.lowerBound), SettingRange.duration.upperBound) }
}

/// 後端送給 UI 的單向事件流。
enum DeviceEvent: Sendable {
    case connection(ConnectionStatus)

    /// 是否正在回填「目前值」。
    ///
    /// Adafruit IO 不支援 MQTT 的 retain flag，所以連線後要對 `<feed>/get` 發一則
    /// 空訊息，broker 才會把最後一筆值推回來。問題是那些回應在 MQTT 上跟「剛發生的
    /// 事件」長得一模一樣 —— 沒有這個標記的話，每次開 App 都會把舊的 last-flush
    /// 當成一次新的沖水記進活動紀錄，時間還是錯的（開啟時間而非實際沖水時間）。
    case syncing(Bool)
    case state(ToiletState)
    case entryThreshold(Int)
    case exitThreshold(Int)
    case flushDuration(Int)
    case lastFlush(String)
    case diagnostics(Diagnostics)
    case schedule(FlushSchedule)
    case log(String)
}

/// 真實裝置與模擬裝置共用的介面。
///
/// 這個抽象不是為了「以後可能會換實作」而做的過度設計 —— 它有兩個具體用途：
///   1. 沒有硬體時也能開發 UI（模擬器上無法連到家裡的尿盆）
///   2. App Store 審查員手上沒有這台硬體。若 App 打開只顯示「連線中…」會直接被
///      以審查指南 2.1 退件。Demo 模式讓審查員能完整操作所有功能。
protocol DeviceBackend: Actor {
    /// 必須是 nonisolated —— 事件流的用途就是給 actor 外部（UI）訂閱，
    /// 若隨 actor 隔離則呼叫端無法在非 async 情境取得它。
    nonisolated var events: AsyncStream<DeviceEvent> { get }

    func start() async
    func stop() async
    func flushNow() async
    func setEntryThreshold(_ seconds: Int) async
    func setExitThreshold(_ seconds: Int) async
    func setFlushDuration(_ seconds: Int) async
    func setSchedule(_ schedule: FlushSchedule) async
    func triggerOTA() async
}
