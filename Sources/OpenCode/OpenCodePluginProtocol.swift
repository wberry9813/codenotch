import Foundation

struct OpenCodeInteractionWireRequest: Codable, Equatable {
    let version: Int
    let kind: String
    let sessionID: String
    let requestID: String
    let cwd: String?
    let toolName: String?
    let command: String?
    let filePath: String?
    let patterns: [String]?
    let description: String?
    let questions: [OpenCodeQuestion]?

    func interaction(createdAt: Date = Date()) -> OpenCodeInteraction? {
        guard version == 1, !sessionID.isEmpty, !requestID.isEmpty else { return nil }

        switch kind {
        case "permission":
            return OpenCodeInteraction(
                sessionID: sessionID,
                requestID: requestID,
                kind: .permission(OpenCodePermissionRequest(
                    toolName: toolName ?? "Tool",
                    cwd: cwd,
                    command: command,
                    filePath: filePath,
                    patterns: patterns ?? [],
                    description: description
                )),
                createdAt: createdAt
            )
        case "question":
            let questions = questions ?? []
            guard !questions.isEmpty else { return nil }
            return OpenCodeInteraction(
                sessionID: sessionID,
                requestID: requestID,
                kind: .question(OpenCodeQuestionRequest(cwd: cwd, questions: questions)),
                createdAt: createdAt
            )
        default:
            return nil
        }
    }
}

struct OpenCodeInteractionWireReply: Codable, Equatable {
    let decision: String
    let answers: [[String]]?

    static func encode(_ reply: OpenCodeInteractionReply) -> OpenCodeInteractionWireReply {
        switch reply {
        case .permissionOnce:
            OpenCodeInteractionWireReply(decision: "once", answers: nil)
        case .permissionAlways:
            OpenCodeInteractionWireReply(decision: "always", answers: nil)
        case .permissionReject:
            OpenCodeInteractionWireReply(decision: "reject", answers: nil)
        case .questionAnswers(let answers):
            OpenCodeInteractionWireReply(decision: "answer", answers: answers)
        case .questionReject:
            OpenCodeInteractionWireReply(decision: "reject", answers: nil)
        case .resolvedExternally:
            OpenCodeInteractionWireReply(decision: "resolved", answers: nil)
        }
    }
}
