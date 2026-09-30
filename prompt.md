Build a native iOS/iPadOS app that remotely monitors and controls Syncthing instances
via Syncthing's REST API. Work as an autonomous engineer in this repository.

## How to work
- First, restate your understanding and produce a short plan + todo list. Don't start
  coding until the plan covers project setup, architecture, and phase-1 features.
- Build incrementally. After each meaningful chunk, verify it compiles with
  `xcodebuild` against an iPhone simulator, and run tests. Do not move on from broken
  code.
- Commit in logical, small units with clear messages.
- Fetch the live REST API docs before implementing networking and whenever unsure of a
  request/response shape: https://docs.syncthing.net/dev/rest.html and the per-endpoint
  pages linked from it. The interface changes between versions — decode defensively and
  ignore unknown fields. Do not invent endpoint shapes from memory.
- Ask me before any irreversible scope decision; otherwise proceed and note assumptions
  in commit messages and the README.
- Create a CLAUDE.md capturing the architecture, conventions, and how to build/test, so
  future sessions have context.

## Prerequisites & project setup
- Assume macOS with Xcode + command line tools installed.
- Generate the project declaratively so it's reproducible from the terminal: use
  XcodeGen (a `project.yml`) — NOT a hand-edited .pbxproj. If XcodeGen isn't available,
  install it or fall back to a Swift Package where feasible. The project must build and
  test headlessly via `xcodebuild -scheme <name> -destination 'platform=iOS
  Simulator,name=iPhone 15'`.
- Set up a test target from the start.

## What the app is
A remote controller — it does NOT run Syncthing itself. It talks to Syncthing daemons
running elsewhere (NAS, home server, Raspberry Pi, VPS) over their REST API. Same
architecture on iPhone and iPad.

## Unified-architecture requirement (non-negotiable)
- Single shared codebase across iOS 17+ and iPadOS 17+. iPhone and iPad use the exact
  same path: same networking client, same models, same view models.
- ONLY the presentation layer adapts per idiom (NavigationStack on iPhone,
  NavigationSplitView / master-detail on iPad). No idiom gets a different API layer.
- 90%+ shared code; idiom-specific code isolated to thin view/adapter files. Support
  iPad multitasking (Split View / Stage Manager) and both orientations.

## Stack
- SwiftUI, Swift Concurrency (async/await), URLSession. Swift Observation (@Observable)
  / MVVM. No third-party runtime dependencies unless justified (XcodeGen is a dev tool,
  not a runtime dep).
- Secrets in the Keychain. Non-secret settings in SwiftData or UserDefaults.
- One API client behind `protocol SyncthingAPIClient` so it's mockable; reused verbatim
  on both idioms.

## Connecting to a Syncthing instance
Each "server": display name, base URL (scheme+host+port, e.g.
https://192.168.1.10:8384 or http://homeserver.local:8384), API key (from Syncthing GUI:
Actions → Settings → API Key). Support MULTIPLE servers, switchable in the UI.

Auth: send `X-API-Key: <key>` on every request (Bearer token also accepted).

Self-signed cert handling (required): Syncthing's GUI commonly serves HTTPS with a
self-signed cert. Implement a URLSessionDelegate that lets the user trust a specific
server's cert on first connect (show fingerprint, confirm, then pin it). Never disable
TLS validation globally.

Validate a new connection with GET /rest/noauth/health (no key), then
GET /rest/system/status and GET /rest/system/version.

## Core features (MVP)
1. Server list: add / edit / remove (name, URL, API key). Bonus: add via QR code
   encoding {name,url,apiKey}.
2. Dashboard per server: device ID, version, uptime, connection state, total up/down
   rates, connected device count, system errors.
3. Folders: list with sync state + completion %; detail with state, file/dir/byte
   counts, out-of-sync items, last scan; actions Rescan and Pause/Resume.
4. Devices: list remote devices (connected/disconnected, address, per-device
   completion %, transfer rates, last seen); Pause/Resume a device.
5. Pending requests: surface pending devices and folders to approve or dismiss.
6. Live updates via the Event API: long-poll GET /rest/events?since=<lastID>, apply
   events to update the UI in near-real-time; fall back to timed polling if the stream
   drops. Pause the long-poll on backgrounding, resume on foreground. This event-reducer
   is shared code and must be unit-tested.
7. Global per-server controls: Restart, Pause all, Resume all. Guard destructive actions
   (Restart/Shutdown/Reset) behind confirmation.

## REST endpoints (Syncthing v2.x; base path /rest) — verify shapes against the docs
- Health/identity: GET /rest/noauth/health, /rest/system/status, /rest/system/version,
  /rest/system/ping
- Connections/transfer: GET /rest/system/connections
- Config (current API): GET/PUT/PATCH under /rest/config/... for folders, devices,
  options, gui. (/rest/system/config is DEPRECATED — prefer /rest/config.)
- Folder state: GET /rest/db/status?folder=, /rest/db/completion?folder=&device=,
  /rest/db/browse?folder=, /rest/db/need?folder=, POST /rest/db/scan?folder=,
  POST /rest/db/override, POST /rest/db/revert
- Errors: GET /rest/system/error, POST /rest/system/error/clear, GET /rest/folder/errors
- Pending: GET/DELETE /rest/cluster/pending/devices, /rest/cluster/pending/folders
- Stats: GET /rest/stats/device, /rest/stats/folder
- Versioning (restore): GET/POST /rest/folder/versions
- Lifecycle: POST /rest/system/pause, /resume, /restart, /shutdown
- Events: GET /rest/events?since=&limit= (and /rest/events/disk)

## UX / design
- Native look, same information architecture on both idioms. Master-detail on iPad,
  stacked navigation on iPhone. Adapt to size classes, don't hardcode.
- Clear sync-state color/iconography (Up to Date, Syncing, Scanning, Paused, Error,
  Out of Sync) with completion progress bars.
- Pull-to-refresh, empty states, explicit connection-error banners.
- Dark Mode, Dynamic Type, Reduced Motion. iPad keyboard shortcuts are a plus.

## Non-functional
- Networking behind a protocol so it's mockable. Unit tests for JSON decoding and the
  event-stream reducer.
- Handle timeouts, offline, wrong API key (401/403), unreachable host with specific,
  human-readable messages.
- No secrets in logs. API keys only in Keychain. No analytics/telemetry by default.
- Localizable strings; English baseline.

## Definition of done (phase 1)
- `xcodebuild` builds cleanly for the iOS simulator and all tests pass.
- App runs on both an iPhone and an iPad simulator with the shared architecture intact.
- README: setup, how to get a Syncthing API key, the cert-trust flow, and how to
  build/test from the terminal.
- CLAUDE.md documents architecture and conventions.

## Phasing
- Phase 1 (MVP): servers, dashboard, folders, devices, live events, basic controls.
- Phase 2: pending approvals, versioning/restore, editing folder/device config, widgets,
  QR add.

Start by confirming the plan and setting up the buildable project skeleton.
