# SuperSynch

A native iOS/iPadOS remote control for [Syncthing](https://syncthing.net). SuperSynch does **not** run Syncthing itself. It connects to Syncthing daemons running elsewhere (a NAS, home server, Raspberry Pi or VPS) through their REST API.

- iOS / iPadOS 17+, SwiftUI, Swift 6, no third-party runtime dependencies.
- One shared codebase. iPhone uses a `NavigationStack`; iPad uses a three-column `NavigationSplitView`. Everything else, from the networking client to the models, view models and screens, is the same code (≈98% of lines).
- Supports multiple servers, with live updates through Syncthing's event API.

## Features (phase 1)

| Area | What you get |
|---|---|
| Servers | Add, edit, remove and reorder servers (name, URL, API key). Switch between them from the toolbar. Paste a `{"name","url","apiKey"}` JSON configuration. |
| Dashboard | Device ID, version, platform, uptime, connection state, total download/upload rates, connected devices, folders needing attention, system errors (with Clear). |
| Folders | Sync state and completion bar. Detail view shows state, global/local file, directory and byte counts, out-of-sync items (`/rest/db/need`), failed items, last scan and per-device completion. Actions: **Rescan**, **Pause/Resume**. |
| Devices | Connected/disconnected/paused, address, completion, per-device transfer rates, last seen, shared folders. Actions: **Pause/Resume**. |
| Pending | Devices and folders waiting for approval: **Add** (built on the server's own config defaults) or **Dismiss**. |
| Live updates | Long-poll `GET /rest/events`, with timed polling as a fallback. Updates pause in the background and resume in the foreground. |
| Controls | Pause all, Resume all, Rescan all, **Restart** and **Shut down** (both require confirmation). |
| UX | Colour and icon per sync state, pull-to-refresh, empty states, connection-error banners, Dark Mode, Dynamic Type, Reduce Motion, iPad keyboard shortcuts. |

Keyboard shortcuts (iPad with a hardware keyboard):
- ⌘R — Refresh
- ⇧⌘R — Rescan all folders
- ⌘1 … ⌘4 — Dashboard / Folders / Devices / Pending
- ⇧⌘S — Rescan (on a folder's detail screen)
- ⇧⌘P — Pause/Resume (on a folder's or device's detail screen)
- ⌘N — Add server

## Connecting to Syncthing

### 1. Make the GUI reachable
Syncthing's GUI/REST API listens on `127.0.0.1:8384` by default. To reach it from your phone, set the GUI listen address to `0.0.0.0:8384` (or a specific LAN or VPN interface). You can do this in the web GUI under **Actions → Settings → GUI → GUI Listen Address**. Setting a GUI username and password is recommended; the API key works independently of them.

### 2. Get the API key
In the Syncthing web GUI, open **Actions → Settings → General**. The **API Key** field is there; copy it, or click *Generate* to rotate it. You can also run `syncthing cli config gui apikey get` on the host.

### 3. Add the server in SuperSynch
Enter a name (optional), the URL including the scheme and port (e.g. `https://192.168.1.10:8384` or `http://homeserver.local:8384`), and the API key. If you leave out the scheme, `https://` is assumed. A URL path prefix is kept, e.g. `https://example.com/syncthing/` behind a reverse proxy.

When you tap **Save**, SuperSynch checks the connection in this order:
1. `GET /rest/noauth/health` (no key)
2. `GET /rest/system/status`
3. `GET /rest/system/version`

The server is saved only if all three succeed. Otherwise you'll see a specific message, for example a rejected API key, an unreachable host or port, a timeout, being offline, or plain HTTP being refused for a remote host.

### Self-signed certificates (trust on first use)
Syncthing's HTTPS GUI uses a self-signed certificate by default, which iOS won't trust. When SuperSynch meets a certificate the system doesn't trust:

1. It shows the certificate's host, subject and **SHA-256 fingerprint**.
2. You compare that fingerprint with the one on the server. In Syncthing's config directory, run:
   ```sh
   openssl x509 -noout -fingerprint -sha256 -in https-cert.pem
   ```
3. If you tap **Trust**, the fingerprint is pinned **for that server only**. From then on, a connection is accepted only if the server presents exactly that certificate.

If the certificate later changes, SuperSynch refuses the connection. It shows a **Certificate Changed** warning and asks you to review the new certificate. TLS validation is never disabled. Certificates signed by a CA the system trusts (e.g. Let's Encrypt behind a reverse proxy) are accepted normally.

### Plain HTTP
App Transport Security allows plain `http://` only for local-network hosts (`.local` names, unqualified names and IP addresses). Remote servers must use HTTPS.

## Privacy & security
- API keys are stored only in the iOS Keychain (`AfterFirstUnlockThisDeviceOnly`, not synced). Non-secret settings (server name, URL, pinned fingerprint) are stored in `UserDefaults`.
- API keys are never logged.
- There's no analytics or telemetry. The app only talks to the servers you add.

## Building & testing

Requirements: macOS with Xcode 16+ (developed on Xcode 27) and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

The Xcode project is generated from `project.yml` and isn't committed:

```sh
xcodegen generate
open SuperSynch.xcodeproj            # optional
```

Build and test headlessly:

```sh
xcodebuild -scheme SuperSynch -destination 'platform=iOS Simulator,name=iPhone 15' test
# or, which regenerates the project and filters the output:
scripts/test.sh                      # default: "iPhone 15"
scripts/test.sh "iPad Pro 11-inch (M5)"
```

If you don't have an "iPhone 15" simulator, create one (`xcrun simctl create "iPhone 15" com.apple.CoreSimulator.SimDeviceType.iPhone-15 <runtime-id>`) or pass another device name.

### Demo mode
Launch with `-DemoMode` to use built-in sample data with no network access. This is handy for UI work and screenshots:

```sh
xcrun simctl launch booted xyz.santacroce.SuperSynch -DemoMode -DemoSection folders -DemoFolder photos
```

### Integration tests (optional)
`LiveIntegrationTests` runs against a real Syncthing. It is skipped unless `SYNCTHING_URL` and `SYNCTHING_API_KEY` are set; xcodebuild forwards `TEST_RUNNER_`-prefixed variables to the test runner. To run it against a throwaway instance:

```sh
syncthing generate --home=/tmp/st
syncthing serve --home=/tmp/st --no-browser --gui-address=https://127.0.0.1:8385 --gui-apikey=testkey123 &
TEST_RUNNER_SYNCTHING_URL=https://127.0.0.1:8385 TEST_RUNNER_SYNCTHING_API_KEY=testkey123 \
  xcodebuild -scheme SuperSynch -destination 'platform=iOS Simulator,name=iPhone 15' test
```

This was last verified against Syncthing **v2.1.5**.

## Assumptions & decisions
- **Bundle ID** `xyz.santacroce.SuperSynch`. Change it in `project.yml`.
- **Pending requests** are part of phase 1, since they're in the MVP feature list. Accepting a folder asks for its path on the server, pre-filled from the server's default folder path.
- **Folder pause/resume** uses `PATCH /rest/config/folders/{id}` with `{"paused": …}`. **Device pause/resume** and pause/resume-all use `POST /rest/system/pause|resume`.
- **Config** is read from `/rest/config/*`. The deprecated `/rest/system/config` is never used.
- **Transfer rates** are computed from `/rest/system/connections` byte-counter deltas, polled every 10 s, because events don't carry rates.
- `/rest/db/status` and `/rest/db/need` are expensive on the server. Status is loaded once and then kept current by `FolderSummary` events; "out of sync" items load only when you open that screen.
- Only the selected server's session runs, and only while the app is in the foreground.
- **Reset** (database reset) isn't exposed in phase 1.

## Roadmap (phase 2)
Versioning and restore (`/rest/folder/versions`), editing folder and device config, widgets, adding a server by QR code (the payload format `{"name","url","apiKey"}` is already supported via paste), and ignore patterns.
