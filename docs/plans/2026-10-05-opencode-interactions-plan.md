# Generic Local OpenCode Sessions and Interactions

## Goal

Add first-class local OpenCode session monitoring and direct permission/question
interaction to Codenotch without coupling the feature to OpenCode Go, a specific
model/provider, or a private bridge.

The feature must work for ordinary local OpenCode installations and for sessions
created indirectly by other local tooling.

## Non-goals for the first version

- Remote OpenCode hosts.
- SSH forwarding.
- Remote URLs.
- Chat transcript browsing.
- Push/mobile/watch/BLE interaction.
- Dependencies on a private MCP bridge.
- Model/provider-specific behavior.

## Existing architecture that must be preserved

Codenotch currently separates usage providers from session activity, but activity
is still keyed by the usage provider id:

- `ActivityCoordinator` owns `AgentActivityMonitor` instances by provider id.
- `NotchViewModel.sessions` is keyed by provider id.
- `NotchViewModel.activity(for:)` attaches those sessions to the matching
  provider snapshot/card.
- `preferences.connectedProviders` controls which activity monitors start.

The existing OpenCode usage provider id, `opencode`, means **OpenCode Go usage**.
That usage provider can legitimately be in `needsAuth` or show no Go
subscription.

The existing `OpenCodeGeminiActivity` is intentionally attributed to
`gemini-api`, because it represents work consuming a Gemini API key. It must
not silently lose that behavior.

## Important consequence

Do not implement generic OpenCode support by merely registering

```swift
"opencode": OpenCodeActivityMonitor()
```

without addressing display ownership.

That naive implementation creates two problems:

1. OpenCode session monitoring would appear coupled to whether the OpenCode Go
   provider is connected/signed in.
2. An OpenCode session using the Google provider could be reported both under
   the existing Gemini API activity and under a new OpenCode activity path.

The implementation must make local OpenCode session capability independent from
OpenCode Go authentication while preserving existing provider attribution where
it is already intentional.

## Target behavior

### Session capability

A local OpenCode session should be observable regardless of whether it uses:

- an OpenCode-managed model/provider,
- a custom provider,
- a local provider,
- DeepSeek,
- Gemini,
- OpenAI,
- Ollama,
- or another user-configured provider.

Codenotch must not need to understand the provider to understand that an
OpenCode session exists.

### Interaction capability

When OpenCode emits an actionable request, Codenotch should be able to represent
and answer it directly:

- permission: reject / once / always where supported,
- question: single-select,
- question: multi-select,
- question: custom text.

Replies must be routed to the exact originating session and request.

## Proposed separation

Keep `AgentSession` as Codenotch's generic display model.

Introduce an OpenCode-specific interaction state store keyed by OpenCode session
and request identity. Do not embed raw OpenCode permission/form payloads into
`AgentSession`.

Conceptually:

```
OpenCode local event/plugin
        |
        +--> activity/session normalization --> AgentSession
        |
        +--> actionable request -------------> OpenCodeInteractionStore
                                                  |
                                                  v
                                           Codenotch card UI
                                                  |
                                                  v
                                            exact reply route
```

## Activity ownership strategy

Before implementation, choose one explicit ownership rule and cover it with
tests.

Preferred direction:

- preserve existing provider-specific activity attribution where Codenotch
  already has authoritative behavior,
- add generic OpenCode session awareness without duplicating the same work in
  two provider cards,
- keep actionable OpenCode permission/question UI independent from whether a
  usage ring is authenticated.

If a session is represented under another provider card for usage/activity
reasons, the OpenCode interaction request must still be reachable and answerable
from Codenotch.

## Event source

Prefer authoritative OpenCode events for interaction state.

Compatibility should cover the current/recent event families as applicable:

- session lifecycle/status,
- tool lifecycle,
- `permission.asked` / replied,
- legacy/current permission variants,
- `question.asked` / replied / rejected,
- `form.created` / replied / cancelled.

Do not treat unrelated tool/session events as proof that a pending request was
answered.

## Local transport

If a plugin/helper transport is required:

- use a Codenotch-specific plugin filename,
- use a Codenotch-specific Unix socket path,
- coexist with other OpenCode plugins,
- do not overwrite CodeIsland's plugin,
- keep fire-and-forget activity separate from blocking permission/question
  round trips,
- explicitly handle app shutdown and peer disconnect.

## CodeIsland reference

CodeIsland's OpenCode integration is the behavior reference for:

- OpenCode version compatibility,
- blocking permission/question round trips,
- exact request/session routing,
- pending-request race guards,
- once/always/reject mapping,
- single/multi/custom question answers.

Use a Codenotch-native implementation. Do not import CodeIsland's complete
AppState, notch UI, remote, push, phone, watch, BLE, ESP32, or SSH systems.

## Suggested implementation phases

### Phase 1 — local session foundation

- Add generic local OpenCode session parsing/monitoring.
- Define and test ownership/deduplication against existing
  `OpenCodeGeminiActivity`.
- Ensure activity can exist without an OpenCode Go login.

### Phase 2 — interaction transport/state

- Add Codenotch OpenCode plugin/helper transport.
- Add permission/question request models and exact routing.
- Add disconnect/cancellation handling.
- Add concurrency/race tests.

### Phase 3 — edge interaction UI

- Add permission card.
- Add question card.
- Integrate pending interactions with the existing edge/tooltip surface.
- Preserve multi-display and existing geometry behavior.

## Acceptance cases

1. Local OpenCode session becomes visible without OpenCode Go authentication.
2. Non-Google OpenCode session is detected.
3. Google-backed OpenCode work is not duplicated across cards.
4. Permission -> allow once.
5. Permission -> always, when supported.
6. Permission -> reject.
7. Question -> predefined option.
8. Question -> custom input.
9. Question -> multi-select, when supported.
10. Two simultaneous sessions cannot answer each other's requests.
11. Subagent activity cannot clear the parent's pending request.
12. Another installed OpenCode plugin can coexist.
13. Closing Codenotch does not leave stale local UI state or an indefinitely
    blocked Codenotch-owned request.
