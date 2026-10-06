import XCTest
@testable import Codenotch

@MainActor
final class OpenCodeInteractionPresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_789_000_000)

    private func permission(sessionID: String = "s1") -> OpenCodeInteraction {
        OpenCodeInteraction(
            sessionID: sessionID,
            requestID: "r1",
            kind: .permission(OpenCodePermissionRequest(
                toolName: "Bash",
                cwd: "/Users/x/Projects/codenotch",
                command: "rm -rf build",
                filePath: nil,
                patterns: ["rm -rf build"],
                description: nil
            )),
            createdAt: now
        )
    }

    func testPendingOpenCodePermissionTurnsMatchingSessionIntoWaiting() throws {
        let model = NotchViewModel()
        model.sessions["opencode"] = [
            AgentSession(
                id: "opencode.session.s1",
                name: "Refactor parser",
                detail: "Working in codenotch",
                state: .busy,
                waitingFor: nil,
                since: now.addingTimeInterval(-10)
            )
        ]
        model.openCodeInteractions = [permission()]

        let summary = try XCTUnwrap(model.activity(for: "opencode"))

        XCTAssertEqual(summary.state, .waiting)
        XCTAssertEqual(summary.sessions.count, 1)
        XCTAssertEqual(summary.sessions[0].id, "opencode.session.s1")
        XCTAssertEqual(summary.sessions[0].state, .waiting)
        XCTAssertEqual(summary.sessions[0].waitingFor, "Approval: Bash")
        XCTAssertEqual(summary.sessions[0].name, "Refactor parser")
    }

    func testPendingInteractionWithoutDatabaseRowStillAppearsAsWaiting() throws {
        let model = NotchViewModel()
        model.openCodeInteractions = [permission(sessionID: "new-session")]

        let summary = try XCTUnwrap(model.activity(for: "opencode"))

        XCTAssertEqual(summary.state, .waiting)
        XCTAssertEqual(summary.sessions.count, 1)
        XCTAssertEqual(summary.sessions[0].id, "opencode.session.new-session")
        XCTAssertEqual(summary.sessions[0].state, .waiting)
    }

    func testOpenCodeInteractionDoesNotChangeAnotherProvidersActivity() throws {
        let model = NotchViewModel()
        model.sessions["claude"] = [
            AgentSession(
                id: "claude.s1",
                name: "Claude",
                detail: "Working",
                state: .busy,
                waitingFor: nil,
                since: now
            )
        ]
        model.openCodeInteractions = [permission()]

        let summary = try XCTUnwrap(model.activity(for: "claude"))

        XCTAssertEqual(summary.state, .working)
        XCTAssertEqual(summary.sessions.map(\.id), ["claude.s1"])
        XCTAssertEqual(summary.sessions.first?.state, .busy)
    }

    func testQuestionUsesTheQuestionTextAsWaitingReason() throws {
        let model = NotchViewModel()
        model.openCodeInteractions = [
            OpenCodeInteraction(
                sessionID: "s1",
                requestID: "q1",
                kind: .question(OpenCodeQuestionRequest(
                    cwd: nil,
                    questions: [
                        OpenCodeQuestion(
                            question: "Which target should I build?",
                            header: "Target",
                            options: [],
                            multiSelect: false
                        )
                    ]
                )),
                createdAt: now
            )
        ]

        let summary = try XCTUnwrap(model.activity(for: "opencode"))
        XCTAssertEqual(summary.sessions.first?.waitingFor, "Which target should I build?")
    }
}
