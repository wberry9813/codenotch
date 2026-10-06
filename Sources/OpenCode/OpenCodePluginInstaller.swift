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

    static var bridgeDestination: URL {
        bridgeDestination(home: FileManager.default.homeDirectoryForCurrentUser)
    }

    static func bridgeDestination(home: URL) -> URL {
        home.appendingPathComponent(".codenotch/codenotch-bridge")
    }

    static var bundledPlugin: URL? {
        Bundle.main.url(forResource: "codenotch-opencode", withExtension: "js")
            ?? Bundle.main.url(
                forResource: "codenotch-opencode",
                withExtension: "js",
                subdirectory: "Resources"
            )
    }

    static var bundledBridge: URL? {
        Bundle.main.url(forResource: "codenotch-bridge", withExtension: nil)
            ?? Bundle.main.url(
                forResource: "codenotch-bridge",
                withExtension: nil,
                subdirectory: "Resources"
            )
    }

    static func status(
        destination: URL = OpenCodePluginInstaller.destination,
        bundledPlugin: URL? = OpenCodePluginInstaller.bundledPlugin,
        bridgeDestination: URL = OpenCodePluginInstaller.bridgeDestination,
        bundledBridge: URL? = OpenCodePluginInstaller.bundledBridge
    ) -> Status {
        guard let bundledPlugin,
              let bundledBridge,
              let bundledPluginData = try? Data(contentsOf: bundledPlugin),
              let bundledBridgeData = try? Data(contentsOf: bundledBridge)
        else { return .unavailable }

        guard let installedPlugin = try? Data(contentsOf: destination),
              let installedBridge = try? Data(contentsOf: bridgeDestination)
        else {
            return .notInstalled
        }

        let executable = FileManager.default.isExecutableFile(atPath: bridgeDestination.path)
        return installedPlugin == bundledPluginData
            && installedBridge == bundledBridgeData
            && executable
            ? .current
            : .outdated
    }

    static func install(
        destination: URL = OpenCodePluginInstaller.destination,
        bundledPlugin: URL? = OpenCodePluginInstaller.bundledPlugin,
        bridgeDestination: URL = OpenCodePluginInstaller.bridgeDestination,
        bundledBridge: URL? = OpenCodePluginInstaller.bundledBridge
    ) throws {
        guard let bundledPlugin, let bundledBridge else {
            throw CocoaError(.fileNoSuchFile)
        }

        let fileManager = FileManager.default

        let pluginDirectory = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: pluginDirectory, withIntermediateDirectories: true)
        try installFile(
            from: bundledPlugin,
            to: destination,
            temporaryName: ".codenotch.js.\(UUID().uuidString).tmp",
            executable: false,
            fileManager: fileManager
        )

        let bridgeDirectory = bridgeDestination.deletingLastPathComponent()
        try fileManager.createDirectory(at: bridgeDirectory, withIntermediateDirectories: true)
        try installFile(
            from: bundledBridge,
            to: bridgeDestination,
            temporaryName: ".codenotch-bridge.\(UUID().uuidString).tmp",
            executable: true,
            fileManager: fileManager
        )
    }

    private static func installFile(
        from source: URL,
        to destination: URL,
        temporaryName: String,
        executable: Bool,
        fileManager: FileManager
    ) throws {
        let data = try Data(contentsOf: source)
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(temporaryName)

        do {
            try data.write(to: temporary, options: .atomic)
            if executable {
                try fileManager.setAttributes(
                    [.posixPermissions: 0o700],
                    ofItemAtPath: temporary.path
                )
            }

            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: destination)
            }

            if executable {
                try fileManager.setAttributes(
                    [.posixPermissions: 0o700],
                    ofItemAtPath: destination.path
                )
            }
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    static func uninstall(
        destination: URL = OpenCodePluginInstaller.destination,
        bridgeDestination: URL = OpenCodePluginInstaller.bridgeDestination
    ) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        if fileManager.fileExists(atPath: bridgeDestination.path) {
            try fileManager.removeItem(at: bridgeDestination)
        }
    }
}
