import Combine
import Foundation

struct OpenCodeQuestionOption: Equatable, Codable {
    let label: String
    let description: String?
}

struct OpenCodeQuestion: Equatable, Codable {
    let question: String
    let header: String?
    let options: [OpenCodeQuestionOption]
    let multiSelect: Bool
}

struct OpenCodePermissionRequest: Equatable, Codable {
    let toolName: String
    let cwd: String?
    let command: String?
    let filePath: String?
    let patterns: [String]
    let description: String?
}

struct OpenCodeQuestionRequest: Equatable, Codable {
    let cwd: String?
    let questions: [OpenCodeQuestion]
}

struct OpenCodeInteraction: Identifiable, Equatable {
    enum Kind: Equatable {
        case permission(OpenCodePermissionRequest)
        case question(OpenCodeQuestionRequest)
    }

    let sessionID: String
    let requestID: String
    let kind: Kind
    let createdAt: Date

    var id: String {
        let kindKey = switch kind {
        case .permission: "permission"
        case .question: "question"
        }
        return "\(sessionID):\(kindKey):\(requestID)"
    }
}

enum OpenCodeInteractionReply: Equatable {
    case permissionOnce
    case permissionAlways
    case permissionReject
    case questionAnswers([[String]])
    case questionReject
}

@MainActor
final class OpenCodeInteractionStore: ObservableObject {
    @Published private(set) var interactions: [OpenCodeInteraction] = []

    private var responders: [String: (OpenCodeInteractionReply) -> Void] = [:]

    @discardableResult
    func receive(
        _ interaction: OpenCodeInteraction,
        responder: @escaping (OpenCodeInteractionReply) -> Void
    ) -> Bool {
        guard responders[interaction.id] == nil else { return false }
        interactions.append(interaction)
        responders[interaction.id] = responder
        return true
    }

    func resolve(_ id: String, with reply: OpenCodeInteractionReply) {
        guard let responder = responders.removeValue(forKey: id) else { return }
        interactions.removeAll { $0.id == id }
        responder(reply)
    }

    func cancel(_ id: String) {
        responders.removeValue(forKey: id)
        interactions.removeAll { $0.id == id }
    }

    func cancelAll() {
        let ids = interactions.map(\.id)
        for id in ids {
            resolve(id, with: .permissionReject)
        }
    }

    func allowOnce(_ id: String) {
        resolve(id, with: .permissionOnce)
    }

    func allowAlways(_ id: String) {
        resolve(id, with: .permissionAlways)
    }

    func deny(_ id: String) {
        guard let interaction = interactions.first(where: { $0.id == id }) else { return }
        switch interaction.kind {
        case .permission:
            resolve(id, with: .permissionReject)
        case .question:
            resolve(id, with: .questionReject)
        }
    }

    func answer(_ id: String, answers: [[String]]) {
        resolve(id, with: .questionAnswers(answers))
    }
}
