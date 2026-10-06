import Foundation
import SQLite3
import XCTest
@testable import Codenotch

final class OpenCodeActivityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_789_000_000)
    private var databases: [URL] = []

    override func tearDownWithError() throws {
        for url in databases { try? FileManager.default.removeItem(at: url) }
        databases = []
    }

    private struct SessionRow {
        let id: String
        var parentID: String?
        var title: String = ""
        var directory: String = ""
        let updated: Date
    }

    private struct MessageRow {
        let id: String
        let sessionID: String
        var seq: Int = 1
        let created: Date
        let updated: Date
        let data: String
        var type: String = "assistant"
    }

    private func message(
        provider: String? = "deepseek-direct",
        role: String = "assistant",
        created: Date,
        completed: Date? = nil,
        v2: Bool = false
    ) -> String {
        var time: [String: Any] = [
            "created": Int(created.timeIntervalSince1970 * 1000)
        ]
        if let completed {
            time["completed"] = Int(completed.timeIntervalSince1970 * 1000)
        }

        var object: [String: Any] = [
            "role": role,
            "time": time
        ]
        if let provider {
            if v2 {
                object["model"] = ["providerID": provider, "modelID": "test"]
            } else {
                object["providerID"] = provider
                object["modelID"] = "test"
            }
        }

        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }

    private func makeV1Database(
        sessions: [SessionRow],
        messages: [MessageRow]
    ) throws -> URL {
        let url = temporary("opencode-v1")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        sqlite3_exec(db, """
        CREATE TABLE session (id TEXT, parent_id TEXT, title TEXT, directory TEXT,
                              time_updated INTEGER);
        CREATE TABLE message (id TEXT, session_id TEXT, time_created INTEGER,
                              time_updated INTEGER, data TEXT);
        """, nil, nil, nil)
        insertV1(sessions: sessions, messages: messages, db: db)
        sqlite3_close(db)
        return url
    }

    private func insertV1(
        sessions: [SessionRow],
        messages: [MessageRow],
        db: OpaquePointer?
    ) {
        for row in sessions {
            let parent = row.parentID.map { "'\($0)'" } ?? "NULL"
            sqlite3_exec(db, """
            INSERT INTO session VALUES ('\(row.id)', \(parent), '\(row.title)',
                                        '\(row.directory)',
                                        \(Int(row.updated.timeIntervalSince1970 * 1000)));
            """, nil, nil, nil)
        }
        for row in messages {
            sqlite3_exec(db, """
            INSERT INTO message VALUES ('\(row.id)', '\(row.sessionID)',
                                        \(Int(row.created.timeIntervalSince1970 * 1000)),
                                        \(Int(row.updated.timeIntervalSince1970 * 1000)),
                                        '\(row.data)');
            """, nil, nil, nil)
        }
    }

    private func makeV2Database(
        sessions: [SessionRow],
        messages: [MessageRow]
    ) throws -> URL {
        let url = temporary("opencode-v2")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        sqlite3_exec(db, """
        CREATE TABLE session_v2 (id TEXT, parent_id TEXT, title TEXT, directory TEXT,
                                 time_updated INTEGER);
        CREATE TABLE session_message (
            id TEXT, session_id TEXT, seq INTEGER, time_created INTEGER,
            time_updated INTEGER, data TEXT, type TEXT);
        """, nil, nil, nil)
        for row in sessions {
            let parent = row.parentID.map { "'\($0)'" } ?? "NULL"
            sqlite3_exec(db, """
            INSERT INTO session_v2 VALUES ('\(row.id)', \(parent), '\(row.title)',
                                           '\(row.directory)',
                                           \(Int(row.updated.timeIntervalSince1970 * 1000)));
            """, nil, nil, nil)
        }
        for row in messages {
            sqlite3_exec(db, """
            INSERT INTO session_message VALUES (
                '\(row.id)', '\(row.sessionID)', \(row.seq),
                \(Int(row.created.timeIntervalSince1970 * 1000)),
                \(Int(row.updated.timeIntervalSince1970 * 1000)),
                '\(row.data)', '\(row.type)');
            """, nil, nil, nil)
        }
        sqlite3_close(db)
        return url
    }

    private func temporary(_ label: String) -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(label)-\(UUID().uuidString).db")
        databases.append(url)
        return url
    }

    func testNonGoogleUnfinishedTurnAppearsUnderOpenCode() throws {
        let url = try makeV1Database(
            sessions: [SessionRow(
                id: "s1",
                title: "Refactor parser",
                directory: "/Users/x/Projects/codenotch",
                updated: now
            )],
            messages: [MessageRow(
                id: "m1",
                sessionID: "s1",
                created: now,
                updated: now,
                data: message(created: now)
            )]
        )

        let sessions = OpenCodeActivity.read(database: url, staleAfter: 45, now: now)

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.id, "opencode.session.s1")
        XCTAssertEqual(sessions.first?.name, "Refactor parser")
        XCTAssertEqual(sessions.first?.detail, "Working in codenotch")
        XCTAssertEqual(sessions.first?.state, .busy)
        XCTAssertEqual(sessions.first?.since, now)
    }

    func testGoogleTurnIsOwnedByGeminiReaderAndNotDuplicated() throws {
        let url = try makeV1Database(
            sessions: [SessionRow(id: "s1", directory: "/Users/x/Projects/codenotch", updated: now)],
            messages: [MessageRow(
                id: "m1",
                sessionID: "s1",
                created: now,
                updated: now,
                data: message(provider: "google", created: now)
            )]
        )

        XCTAssertTrue(OpenCodeActivity.read(database: url, staleAfter: 45, now: now).isEmpty)
        XCTAssertEqual(
            OpenCodeGeminiActivity.read(database: url, staleAfter: 45, now: now).count,
            1
        )
    }

    func testCompletedTurnDoesNotAppear() throws {
        let url = try makeV1Database(
            sessions: [SessionRow(id: "s1", updated: now)],
            messages: [MessageRow(
                id: "m1",
                sessionID: "s1",
                created: now,
                updated: now,
                data: message(created: now, completed: now)
            )]
        )

        XCTAssertTrue(OpenCodeActivity.read(database: url, staleAfter: 45, now: now).isEmpty)
    }

    func testStaleUnfinishedTurnDoesNotAppear() throws {
        let old = now.addingTimeInterval(-600)
        let url = try makeV1Database(
            sessions: [SessionRow(id: "s1", updated: now)],
            messages: [MessageRow(
                id: "m1",
                sessionID: "s1",
                created: old,
                updated: old,
                data: message(created: old)
            )]
        )

        XCTAssertTrue(OpenCodeActivity.read(database: url, staleAfter: 45, now: now).isEmpty)
    }

    func testSubagentFoldsIntoParentOnce() throws {
        let earlier = now.addingTimeInterval(-5)
        let url = try makeV1Database(
            sessions: [
                SessionRow(
                    id: "p1",
                    title: "Parent task",
                    directory: "/Users/x/Projects/codenotch",
                    updated: now
                ),
                SessionRow(id: "c1", parentID: "p1", title: "subagent", updated: now)
            ],
            messages: [
                MessageRow(
                    id: "m1",
                    sessionID: "p1",
                    created: earlier,
                    updated: earlier,
                    data: message(created: earlier)
                ),
                MessageRow(
                    id: "m2",
                    sessionID: "c1",
                    created: now,
                    updated: now,
                    data: message(created: now)
                )
            ]
        )

        let sessions = OpenCodeActivity.read(database: url, staleAfter: 45, now: now)

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.id, "opencode.session.p1")
        XCTAssertEqual(sessions.first?.name, "Parent task")
        XCTAssertEqual(sessions.first?.detail, "Working in codenotch")
    }

    func testMixedProviderSubagentRootBelongsOnlyToGeminiWhenAnyLiveTurnUsesGoogle() throws {
        let earlier = now.addingTimeInterval(-5)
        let url = try makeV1Database(
            sessions: [
                SessionRow(
                    id: "p1",
                    title: "Parent task",
                    directory: "/Users/x/Projects/codenotch",
                    updated: now
                ),
                SessionRow(id: "c1", parentID: "p1", title: "google subagent", updated: now)
            ],
            messages: [
                // Newer generic parent turn is encountered first by the SQL.
                MessageRow(
                    id: "m1",
                    sessionID: "p1",
                    created: now,
                    updated: now,
                    data: message(provider: "deepseek-direct", created: now)
                ),
                // An older-but-still-live Google subagent must still claim the
                // folded root for the existing Gemini API reader.
                MessageRow(
                    id: "m2",
                    sessionID: "c1",
                    created: earlier,
                    updated: earlier,
                    data: message(provider: "google", created: earlier)
                )
            ]
        )

        XCTAssertTrue(OpenCodeActivity.read(database: url, staleAfter: 45, now: now).isEmpty)

        let gemini = OpenCodeGeminiActivity.read(database: url, staleAfter: 45, now: now)
        XCTAssertEqual(gemini.count, 1)
        XCTAssertEqual(gemini.first?.id, "gemini-api.opencode.p1")
    }

    func testOpenCode2SchemaIsRead() throws {
        let url = try makeV2Database(
            sessions: [SessionRow(
                id: "s2",
                title: "OpenCode 2 task",
                directory: "/Users/x/Projects/codenotch",
                updated: now
            )],
            messages: [MessageRow(
                id: "m2",
                sessionID: "s2",
                created: now,
                updated: now,
                data: message(provider: "deepseek-direct", created: now, v2: true),
                type: "assistant"
            )]
        )

        let sessions = OpenCodeActivity.read(database: url, staleAfter: 45, now: now)

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.id, "opencode.session.s2")
        XCTAssertEqual(sessions.first?.name, "OpenCode 2 task")
    }

    func testMissingProviderStillCountsAsGenericOpenCodeActivity() throws {
        let url = try makeV1Database(
            sessions: [SessionRow(id: "s1", title: "Unknown provider", updated: now)],
            messages: [MessageRow(
                id: "m1",
                sessionID: "s1",
                created: now,
                updated: now,
                data: message(provider: nil, created: now)
            )]
        )

        XCTAssertEqual(
            OpenCodeActivity.read(database: url, staleAfter: 45, now: now).count,
            1
        )
    }
}
