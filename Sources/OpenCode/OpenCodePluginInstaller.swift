import Foundation

enum OpenCodePluginInstaller {
    enum Status: Equatable {
        case notInstalled
        case current
        case outdated
        case unavailable
    }

    static var destination: URL {
        destination(home: FileManager.default.homeDirectoryForCurrentUser)
    }

    static func destination(home: URL) -> URL {
        home.appendingPathComponent(".config/opencode/plugins/codenotch.js")
    }

    static var bundledPlugin: URL? {
        Bundle.main.url(forResource: "codenotch-opencode", withExtension: "js")
            ?? Bundle.main.url(
                forResource: "codenotch-opencode",
                withExtension: "js",
                subdirectory: "Resources"
            )
    }

    static func status(
        destination: URL = OpenCodePluginInstaller.destination,
        bundledPlugin: URL? = OpenCodePluginInstaller.bundledPlugin
    ) -> Status {
        guard let bundledPlugin,
              let bundled = try? Data(contentsOf: bundledPlugin)
        else { return .unavailable }

        guard let installed = try? Data(contentsOf: destination) else {
            return .notInstalled
        }
        return installed == bundled ? .current : .outdated
    }

    static func install(
        destination: URL = OpenCodePluginInstaller.destination,
        bundledPlugin: URL? = OpenCodePluginInstaller.bundledPlugin
    ) throws {
        guard let bundledPlugin else {
            throw CocoaError(.fileNoSuchFile)
        }

        let fileManager = FileManager.default
        let directory = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let data = try Data(contentsOf: bundledPlugin)
        let temporary = directory.appendingPathComponent(".codenotch.js.\(UUID().uuidString).tmp")

        do {
            try data.write(to: temporary, options: .atomic)
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: destination)
            }
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    static func uninstall(
        destination: URL = OpenCodePluginInstaller.destination
    ) throws {
        guard FileManager.default.fileExists(atPath: destination.path) else { return }
        try FileManager.default.removeItem(at: destination)
    }
}
