import Foundation

/// MQTT 3.1.1 封包的編碼與解碼。
///
/// 只實作這個 App 真正用到的子集：CONNECT / CONNACK / SUBSCRIBE / SUBACK /
/// PUBLISH / PUBACK / PINGREQ / PINGRESP / DISCONNECT。QoS 只支援 0 與 1
/// （Adafruit IO 本來就不支援 QoS 2）。
///
/// 自己實作而不引入第三方函式庫的理由：需求極小（5 個訂閱、5 個發布），
/// 而 SwiftNIO 系列會為此拉進四個套件。零相依也讓 App Store 的隱私聲明最單純。
enum MQTTPacketType: UInt8 {
    case connect     = 1
    case connack     = 2
    case publish     = 3
    case puback      = 4
    case subscribe   = 8
    case suback      = 9
    case pingreq     = 12
    case pingresp    = 13
    case disconnect  = 14
}

struct MQTTPacket: Sendable {
    let type: MQTTPacketType
    let flags: UInt8
    let body: Data          // 可變標頭 + 酬載（不含固定標頭）
}

enum MQTTError: Error, LocalizedError {
    case connectionRefused(UInt8)
    case protocolViolation(String)
    case transport(String)
    case notConnected

    var errorDescription: String? {
        switch self {
        case .connectionRefused(let code):
            switch code {
            case 1: return "伺服器不支援的 MQTT 版本"
            case 2: return "用戶端識別碼被拒絕"
            case 3: return "伺服器暫時無法使用"
            case 4: return "使用者名稱或 AIO Key 錯誤"
            case 5: return "未被授權"
            default: return "連線被拒絕（代碼 \(code)）"
            }
        case .protocolViolation(let m): return "協定錯誤：\(m)"
        case .transport(let m):         return m
        case .notConnected:             return "尚未連線"
        }
    }
}

// MARK: - 編碼

enum MQTTEncoder {

    /// MQTT 的字串是 2 bytes 大端長度 + UTF-8 位元組。
    static func string(_ s: String) -> Data {
        let bytes = Array(s.utf8)
        var d = Data([UInt8(bytes.count >> 8), UInt8(bytes.count & 0xFF)])
        d.append(contentsOf: bytes)
        return d
    }

    /// 剩餘長度用 7-bit 可變長度編碼，每個位元組最高位代表「還有後續」。
    static func remainingLength(_ length: Int) -> Data {
        var value = length
        var out = Data()
        repeat {
            var byte = UInt8(value % 128)
            value /= 128
            if value > 0 { byte |= 0x80 }
            out.append(byte)
        } while value > 0
        return out
    }

    static func packet(type: MQTTPacketType, flags: UInt8 = 0, body: Data) -> Data {
        var d = Data([(type.rawValue << 4) | flags])
        d.append(remainingLength(body.count))
        d.append(body)
        return d
    }

    static func connect(clientId: String, username: String, password: String,
                        keepAlive: UInt16) -> Data {
        var body = string("MQTT")
        body.append(4)                       // Protocol Level 4 = MQTT 3.1.1
        body.append(0b1100_0010)             // username + password + clean session
        body.append(UInt8(keepAlive >> 8))
        body.append(UInt8(keepAlive & 0xFF))
        body.append(string(clientId))
        body.append(string(username))
        body.append(string(password))
        return packet(type: .connect, body: body)
    }

    static func subscribe(packetId: UInt16, topics: [(String, UInt8)]) -> Data {
        var body = Data([UInt8(packetId >> 8), UInt8(packetId & 0xFF)])
        for (topic, qos) in topics {
            body.append(string(topic))
            body.append(qos)
        }
        // SUBSCRIBE 的固定標頭 flags 依規範必須是 0b0010
        return packet(type: .subscribe, flags: 0b0010, body: body)
    }

    static func publish(topic: String, payload: String, qos: UInt8, packetId: UInt16?) -> Data {
        var body = string(topic)
        if qos > 0, let id = packetId {
            body.append(UInt8(id >> 8))
            body.append(UInt8(id & 0xFF))
        }
        body.append(contentsOf: Array(payload.utf8))
        return packet(type: .publish, flags: (qos << 1), body: body)
    }

    static func puback(packetId: UInt16) -> Data {
        packet(type: .puback, body: Data([UInt8(packetId >> 8), UInt8(packetId & 0xFF)]))
    }

    static var pingreq: Data    { packet(type: .pingreq, body: Data()) }
    static var disconnect: Data { packet(type: .disconnect, body: Data()) }
}

// MARK: - 解碼

/// 累積位元組並切出完整封包。
///
/// 必須是累積式的：MQTT over WebSocket 的規範允許一個 WebSocket frame 內含
/// 多個 MQTT 封包，也允許單一封包跨越多個 frame。直接把每個 frame 當成一個
/// 封包來解析在多數情況下會「剛好」正確，然後在酬載變大時隨機出錯。
struct MQTTDecoder {
    private var buffer = Data()

    mutating func append(_ data: Data) {
        buffer.append(data)
    }

    mutating func nextPacket() throws -> MQTTPacket? {
        guard buffer.count >= 2 else { return nil }

        let first = buffer[buffer.startIndex]
        guard let type = MQTTPacketType(rawValue: first >> 4) else {
            throw MQTTError.protocolViolation("未知的封包型別 \(first >> 4)")
        }

        // 解析可變長度的剩餘長度欄位
        var multiplier = 1
        var length = 0
        var index = buffer.startIndex + 1
        var lengthBytes = 0
        while true {
            guard index < buffer.endIndex else { return nil }   // 還沒收完
            let byte = buffer[index]
            length += Int(byte & 0x7F) * multiplier
            lengthBytes += 1
            index += 1
            if byte & 0x80 == 0 { break }
            multiplier *= 128
            if lengthBytes > 4 {
                throw MQTTError.protocolViolation("剩餘長度欄位超過 4 bytes")
            }
        }

        let headerSize = 1 + lengthBytes
        guard buffer.count >= headerSize + length else { return nil }

        let bodyStart = buffer.startIndex + headerSize
        let body = Data(buffer[bodyStart..<(bodyStart + length)])
        buffer.removeSubrange(buffer.startIndex..<(bodyStart + length))

        return MQTTPacket(type: type, flags: first & 0x0F, body: body)
    }
}

extension MQTTPacket {
    /// 從 PUBLISH 封包取出 topic、packet id 與酬載。
    func decodePublish() -> (topic: String, packetId: UInt16?, payload: String)? {
        guard type == .publish, body.count >= 2 else { return nil }
        let bytes = [UInt8](body)
        let topicLen = Int(bytes[0]) << 8 | Int(bytes[1])
        guard bytes.count >= 2 + topicLen else { return nil }
        let topic = String(decoding: bytes[2..<(2 + topicLen)], as: UTF8.self)

        var cursor = 2 + topicLen
        var packetId: UInt16?
        let qos = (flags >> 1) & 0x03
        if qos > 0 {
            guard bytes.count >= cursor + 2 else { return nil }
            packetId = UInt16(bytes[cursor]) << 8 | UInt16(bytes[cursor + 1])
            cursor += 2
        }
        let payload = String(decoding: bytes[cursor...], as: UTF8.self)
        return (topic, packetId, payload)
    }
}
