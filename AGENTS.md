# AGENTS.md

This file contains development guidance for AI coding agents working on this fork.

## Read before editing

Before changing code, read:

1. `CONTRIBUTING.md`
2. Relevant sections of `TASKS.md`
3. Relevant files under `docs/specs/`, `docs/plans/`, and `docs/providers/`
4. The existing tests closest to the code being changed

Upstream project conventions remain authoritative unless this file adds a stricter fork-specific rule.

## General project rules

- Preserve Codenotch's existing architecture and visual behavior unless a task explicitly requires a change.
- Comments should explain why a constraint or workaround exists, not restate what the code does.
- Avoid premature abstraction. Prefer small, local changes over introducing a framework for a single use case.
- Do not invent state, usage, quota, timing, or activity data. Unknown information must remain unknown.
- Every new behavior should have a focused test.
- Run `make test` before claiming a task is complete.
- For UI/layout changes, run the existing relevant geometry/render tests and inspect the associated design/spec documents.
- Do not modify release, signing, notarization, Sparkle, or maintainer-only release machinery unless explicitly requested.
- Keep changes suitable for upstreaming where practical.

## OpenCode integration scope

The OpenCode work in this fork is for **generic local OpenCode session support**.

That means:

- Codenotch should be able to observe and interact with local OpenCode sessions regardless of which model/provider the OpenCode session is using.
- OpenCode session support must not depend on an OpenCode Go subscription or an OpenCode account login.
- Existing `OpenCodeProvider` usage/quota behavior must remain separate from session interaction behavior.
- A local OpenCode session may use OpenCode-managed providers, custom providers, local providers, or other providers configured by the user.
- Do not hard-code DeepSeek, Gemini, OpenAI, Ollama, or any other model/provider into the session interaction layer.
- First-version scope is local OpenCode only. Remote OpenCode hosts, SSH forwarding, remote URLs, and remote control are out of scope unless explicitly added later.
- Do not add dependencies on a user's private MCP bridge, ChatGPT workflow, or machine-specific service. The integration should work with an ordinary local OpenCode installation.

## OpenCode interaction architecture

Keep these concerns separate:

- `AgentSession`: generic display/activity state used by Codenotch.
- OpenCode activity monitoring: translates local OpenCode lifecycle into Codenotch session state.
- OpenCode interactions: pending permission/question requests and their replies.
- OpenCode Go usage: existing provider/quota functionality.

Prefer linking an OpenCode interaction to an `AgentSession` by session ID instead of putting provider-specific permission/question payloads directly into `AgentSession`.

## OpenCode event source

Prefer authoritative OpenCode events over polling or inference whenever an event exists.

The compatibility layer should account for the OpenCode event families used by current and recent OpenCode versions, including as applicable:

- session lifecycle/status events
- tool lifecycle events
- permission requested/replied events
- question requested/replied/rejected events
- form created/replied/cancelled events

Do not infer that a permission or question has been resolved merely because an unrelated tool/session event arrived.

## Permission and question behavior

The interaction path must preserve request identity and route replies back to the exact originating session/request.

Permission behavior should support:

- deny/reject
- allow once
- always allow when OpenCode supports it

Question behavior should support, when provided by OpenCode:

- single choice
- multiple choice
- custom text input

Concurrent sessions and multiple pending requests must not answer or drain one another.

Subagent activity must not accidentally clear a parent session's pending interaction, and vice versa.

## Local transport

If a local helper/plugin transport is added:

- Use a Codenotch-specific name and socket path.
- Do not overwrite or modify another application's OpenCode plugin.
- Coexist with other OpenCode plugins where possible.
- Keep blocking permission/question round trips separate from fire-and-forget activity events.
- Treat peer disconnects and app shutdown as explicit failure/cancellation paths so an OpenCode request cannot wait forever because Codenotch disappeared.

## CodeIsland reference

The CodeIsland project may be used as a reference implementation for OpenCode interaction behavior.

When using it:

- Reuse behavior and proven edge-case handling where helpful.
- Prefer a Codenotch-native implementation instead of copying CodeIsland's UI/state architecture wholesale.
- Do not import CodeIsland-specific notch UI, push/phone/watch/BLE/ESP32/SSH features into the initial OpenCode work.
- Preserve applicable copyright and MIT license notices if substantial CodeIsland code is copied.

Important behaviors worth preserving from the reference include:

- OpenCode version compatibility
- blocking permission/question round trips
- exact request/session routing
- pending-request race guards
- permission decision mapping
- single/multi/custom question answers

## Initial acceptance tests

At minimum, the OpenCode interaction work should cover:

1. Local OpenCode session appears and transitions through active/idle/completed states.
2. Permission request -> allow once.
3. Permission request -> always allow, when supported.
4. Permission request -> deny.
5. Question -> predefined option.
6. Question -> custom text.
7. Multi-select question, when supported.
8. Two sessions waiting at the same time route answers correctly.
9. Subagent interaction does not corrupt the parent session's pending request.
10. A session using a non-Google/non-OpenCode-Go provider is still detected.
11. Codenotch and another OpenCode plugin can coexist without overwriting each other's plugin files.
12. Disconnect/shutdown does not leave stale Codenotch UI state.

## Completion checklist

Before reporting an implementation complete:

- Relevant tests were added or updated.
- `make test` passes, or any pre-existing failure is clearly identified.
- No existing provider semantics were changed unintentionally.
- No OpenCode account/login requirement was introduced for local session interaction.
- No model/provider-specific assumption was introduced into generic OpenCode session handling.
- No user secrets, tokens, API keys, or private paths were committed.
