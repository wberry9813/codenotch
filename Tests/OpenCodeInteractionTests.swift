import Foundation
import XCTest
@testable import Codenotch

@MainActor
final class OpenCodeInteractionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_789_000_000)

    private func permission(
        session: String = "s1",
        request: String = "r1"
    ) -> OpenCodeInteraction {
        OpenCodeInteraction(
            sessionID: session,
            requestID: request,
            kind: .permission(OpenCodePermissionRequest(
                toolName: "Bash",
                cwd: "/tmp/project",
                command: "rm -rf build",
                filePath: nil,
                patterns: ["rm -rf build"],
                description: nil
            )),
            createdAt: now
        )
    }

    private func question(
        session: String = "s1",
        request: String = "q1"
    ) -> OpenCodeInteraction {
        OpenCodeInteraction(
            sessionID: session,
            requestID: request,
            kind: .question(OpenCodeQuestionRequest(
                cwd: "/tmp/project",
                questions: [
                    OpenCodeQuestion(
                        question: "Choose targets",
                        header: "Targets",
                        options: [
                            OpenCodeQuestionOption(label: "A", description: nil),
                            OpenCodeQuestionOption(label: "B", description: "Second")
                        ],
                        multiSelect: true
                    )
                ]
            )),
            createdAt: now
        )
    }

    func testWirePermissionBecomesTypedInteraction() throws {
        let data = Data("""
        {
          "version": 1,
          "kind": "permission",
          "sessionID": "s1",
          "requestID": "r1",
          "cwd": "/tmp/project",
          "toolName": "Bash",
          "command": "rm -rf build",
          "patterns": ["rm -rf build"]
        }
        """.utf8)

        let wire = try JSONDecoder().decode(OpenCodeInteractionWireRequest.self, from: data)
        let interaction = try XCTUnwrap(wire.interaction(createdAt: now))

        XCTAssertEqual(interaction.id, "s1:permission:r1")
        XCTAssertEqual(interaction.createdAt, now)
        guard case .permission(let request) = interaction.kind else {
            return XCTFail("expected permission")
        }
        XCTAssertEqual(request.toolName, "Bash")
        XCTAssertEqual(request.command, "rm -rf build")
        XCTAssertEqual(request.patterns, ["rm -rf build"])
    }

    func testWireQuestionPreservesMultiSelectOptions() throws {
        let data = Data("""
        {
          "version": 1,
          "kind": "question",
          "sessionID": "s1",
          "requestID": "q1",
          "questions": [{
            "question": "Choose targets",
            "header": "Targets",
            "options": [
              {"label": "A"},
              {"label": "B", "description": "Second"}
            ],
            "multiSelect": true
          }]
        }
        """.utf8)

        let wire = try JSONDecoder().decode(OpenCodeInteractionWireRequest.self, from: data)
        let interaction = try XCTUnwrap(wire.interaction(createdAt: now))

        guard case .question(let request) = interaction.kind else {
            return XCTFail("expected question")
        }
        XCTAssertEqual(request.questions.count, 1)
        XCTAssertEqual(request.questions[0].options.map(\.label), ["A", "B"])
        XCTAssertTrue(request.questions[0].multiSelect)
    }

    func testConcurrentSessionsRouteRepliesByExactInteractionID() {
        let store = OpenCodeInteractionStore()
        var first: OpenCodeInteractionReply?
        var second: OpenCodeInteractionReply?

        let a = permission(session: "session-a", request: "request-a")
        let b = permission(session: "session-b", request: "request-b")
        XCTAssertTrue(store.receive(a) { first = $0 })
        XCTAssertTrue(store.receive(b) { second = $0 })

        store.allowAlways(b.id)

        XCTAssertNil(first)
        XCTAssertEqual(second, .permissionAlways)
        XCTAssertEqual(store.interactions.map(\.id), [a.id])

        store.allowOnce(a.id)
        XCTAssertEqual(first, .permissionOnce)
        XCTAssertTrue(store.interactions.isEmpty)
    }

    func testQuestionAnswerKeepsQuestionOrderAndMultipleSelections() {
        let store = OpenCodeInteractionStore()
        var reply: OpenCodeInteractionReply?
        let item = question()

        XCTAssertTrue(store.receive(item) { reply = $0 })
        store.answer(item.id, answers: [["A", "B"]])

        XCTAssertEqual(reply, .questionAnswers([["A", "B"]]))
        XCTAssertTrue(store.interactions.isEmpty)
    }

    func testDenyUsesTheCorrectReplyKind() {
        let store = OpenCodeInteractionStore()
        var permissionReply: OpenCodeInteractionReply?
        var questionReply: OpenCodeInteractionReply?
        let p = permission(request: "p")
        let q = question(request: "q")

        XCTAssertTrue(store.receive(p) { permissionReply = $0 })
        XCTAssertTrue(store.receive(q) { questionReply = $0 })

        store.deny(p.id)
        store.deny(q.id)

        XCTAssertEqual(permissionReply, .permissionReject)
        XCTAssertEqual(questionReply, .questionReject)
    }

    func testDuplicateRequestDoesNotReplaceItsResponder() {
        let store = OpenCodeInteractionStore()
        var first: OpenCodeInteractionReply?
        var duplicate: OpenCodeInteractionReply?
        let item = permission()

        XCTAssertTrue(store.receive(item) { first = $0 })
        XCTAssertFalse(store.receive(item) { duplicate = $0 })

        store.allowOnce(item.id)

        XCTAssertEqual(first, .permissionOnce)
        XCTAssertNil(duplicate)
    }

    func testCancelAllRejectsEachInteractionByKind() {
        let store = OpenCodeInteractionStore()
        var permissionReply: OpenCodeInteractionReply?
        var questionReply: OpenCodeInteractionReply?

        XCTAssertTrue(store.receive(permission(request: "p")) { permissionReply = $0 })
        XCTAssertTrue(store.receive(question(request: "q")) { questionReply = $0 })

        store.cancelAll()

        XCTAssertEqual(permissionReply, .permissionReject)
        XCTAssertEqual(questionReply, .questionReject)
        XCTAssertTrue(store.interactions.isEmpty)
    }

    func testExternalResolutionReleasesOnlyTheMatchingPendingRequest() {
        let store = OpenCodeInteractionStore()
        var first: OpenCodeInteractionReply?
        var second: OpenCodeInteractionReply?
        let a = permission(session: "session-a", request: "request-a")
        let b = permission(session: "session-b", request: "request-b")

        XCTAssertTrue(store.receive(a) { first = $0 })
        XCTAssertTrue(store.receive(b) { second = $0 })

        store.resolveExternally(sessionID: "session-a", requestID: "request-a")

        XCTAssertEqual(first, .resolvedExternally)
        XCTAssertNil(second)
        XCTAssertEqual(store.interactions.map(\.id), [b.id])
    }

    func testSessionOnlyExternalResolutionUsesTheOldestBlockingRequest() {
        let store = OpenCodeInteractionStore()
        var first: OpenCodeInteractionReply?
        var second: OpenCodeInteractionReply?

        let older = OpenCodeInteraction(
            sessionID: "s1",
            requestID: "old",
            kind: permission(request: "old").kind,
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let newer = OpenCodeInteraction(
            sessionID: "s1",
            requestID: "new",
            kind: permission(request: "new").kind,
            createdAt: Date(timeIntervalSince1970: 20)
        )

        XCTAssertTrue(store.receive(older) { first = $0 })
        XCTAssertTrue(store.receive(newer) { second = $0 })

        store.resolveExternally(sessionID: "s1")

        XCTAssertEqual(first, .resolvedExternally)
        XCTAssertNil(second)
        XCTAssertEqual(store.interactions.map(\.requestID), ["new"])
    }

    func testWireRepliesUsePluginDecisionVocabulary() throws {
        let once = OpenCodeInteractionWireReply.encode(.permissionOnce)
        let always = OpenCodeInteractionWireReply.encode(.permissionAlways)
        let reject = OpenCodeInteractionWireReply.encode(.questionReject)
        let answer = OpenCodeInteractionWireReply.encode(.questionAnswers([["A"], ["B", "C"]]))
        let resolved = OpenCodeInteractionWireReply.encode(.resolvedExternally)

        XCTAssertEqual(once.decision, "once")
        XCTAssertEqual(always.decision, "always")
        XCTAssertEqual(reject.decision, "reject")
        XCTAssertEqual(answer.decision, "answer")
        XCTAssertEqual(answer.answers, [["A"], ["B", "C"]])
        XCTAssertEqual(resolved.decision, "resolved")

        XCTAssertNoThrow(try JSONEncoder().encode(answer))
    }
}

final class OpenCodePluginInstallerTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDownWithError() throws {
        for root in roots {
            try? FileManager.default.removeItem(at: root)
        }
        roots = []
    }

    private func root() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codenotch-plugin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(root)
        return root
    }

    func testDestinationDoesNotOverlapCodeIslandPlugin() throws {
        let home = try root()
        let destination = OpenCodePluginInstaller.destination(home: home)

        XCTAssertEqual(
            destination.path,
            home.appendingPathComponent(".config/opencode/plugins/codenotch.js").path
        )
        XCTAssertNotEqual(
            destination.lastPathComponent,
            "codeisland.js"
        )
    }

    func testInstallCopiesOnlyCodenotchPluginAndStatusTracksContent() throws {
        let home = try root()
        let source = home.appendingPathComponent("bundled.js")
        try Data("plugin-v1".utf8).write(to: source)

        let destination = OpenCodePluginInstaller.destination(home: home)
        let codeIsland = destination.deletingLastPathComponent().appendingPathComponent("codeisland.js")
        try FileManager.default.createDirectory(
            at: codeIsland.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("leave-me-alone".utf8).write(to: codeIsland)

        XCTAssertEqual(
            OpenCodePluginInstaller.status(destination: destination, bundledPlugin: source),
            .notInstalled
        )

        try OpenCodePluginInstaller.install(destination: destination, bundledPlugin: source)

        XCTAssertEqual(
            OpenCodePluginInstaller.status(destination: destination, bundledPlugin: source),
            .current
        )
        XCTAssertEqual(try Data(contentsOf: destination), Data("plugin-v1".utf8))
        XCTAssertEqual(try Data(contentsOf: codeIsland), Data("leave-me-alone".utf8))

        try Data("plugin-v2".utf8).write(to: source)
        XCTAssertEqual(
            OpenCodePluginInstaller.status(destination: destination, bundledPlugin: source),
            .outdated
        )
    }
}
