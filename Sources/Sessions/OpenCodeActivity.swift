import Combine
import Foundation
import SQLite3

/// Generic local OpenCode activity for the existing OpenCode provider.
///
/// This is deliberately separate from `OpenCodeGeminiActivity`. The Gemini
/// reader answers "is the Gemini API key being used?" and therefore owns
/// OpenCode turns whose provider id is exactly `google`. This reader answers
/// "is OpenCode working locally?" for every other provider. Keeping that one
/// ownership rule here prevents the same OpenCode turn from appearing under
/// both the Gemini API and OpenCode cards.
///
/// OpenCode writes `time.completed` only after an assistant turn finishes.
/// An assistant row without it is therefore the authoritative busy marker used
/// here. The stale bound protects against a server that died before it could
/// write completion.
enum OpenCodeActivity {
    static var database: URL { OpenCodeGeminiUsage.database }

    static func read(
        database: URL = OpenCodeActivity.database,
        staleAfter: TimeInterval,
        now: Date = Date()
    ) -> [AgentSession] {
        guard let db = SQLiteStore.open(database) else { return [] }
        defer { sqlite3_close(db) }

        let cutoffMillis = Int((now.timeIntervalSince1970 - staleAfter) * 1000)
        guard let schema = OpenCodeSchema.of(db) else { return [] }
        let rows = SQLiteStore.rows(
            in: db,
            sql: schema.activitySQL(cutoffMillis: cutoffMillis),
            columns: 7
        )

        // Ownership is decided for the folded root, not row-by-row. A parent
        // and sub-agent may use different providers concurrently; if any live
        // turn in that root uses Google, the existing Gemini API reader owns the
        // whole folded row so the same work never appears in two provider cards.
        var geminiOwnedRoots: Set<String> = []
        var candidates: [String: AgentSession] = [:]
        var order: [String] = []

        for row in rows {
            let root = row[0]
            guard !root.isEmpty else { continue }
            guard let updated = Double(row[4]), Int(updated) >= cutoffMillis else { continue }
            guard let created = Double(row[3]) else { continue }
            guard let turn = unfinishedTurn(row[5], type: row[6]) else { continue }

            if turn.provider == "google" {
                geminiOwnedRoots.insert(root)
                continue
            }

            // Rows arrive newest first. Keep the first generic turn for this
            // folded root, while continuing to scan older sibling rows in case
            // one establishes Gemini ownership.
            guard candidates[root] == nil else { continue }

            let title = row[1]
            let directory = row[2]
            let name = title.isEmpty ? "OpenCode" : title
            let detail: String
            if directory.isEmpty {
                detail = L10n.t("Working")
            } else {
                detail = L10n.t("Working in \(URL(fileURLWithPath: directory).lastPathComponent)")
            }

            candidates[root] = AgentSession(
                id: "opencode.session.\(root)",
                name: name,
                detail: detail,
                state: .busy,
                waitingFor: nil,
                since: Date(timeIntervalSince1970: created / 1000)
            )
            order.append(root)
        }

        return order.compactMap { root in
            guard !geminiOwnedRoots.contains(root) else { return nil }
            return candidates[root]
        }
    }

    /// OpenCode 2.x stores the role in the row's `type` column and the
    /// provider under `model.providerID`; 1.x stores both in `data`.
    ///
    /// A missing provider is still a valid generic OpenCode turn. Only the
    /// exact `google` provider is excluded because the existing Gemini API
    /// activity reader already owns that turn.
    private struct UnfinishedTurn {
        let provider: String?
    }

    private static func unfinishedTurn(_ data: String, type: String) -> UnfinishedTurn? {
        guard let bytes = data.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: bytes),
              let message = object as? [String: Any]
        else { return nil }

        let role = type.isEmpty ? (message["role"] as? String) : type
        guard role == "assistant" else { return nil }

        let provider = (message["model"] as? [String: Any])?["providerID"] as? String
            ?? message["providerID"] as? String

        if let time = message["time"] as? [String: Any] {
            let completed = time["completed"]
            guard completed == nil || completed is NSNull else { return nil }
        }

        return UnfinishedTurn(provider: provider)
    }
}

/// Polls OpenCode's own local database and publishes activity under the existing
/// `opencode` provider id. Whether the OpenCode Go account is authenticated is
/// irrelevant: `ActivityCoordinator` starts this monitor when the user has
/// enabled the OpenCode provider, not when its usage request succeeds.
final class OpenCodeActivityMonitor: AgentActivityMonitor {
    @Published private(set) var sessions: [AgentSession] = []
    var sessionsPublisher: AnyPublisher<[AgentSession], Never> { $sessions.eraseToAnyPublisher() }

    private let database: URL
    private let interval: TimeInterval
    private let staleAfter: TimeInterval
    private var timer: Timer?

    init(
        database: URL = OpenCodeActivity.database,
        interval: TimeInterval = 2,
        staleAfter: TimeInterval = 45
    ) {
        self.database = database
        self.interval = interval
        self.staleAfter = staleAfter
    }

    func start() {
        stop()
        poll()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let found = OpenCodeActivity.read(
            database: database,
            staleAfter: staleAfter
        )
        guard found != sessions else { return }
        sessions = found
    }
}
