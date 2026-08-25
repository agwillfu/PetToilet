import Foundation

/// 走 WebSocket Secure 的極簡 MQTT 3.1.1 用戶端。
///
/// 為什麼是 WebSocket 而不是原生 TCP：`URLSessionWebSocketTask` 由系統處理 TLS、
/// 憑證驗證與連線建立，不需要任何第三方相依，也不需要自己管理 TLS 狀態。
/// Adafruit IO 在 443 埠提供 `wss://io.adafruit.com/mqtt`。
actor MQTTWebSocketClient {

    enum Event: Sendable {
        case connected
        case message(topic: String, payload: String)
        case disconnected(String?)
    }

    nonisolated let events: AsyncStream<Event>
    private let emit: AsyncStream<Event>.Continuation

    private var socket: URLSessionWebSocketTask?
    private var decoder = MQTTDecoder()
    private var receiveLoop: Task<Void, Never>?
    private var pingLoop: Task<Void, Never>?
    private var connackWaiter: CheckedContinuation<Void, Error>?
    private var nextPacketId: UInt16 = 1
    private var isConnected = false

    private let keepAliveSeconds: UInt16 = 45

    init() {
        (events, emit) = AsyncStream<Event>.makeStream(bufferingPolicy: .bufferingNewest(128))
    }

    // MARK: - 連線

    func connect(host: String, clientId: String, username: String, password: String) async throws {
        await disconnect()

        guard let url = URL(string: "wss://\(host)/mqtt") else {
            throw MQTTError.transport("無效的伺服器位址")
        }

        // 刻意不指定 subprotocol：Adafruit IO 的伺服器不會回應 `mqtt` subprotocol，
        // 指定了反而可能讓握手因為沒有協商結果而失敗。
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        let task = URLSession(configuration: config).webSocketTask(with: url)
        socket = task
        decoder = MQTTDecoder()
        task.resume()

        startReceiveLoop()

        try await send(MQTTEncoder.connect(clientId: clientId,
                                           username: username,
                                           password: password,
                                           keepAlive: keepAliveSeconds))

        // 等 CONNACK。沒有這一步的話，帳密錯誤要等到第一次 publish 失敗才會發現。
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                try await withCheckedThrowingContinuation { c in
                    Task { await self?.setConnackWaiter(c) }
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(15))
                throw MQTTError.transport("等待伺服器回應逾時")
            }
            try await group.next()
            group.cancelAll()
        }

        isConnected = true
        startPingLoop()
        emit.yield(.connected)
    }

    func disconnect() async {
        if isConnected { try? await send(MQTTEncoder.disconnect) }
        isConnected = false
        receiveLoop?.cancel(); receiveLoop = nil
        pingLoop?.cancel();    pingLoop = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        if let waiter = connackWaiter {
            connackWaiter = nil
            waiter.resume(throwing: MQTTError.transport("連線已關閉"))
        }
    }

    // MARK: - 操作

    func subscribe(_ topics: [String], qos: UInt8 = 1) async throws {
        guard isConnected else { throw MQTTError.notConnected }
        let id = takePacketId()
        try await send(MQTTEncoder.subscribe(packetId: id, topics: topics.map { ($0, qos) }))
    }

    func publish(topic: String, payload: String, qos: UInt8 = 1) async throws {
        guard isConnected else { throw MQTTError.notConnected }
        let id: UInt16? = qos > 0 ? takePacketId() : nil
        try await send(MQTTEncoder.publish(topic: topic, payload: payload, qos: qos, packetId: id))
    }

    // MARK: - 內部

    private func setConnackWaiter(_ c: CheckedContinuation<Void, Error>) {
        connackWaiter = c
    }

    private func takePacketId() -> UInt16 {
        let id = nextPacketId
        nextPacketId = nextPacketId == UInt16.max ? 1 : nextPacketId + 1
        return id
    }

    private func send(_ data: Data) async throws {
        guard let socket else { throw MQTTError.notConnected }
        do {
            try await socket.send(.data(data))
        } catch {
            throw MQTTError.transport(error.localizedDescription)
        }
    }

    private func startReceiveLoop() {
        receiveLoop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    let message = try await self.receiveOne()
                    await self.ingest(message)
                } catch {
                    await self.failed(error)
                    return
                }
            }
        }
    }

    private func receiveOne() async throws -> URLSessionWebSocketTask.Message {
        guard let socket else { throw MQTTError.notConnected }
        return try await socket.receive()
    }

    private func ingest(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .data(let d):   decoder.append(d)
        case .string(let s): decoder.append(Data(s.utf8))
        @unknown default:    return
        }

        // 一個 WebSocket frame 可能含多個 MQTT 封包，要一路取到取不出為止
        while true {
            let packet: MQTTPacket?
            do { packet = try decoder.nextPacket() }
            catch { failed(error); return }
            guard let packet else { return }
            handle(packet)
        }
    }

    private func handle(_ packet: MQTTPacket) {
        switch packet.type {
        case .connack:
            let code = packet.body.count >= 2 ? packet.body[packet.body.startIndex + 1] : 255
            let waiter = connackWaiter
            connackWaiter = nil
            if code == 0 {
                waiter?.resume()
            } else {
                waiter?.resume(throwing: MQTTError.connectionRefused(code))
            }

        case .publish:
            guard let (topic, packetId, payload) = packet.decodePublish() else { return }
            // QoS 1 必須回 PUBACK，否則 broker 會不斷重送同一則訊息
            if let id = packetId {
                Task { try? await self.send(MQTTEncoder.puback(packetId: id)) }
            }
            emit.yield(.message(topic: topic, payload: payload))

        case .puback, .suback, .pingresp:
            break

        default:
            break
        }
    }

    private func failed(_ error: Error) {
        guard isConnected || connackWaiter != nil else { return }
        let message = (error as? MQTTError)?.errorDescription ?? error.localizedDescription
        if let waiter = connackWaiter {
            connackWaiter = nil
            waiter.resume(throwing: error)
        }
        isConnected = false
        emit.yield(.disconnected(message))
    }

    private func startPingLoop() {
        pingLoop = Task { [weak self] in
            while !Task.isCancelled {
                // 比 keepalive 短一些送出，留出網路延遲的餘裕
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, let self else { return }
                do { try await self.send(MQTTEncoder.pingreq) }
                catch { await self.failed(error); return }
            }
        }
    }
}
