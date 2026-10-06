import SwiftUI

/// OpenCode keeps two independent pieces of state in Codenotch:
///
/// - the existing OpenCode Go account supplies usage windows;
/// - this switch installs Codenotch's local OpenCode plugin so sessions can
///   surface permission/question requests.
///
/// They share the same OpenCode identity in the notch, but neither requires the
/// other to be signed in.
struct OpenCodeSettingsView: View {
    @ObservedObject var preferences: Preferences

    @State private var pluginStatus = OpenCodePluginInstaller.status()
    @State private var errorText: String?

    private var sessionsBinding: Binding<Bool> {
        Binding(
            get: { preferences.openCodeSessionsEnabled },
            set: { setSessionsEnabled($0) }
        )
    }

    private var statusText: String {
        switch pluginStatus {
        case .notInstalled: return L10n.t("Not installed")
        case .current:      return L10n.t("Installed")
        case .outdated:     return L10n.t("Update available")
        case .unavailable:  return L10n.t("Plugin unavailable")
        }
    }

    var body: some View {
        Form {
            Section(L10n.t("Local sessions")) {
                Toggle(L10n.t("Monitor and interact with OpenCode sessions"),
                       isOn: sessionsBinding)

                Text(L10n.t("Reads local OpenCode session state and lets Codenotch handle permission requests and questions. This does not require an OpenCode Go subscription."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(L10n.t("OpenCode plugin")) {
                LabeledContent(L10n.t("Status")) {
                    Text(statusText)
                        .foregroundStyle(pluginStatus == .current ? .primary : .secondary)
                }

                HStack(spacing: 8) {
                    Button(pluginStatus == .current
                           ? L10n.t("Reinstall")
                           : L10n.t("Install or update")) {
                        install()
                    }

                    if pluginStatus != .notInstalled {
                        Button(L10n.t("Remove")) {
                            remove()
                        }
                    }
                }

                Text(L10n.t("Codenotch installs only ~/.config/opencode/plugins/codenotch.js. Other plugin files are left untouched. Restart a running OpenCode process after installing or updating the plugin."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let errorText {
                    Text(errorText)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { refreshStatus() }
    }

    private func setSessionsEnabled(_ enabled: Bool) {
        errorText = nil
        if enabled {
            do {
                try OpenCodePluginInstaller.install()
                pluginStatus = .current
                // Session activity is rendered on the existing OpenCode ring.
                // Turning the capability on therefore makes that existing cell
                // visible if it was off; turning the capability off below does
                // not hide the ring, because OpenCode Go usage may still need it.
                preferences.setConnected(true, for: "opencode")
                preferences.openCodeSessionsEnabled = true
            } catch {
                preferences.openCodeSessionsEnabled = false
                refreshStatus()
                errorText = L10n.t("Could not install the OpenCode plugin: \(error.localizedDescription)")
            }
        } else {
            preferences.openCodeSessionsEnabled = false
            do {
                try OpenCodePluginInstaller.uninstall()
            } catch {
                errorText = L10n.t("Could not remove the OpenCode plugin: \(error.localizedDescription)")
            }
            refreshStatus()
        }
    }

    private func install() {
        errorText = nil
        do {
            try OpenCodePluginInstaller.install()
            refreshStatus()
        } catch {
            refreshStatus()
            errorText = L10n.t("Could not install the OpenCode plugin: \(error.localizedDescription)")
        }
    }

    private func remove() {
        errorText = nil
        preferences.openCodeSessionsEnabled = false
        do {
            try OpenCodePluginInstaller.uninstall()
        } catch {
            errorText = L10n.t("Could not remove the OpenCode plugin: \(error.localizedDescription)")
        }
        refreshStatus()
    }

    private func refreshStatus() {
        pluginStatus = OpenCodePluginInstaller.status()
    }
}
