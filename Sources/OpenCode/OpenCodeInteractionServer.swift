import Darwin
import Foundation
import Network
import os.log

@MainActor
final class OpenCodeInteractionServer {
    nonisolated static var socketPath: String {
        "/tmp/codenotch-\(getuid()).sock"
    }

    private final class ClientContext {
        let connection: NWConnection
        var interactionID: String?

        init(connection: NWConnection) {
            self.connection = connection
        }
    }

    private static let maxPayloadSize = 1_048_576
    private let log = Logger(subsystem: "com.vinz.codenotch", category: "OpenCodeInteraction")
    private let store: OpenCodeInteractionStore
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: ClientContext] = [:]

    init(store: OpenCodeInteractionStore) {
        self.store = store
    }

    func start() {
        guard listener == nil else { return }

        unlink(Self.socketPath)
        let previousUmask = umask(0o077)

        let parameters = NWParameters()
        parameters.defaultProtocolStack.transportProtocol = NWProtocolTCP.Options()
        parameters.requiredLocalEndpoint = .unix(path: Self.socketPath)

        let newListener: NWListener
        do {
            newListener = try NWListener(using: parameters)
        } catch {
            umask(previousUmask)
            log.error("Could not create OpenCode interaction socket: \(error.localizedDescription, privacy: .public)")
            return
        }

        listener = newListener
        newListener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                self?.accept(connection)
            }
        }
        newListener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    umask(previousUmask)
                    chmod(Self.socketPath, 0o700)
                    self.log.info("OpenCode interaction socket ready")
                case .failed(let error):
                    umask(previousUmask)
                    self.log.error("OpenCode interaction socket failed: \(error.localizedDescription, privacy: .public)")
                    self.listener = nil
                case .cancelled:
                    umask(previousUmask)
                default:
                    break
                }
            }
        }
        newListener.start(queue: .main)
    }

    func stop() {
        store.releaseAll()
        for client in clients.values {
            client.connection.cancel()
        }
        clients.removeAll()
        listener?.cancel()
        listener = nil
        unlink(Self.socketPath)
    }

    private func accept(_ connection: NWConnection) {
        let client = ClientContext(connection: connection)
        let key = ObjectIdentifier(client)
        clients[key] = client

        connection.stateUpdateHandler = { [weak self, weak client] state in
            guard state == .cancelled || {
                if case .failed = state { return true }
                return false
            }() else { return }

            Task { @MainActor in
                guard let self, let client else { return }
                if let id = client.interactionID {
                    self.store.cancel(id)
                }
                self.clients.removeValue(forKey: ObjectIdentifier(client))
            }
        }
        connection.start(queue: .main)
        receive(client, accumulated: Data())
    }

    /// The plugin sends exactly one newline-delimited JSON request per
    /// connection and keeps the socket open for the answer. Framing on a
    /// newline is intentional: Node can wait for the reply without half-closing
    /// its write side, avoiding the macOS NWConnection half-close race that
    /// affects EOF-framed protocols.
    private func receive(_ client: ClientContext, accumulated: Data) {
        client.connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 65_536
        ) { [weak self, weak client] content, _, isComplete, error in
            Task { @MainActor in
                guard let self, let client else { return }

                var data = accumulated
                if let content { data.append(content) }

                guard data.count <= Self.maxPayloadSize else {
                    self.send(.permissionReject, to: client)
                    return
                }

                if let newline = data.firstIndex(of: 0x0A) {
                    self.process(Data(data[..<newline]), client: client)
                    return
                }

                if isComplete || error != nil {
                    client.connection.cancel()
                    return
                }

                self.receive(client, accumulated: data)
            }
        }
    }

    private func process(_ data: Data, client: ClientContext) {
        guard let wire = try? JSONDecoder().decode(OpenCodeInteractionWireRequest.self, from: data),
              wire.version == 1
        else {
            send(.permissionReject, to: client)
            return
        }

        if wire.kind == "resolved" {
            store.resolveExternally(
                sessionID: wire.sessionID,
                requestID: wire.requestID.isEmpty ? nil : wire.requestID
            )
            send(.resolvedExternally, to: client)
            return
        }

        guard let interaction = wire.interaction() else {
            send(.permissionReject, to: client)
            return
        }

        let accepted = store.receive(interaction) { [weak self, weak client] reply in
            guard let self, let client else { return }
            self.send(reply, to: client)
        }

        if accepted {
            // Only the connection that owns the store entry may cancel it when
            // that connection dies. A duplicate has the same logical id and
            // must never tear down the first, valid request as it closes.
            client.interactionID = interaction.id
        } else {
            // A duplicate transport must not decide the user's permission.
            // Tell only that duplicate plugin instance to stand down while the
            // first connection remains the sole request the user can answer.
            send(.resolvedExternally, to: client)
        }
    }

    private func send(_ reply: OpenCodeInteractionReply, to client: ClientContext) {
        guard var data = try? JSONEncoder().encode(OpenCodeInteractionWireReply.encode(reply)) else {
            finish(client)
            return
        }
        data.append(0x0A)
        client.connection.send(content: data, completion: .contentProcessed { [weak self, weak client] _ in
            Task { @MainActor in
                guard let self, let client else { return }
                self.finish(client)
            }
        })
    }

    private func finish(_ client: ClientContext) {
        clients.removeValue(forKey: ObjectIdentifier(client))
        client.connection.cancel()
    }
}
