import AppKit
import SwiftUI

@MainActor
final class OpenCodeQuestionWindowController: NSObject, NSWindowDelegate {
    private var windows: [String: NSWindowController] = [:]

    func present(
        _ interaction: OpenCodeInteraction,
        onAnswer: @escaping ([[String]]) -> Void,
        onSkip: @escaping () -> Void
    ) {
        guard case .question(let request) = interaction.kind else { return }

        if let existing = windows[interaction.id]?.window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 520),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.t("OpenCode question")
        window.minSize = NSSize(width: 420, height: 360)
        window.isReleasedWhenClosed = false
        window.delegate = self

        let root = OpenCodeQuestionAnswerView(
            request: request,
            answer: { [weak self, weak window] answers in
                onAnswer(answers)
                window?.close()
                self?.windows[interaction.id] = nil
            },
            skip: { [weak self, weak window] in
                onSkip()
                window?.close()
                self?.windows[interaction.id] = nil
            }
        )

        window.contentViewController = NSHostingController(rootView: root)
        let controller = NSWindowController(window: window)
        windows[interaction.id] = controller

        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func reconcile(_ interactions: [OpenCodeInteraction]) {
        let live = Set(interactions.map(\.id))
        let stale = windows.keys.filter { !live.contains($0) }
        for id in stale {
            windows[id]?.close()
            windows[id] = nil
        }
    }

    func closeAll() {
        let current = Array(windows.values)
        windows.removeAll()
        for controller in current { controller.close() }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let id = windows.first(where: { $0.value.window === window })?.key
        else { return }
        windows[id] = nil
    }
}

private struct OpenCodeQuestionAnswerView: View {
    let request: OpenCodeQuestionRequest
    let answer: ([[String]]) -> Void
    let skip: () -> Void

    @State private var selected: [Int: Set<String>] = [:]
    @State private var custom: [Int: String] = [:]

    private var answers: [[String]] {
        request.questions.enumerated().map { index, question in
            var values = Array(selected[index] ?? []).sorted()
            let typed = (custom[index] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !typed.isEmpty {
                // A custom answer is an alternative to the selected option for
                // single-choice questions. Multi-select may deliberately combine
                // predefined choices with free text.
                if question.multiSelect {
                    values.append(typed)
                } else {
                    values = [typed]
                }
            }
            return values
        }
    }

    private var canSubmit: Bool {
        answers.count == request.questions.count && answers.allSatisfy { !$0.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.t("OpenCode is waiting for your answer"))
                    .font(.system(size: 18, weight: .semibold))
                if let cwd = request.cwd, !cwd.isEmpty {
                    Text(URL(fileURLWithPath: cwd).lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Array(request.questions.enumerated()), id: \.offset) { index, question in
                        questionBlock(question, index: index)
                    }
                }
                .padding(20)
            }

            Divider()

            HStack {
                Button(L10n.t("Skip")) { skip() }
                Spacer()
                Button(L10n.t("Submit")) { answer(answers) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
            }
            .padding(16)
        }
        .frame(minWidth: 420, minHeight: 360)
    }

    @ViewBuilder
    private func questionBlock(_ question: OpenCodeQuestion, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let header = question.header, !header.isEmpty {
                Text(header)
                    .font(.headline)
            }

            Text(question.question)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)

            if !question.options.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(question.options, id: \.label) { option in
                        optionRow(option, question: question, index: index)
                    }
                }
            }

            TextField(
                question.options.isEmpty
                    ? L10n.t("Your answer")
                    : L10n.t("Custom answer (optional)"),
                text: Binding(
                    get: { custom[index] ?? "" },
                    set: { custom[index] = $0 }
                )
            )
            .textFieldStyle(.roundedBorder)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private func optionRow(
        _ option: OpenCodeQuestionOption,
        question: OpenCodeQuestion,
        index: Int
    ) -> some View {
        Button {
            toggle(option.label, multi: question.multiSelect, index: index)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isSelected(option.label, index: index)
                      ? (question.multiSelect ? "checkmark.square.fill" : "largecircle.fill.circle")
                      : (question.multiSelect ? "square" : "circle"))
                    .foregroundStyle(
                        isSelected(option.label, index: index)
                            ? Color.accentColor
                            : Color(nsColor: .secondaryLabelColor)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .foregroundStyle(.primary)
                    if let description = option.description, !description.isEmpty {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func isSelected(_ label: String, index: Int) -> Bool {
        selected[index]?.contains(label) == true
    }

    private func toggle(_ label: String, multi: Bool, index: Int) {
        if multi {
            var values = selected[index] ?? []
            if values.contains(label) {
                values.remove(label)
            } else {
                values.insert(label)
            }
            selected[index] = values
        } else {
            selected[index] = isSelected(label, index: index) ? [] : [label]
        }
    }
}
