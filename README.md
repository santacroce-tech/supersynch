# SuperSynch

SuperSynch runs **[Syncthing](https://syncthing.net) on your iPhone and iPad**, so your phone becomes a Syncthing device of its own. It syncs folders directly with Syncthing on your Mac (or any other device), peer to peer and end-to-end encrypted. No server is involved, and nothing on your Mac has to be exposed.

- Embeds Syncthing **v2.1.5** (compiled for iOS with gomobile) behind a small Go bridge.
- Native SwiftUI on iOS/iPadOS 17+, Swift 6. iPhone uses a `NavigationStack`; iPad uses a three-column `NavigationSplitView`. Everything else is shared code.
- No analytics. Syncthing's usage reporting, crash reporting, auto-upgrade and web GUI are all turned off.

## Features

| Area | What you get |
|---|---|
| Pairing | This device's ID as a QR code (copy/share). Add your Mac by pasting or **scanning** its ID; addresses can be automatic (discovery) or manual (`tcp://macbook.local:22000`). |
| Folders | Create folders, accept folders your Mac offers, choose which devices to share with, send-receive / send-only / receive-only, pause/resume, rescan, remove. Detail view shows sync state, counts, out-of-sync items, failed items and per-device completion. |
| Files | Synced folders live in **Files › On My iPhone › SuperSynch** and are usable from any app. There's also an in-app browser with Quick Look preview and sharing. You can also sync **into a folder you pick elsewhere** (security-scoped bookmark; see limitations). |
| Devices | Connection state, address, completion, last seen, shared folders; pause/resume, edit, remove. |
| Pending | Devices that try to connect and folders offered to you: **Add** or **Ignore**. |
| Live status | Syncthing's event stream drives the UI in real time, including transfer rates and sync progress. |
| Background | Keeps syncing for a short while after you leave the app, then iOS-scheduled background syncs (see below). |
| UX | Colour and icon per sync state, pull-to-refresh, empty states, error banners, Dark Mode, Dynamic Type, Reduce Motion, iPad keyboard shortcuts. |

## Pairing with your Mac

1. **On the iPhone**, open SuperSynch → **This Device** → *Show Device ID*.
2. **On the Mac**, open Syncthing's GUI (`http://127.0.0.1:8384`) → **Add Remote Device**. Paste the ID; the Mac's GUI can also scan the QR code from a screenshot. Give it a name.
3. **On the iPhone**, go to **Devices → +** and paste or scan the Mac's ID (Mac: *Actions → Show ID*).
4. Share folders:
   - **From the Mac:** edit a folder → *Sharing* → tick the iPhone. It appears on the phone under **Pending Requests**; tap *Add…* to accept it into SuperSynch.
   - **From the phone:** **Folders → +**, tick the Mac under *Share With*. Accept it on the Mac.

If the two can't find each other on your network, set the Mac's address manually when adding it on the phone (*Connection → Manual*, e.g. `tcp://192.168.1.20:22000`). Global discovery and relays are on by default, so devices also find each other across networks.

## How iOS limits syncing (important)

iOS doesn't let apps run continuously in the background, so SuperSynch can't stay in sync with your Mac around the clock the way two desktops do. It syncs:

1. **While the app is open.** This is the reliable way to sync.
2. **For ~30 seconds after you leave it.** It finishes in-progress transfers, then shuts Syncthing down cleanly.
3. **When iOS grants background time.** It uses a short app-refresh window, and a longer processing window that iOS typically grants while charging on Wi-Fi. iOS decides when these happen.

When the phone isn't running, your Mac queues the changes, and they sync the next time the app runs.

**Local discovery:** iOS requires a special Apple entitlement (multicast networking) for apps to send the LAN broadcasts that Syncthing's local discovery uses. Until that entitlement is granted, use global discovery (on by default) or a manual address.

**Folders outside the app:** syncing into a folder picked from another location works for local storage such as "On My iPhone" folders of other apps. Cloud-backed locations like iCloud Drive can evict downloaded copies or coordinate writes in ways Syncthing doesn't expect, so they're not recommended.

## Architecture

```
go/stbridge/          Go bridge around Syncthing's lib/syncthing (App + Internals).
                      Exposes a Node to Swift; data crosses as JSON shaped like
                      Syncthing's REST API. Re-implements the folder-summary
                      service (Syncthing only starts it with its web GUI).
Frameworks/           Stbridge.xcframework (generated; scripts/build-bridge.sh)
SyncthingKit/         Shared Swift core: SyncEngine (node lifecycle),
                      EmbeddedSyncthingClient (async wrapper), models, event
                      reducer, SyncSession, AppModel
SuperSynch/           SwiftUI app (views only) + background-sync scheduling
```

## Building & testing

Requirements: macOS with Xcode 16+ (developed on Xcode 27), Go 1.26+, and XcodeGen (`brew install xcodegen`). gomobile is installed automatically by the build script.

```sh
scripts/build-bridge.sh          # Go → Frameworks/Stbridge.xcframework (~30 s; skipped if up to date)
xcodegen generate                # project.yml → SuperSynch.xcodeproj (not committed)
xcodebuild -scheme SuperSynch -destination 'platform=iOS Simulator,name=iPhone 15' test
# or all of the above, with filtered output:
scripts/test.sh                  # default device "iPhone 15"
```

The tests run the **real embedded Syncthing inside the simulator** (start/stop/restart, folder management, live summaries), plus unit tests for decoding, the event reducer and the session.

### End-to-end sync test (optional)
This syncs files both ways between the embedded node and a separate Syncthing standing in for your Mac. It uses its own ports (22001/8386) and never touches a Syncthing you already run:

```sh
scripts/e2e-peer.sh /path/to/syncthing            # starts the throwaway peer
TEST_RUNNER_PEER_URL=http://127.0.0.1:8386 TEST_RUNNER_PEER_API_KEY=e2e-key scripts/test.sh
(cd go && PEER_URL=http://127.0.0.1:8386 PEER_API_KEY=e2e-key go test -tags noassets ./stbridge/)
```

> **Simulator note:** the simulator shares your Mac's network. When you run the app (not the tests) in the simulator, its Syncthing listens on the default port 22000, which conflicts with a Syncthing already running on the Mac. Prefer a real device or demo mode for UI work.

### Demo mode
`-DemoMode` runs the UI against sample data without starting Syncthing:
```sh
xcrun simctl launch booted xyz.santacroce.SuperSynch -DemoMode -DemoSection folders -DemoFolder photos
```

## Decisions & assumptions
- **Embedded engine with a custom Go bridge** (not the local REST API). Remote control of other Syncthing instances was dropped.
- Syncthing is pinned by commit (`v2.1.5`). Its `v2` tags don't use a `/v2` module path, so Go resolves it as a pseudo-version. It's built with `-tags noassets`, since the web GUI isn't needed.
- Storage locations:
  - Folders: `Documents/` by default, which is why they appear in the Files app.
  - Config, certificate and key: `Application Support/Syncthing/config`. These are backed up, so a restored phone keeps its device ID.
  - Index database: `Application Support/Syncthing/data`, excluded from backup because it can be rebuilt.
- Dismissing a pending request **ignores** it in config, like the web GUI's *Ignore*.
- Bundle ID: `xyz.santacroce.SuperSynch`.
- Syncthing is MPL-2.0. The app links it unmodified; the source is at github.com/syncthing/syncthing.

## Roadmap
File versioning and restore, ignore patterns, conflict resolution UI, selective/on-demand sync (download individual files via the bridge's block API), a File Provider extension, widgets, and requesting the multicast entitlement for local discovery.
