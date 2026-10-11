import Foundation
import Network
import Security
import MowerBarCore

@MainActor final class MQTTClient {
    enum Event { case connected, disconnected(String), telemetry(Data) }
    var onEvent: ((Event) -> Void)?
    private(set) var connected = false
    private var connection: NWConnection?
    private var decoder = MQTTDecoder()
    private var generation = UUID()
    private var connectWaiter: CheckedContinuation<Void, Error>?
    private var subscribeWaiter: CheckedContinuation<Void, Error>?
    private var acknowledgements: [Int: CheckedContinuation<Void, Error>] = [:]
    private var pingTask: Task<Void, Never>?
    private var lastReceived = Date()
    private var nextID = 10
    private var expectedTopic = ""
    private var intentional = false

    func connect(mower: Mower, token: String) async throws {
        disconnect()
        intentional = false; decoder = MQTTDecoder(); expectedTopic = mower.topicOut
        let generation = UUID(); self.generation = generation
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "mqtt")
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, mower.endpoint)
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        let connection = NWConnection(host: NWEndpoint.Host(mower.endpoint), port: 443, using: parameters)
        self.connection = connection
        let installation = UserDefaults.standard.string(forKey: "installationID") ?? UUID().uuidString
        UserDefaults.standard.set(installation, forKey: "installationID")
        let packet = try MQTTWire.connect(clientID: "WX/USER/\(mower.userID)/macos/\(installation)", username: MQTTWire.username(accessToken: token))
        try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, Error>) in
            connectWaiter = waiter
            connection.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self, self.generation == generation else { return }
                    switch state {
                    case .ready:
                        self.receive(generation: generation)
                        self.write(packet)
                    case .failed: self.fail(String(localized: "The connection to the mower was interrupted."))
                    case .waiting: break
                    default: break
                    }
                }
            }
            connection.start(queue: .global(qos: .utility))
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(20))
                guard let self, self.generation == generation, self.connectWaiter != nil else { return }
                self.fail(String(localized: "The cloud did not answer the connection."))
            }
        }
        try await subscribe(mower.topicOut)
        onEvent?(.connected)
        pingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(12)) } catch { return }
                guard let self, self.generation == generation, self.connected else { return }
                if Date().timeIntervalSince(self.lastReceived) > 45 { self.fail(String(localized: "The cloud link stopped responding.")); return }
                self.write(Data([0xC0, 0]))
            }
        }
    }
    private func subscribe(_ topic: String) async throws {
        let id = packetID()
        let packet = try MQTTWire.subscribe(topic: topic, id: id)
        let generation = self.generation
        try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, Error>) in
            subscribeWaiter = waiter; write(packet)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(15))
                guard let self, self.generation == generation, self.subscribeWaiter != nil else { return }
                self.fail(String(localized: "The subscription to the mower’s events was not confirmed."))
            }
        }
    }
    func publish(topic: String, payload: Data) async throws {
        guard connected, subscribeWaiter == nil else { throw ProtocolError.invalid(String(localized: "The mower is not connected.")) }
        let id = packetID(); let packet = try MQTTWire.publish(topic: topic, payload: payload, id: id)
        let generation = self.generation
        try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, Error>) in
            acknowledgements[id] = waiter; write(packet)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(12))
                guard let self, self.generation == generation else { return }
                self.acknowledgements.removeValue(forKey: id)?.resume(throwing: ProtocolError.invalid(String(localized: "No acknowledgement from the cloud. The command will not be resent automatically.")))
            }
        }
    }
    func disconnect() {
        intentional = true; generation = UUID(); connected = false
        pingTask?.cancel(); pingTask = nil
        connection?.cancel(); connection = nil
        let error = ProtocolError.invalid(String(localized: "Connection closed."))
        connectWaiter?.resume(throwing: error); connectWaiter = nil
        subscribeWaiter?.resume(throwing: error); subscribeWaiter = nil
        for waiter in acknowledgements.values { waiter.resume(throwing: error) }; acknowledgements.removeAll()
    }
    private func fail(_ message: String) {
        let report = !intentional
        disconnect()
        if report { onEvent?(.disconnected(message)) }
    }
    private func packetID() -> Int { nextID = nextID % 65535 + 1; return nextID }
    private func write(_ data: Data) {
        guard let connection else { return }
        let generation = self.generation
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if error != nil { Task { @MainActor in
                guard let self, self.generation == generation else { return }; self.fail(String(localized: "Sending interrupted; no command is kept offline."))
            } }
        })
    }
    private func receive(generation: UUID) {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                do {
                    if let data, !data.isEmpty {
                        self.lastReceived = Date()
                        for frame in try self.decoder.append(data) { try self.handle(frame) }
                    }
                    if complete || error != nil { self.fail(String(localized: "Cloud link interrupted.")) }
                    else { self.receive(generation: generation) }
                } catch { self.fail(String(localized: "Unrecognised network answer.")) }
            }
        }
    }
    private func handle(_ frame: MQTTFrame) throws {
        let bytes = [UInt8](frame.body)
        switch frame.type {
        case 2:
            guard bytes.count >= 3, bytes[1] == 0 else {
                let reason = bytes.count > 1 ? Int(bytes[1]) : -1
                fail(String(localized: "Worx refused the connection (code \(reason)).")); return
            }
            connected = true; connectWaiter?.resume(); connectWaiter = nil
        case 9:
            guard bytes.count >= 4, bytes[2] == 0, bytes[3] < 128 else { fail(String(localized: "Worx refused the subscription.")); return }
            subscribeWaiter?.resume(); subscribeWaiter = nil
        case 3:
            let publication = try MQTTWire.publication(frame)
            if let id = publication.id { write(MQTTFrame(header: 0x40, body: MQTTWire.u16(id)).encoded) }
            if publication.topic == expectedTopic { onEvent?(.telemetry(publication.payload)) }
        case 4:
            guard bytes.count >= 2 else { throw ProtocolError.invalid(String(localized: "Incomplete acknowledgement.")) }
            let id = Int(bytes[0])*256 + Int(bytes[1])
            if bytes.count >= 3 && bytes[2] >= 128 {
                acknowledgements.removeValue(forKey: id)?.resume(throwing: ProtocolError.invalid(String(localized: "The cloud refused the message.")))
            } else { acknowledgements.removeValue(forKey: id)?.resume() }
        case 13: break
        case 14: fail(String(localized: "Cloud session closed by Worx."))
        default: break
        }
    }
}
