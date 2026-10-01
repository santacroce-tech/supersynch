# SuperSynch

SuperSynch runs **[Syncthing](https://syncthing.net) on your iPhone and iPad**, so your phone becomes a Syncthing device of its own. It syncs folders directly with Syncthing on your Mac (or any other device), peer to peer and end-to-end encrypted. No server is involved, and nothing on your Mac has to be exposed.

- Embeds Syncthing **v2.1.5** (compiled for iOS with gomobile) behind a small Go bridge.
- Native SwiftUI on iOS/iPadOS 17+, Swift 6. iPhone uses a `NavigationStack`; iPad uses a three-column `NavigationSplitView`. Everything else is shared code.
- No analytics. Syncthing's usage reporting, crash reporting, auto-upgrade and web GUI are all turned off.

> iOS doesn't allow continuous background syncing, and some features of desktop Syncthing aren't available yet. See **[Limitations](#limitations)** before relying on it.

## Features

| Area | What you get |
|---|---|
| Pairing | This device's ID as a QR code (copy/share). Add your Mac by pasting or **scanning** its ID; addresses can be automatic (discovery) or manual (`tcp://macbook.local:22000`). |
| Folders | Create folders, accept folders your Mac offers, choose which devices to share with, send-receive / send-only / receive-only, pause/resume, rescan, remove. Detail view shows sync state, counts, out-of-sync items, failed items, per-device completion, last scan and last synced file. |
| Selective sync | **Ignore patterns** editor per folder. Ignored files are never downloaded, so you can sync only part of a large folder. |
| Versions & conflicts | **File versioning** (trash can, simple, staggered) with a browser to **restore** old versions. A **conflicts** list lets you keep either copy. **Override** (send-only) and **Revert** (receive-only). |
| Untrusted devices | Share a folder **encrypted** with a password, so the other device stores data it can't read. |
| Files | Synced folders live in **Files › On My iPhone › SuperSynch** and are usable from any app. There's also an in-app browser with Quick Look preview and sharing. You can also sync **into a folder you pick elsewhere** (security-scoped bookmark; see limitations). |
| Devices | Connection state, address, completion, **per-device transfer rates** and totals, last seen, shared folders; pause/resume, edit, remove. Per-device **bandwidth limits** and **introducer** setting. |
| Pending | Devices that tried to connect (remembered even while the app was closed) and folders offered to you: **Add**, **Dismiss** or **Ignore permanently**. |
| Data usage | **Sync on Wi-Fi only** (pauses on cellular and personal hotspots), pause in **Low Data Mode**, global bandwidth limits. |
| Diagnostics | Syncthing's warnings and errors, with recent errors on the This Device screen. |
| Live status | Syncthing's event stream drives the UI in real time, including transfer rates and sync progress. |
| Background | Keeps syncing for a short while after you leave the app, then iOS-scheduled background syncs (see [Limitations](#limitations)). |
| UX | Colour and icon per sync state, pull-to-refresh, empty states, error banners, Dark Mode, Dynamic Type, Reduce Motion, iPad keyboard shortcuts. |

## Pairing with your Mac

1. **On the iPhone**, open SuperSynch → **This Device** → *Show Device ID*.
2. **On the Mac**, open Syncthing's GUI (`http://127.0.0.1:8384`) → **Add Remote Device**. Paste the ID; the Mac's GUI can also scan the QR code from a screenshot. Give it a name.
3. **On the iPhone**, go to **Devices → +** and paste or scan the Mac's ID (Mac: *Actions → Show ID*).
4. Share folders:
   - **From the Mac:** edit a folder → *Sharing* → tick the iPhone. It appears on the phone under **Pending Requests**; tap *Add…* to accept it into SuperSynch.
   - **From the phone:** **Folders → +**, tick the Mac under *Share With*. Accept it on the Mac.

If the two can't find each other on your network, set the Mac's address manually when adding it on the phone (*Connection → Manual*, e.g. `tcp://192.168.1.20:22000`). Global discovery and relays are on by default, so devices also find each other across networks.

## Limitations

Read this before relying on SuperSynch. Some limits come from iOS, some from embedding Syncthing, and some reflect what has (and hasn't) been tested.

### iOS platform limits
- **No continuous background sync.** iOS doesn't let apps run continuously in the background, so the phone can't stay in sync around the clock the way two desktops do. SuperSynch syncs:
  1. **While the app is open.** This is the only reliable way to sync. Open the app to catch up.
  2. **For about 30 seconds after you leave it.** It finishes in-progress transfers, then shuts Syncthing down cleanly.
  3. **When iOS grants background time.** It uses a short app-refresh window, and a longer processing window that iOS typically grants while charging on Wi-Fi. iOS decides when, and whether, these run, and they can be days apart for rarely used apps.

  While the phone is offline, your Mac queues the changes; they sync the next time the app runs.
- **No local (LAN) discovery yet.** Syncthing's local discovery uses UDP broadcasts. On iOS these need Apple's multicast networking entitlement, which Apple must approve. Until then, devices find each other through **global discovery** and **relays** (both on by default, so they need internet access), or through a **manual address** for your Mac (e.g. `tcp://192.168.1.20:22000`).
- **Inbound connections only while running.** Your Mac can only connect to the phone while SuperSynch is syncing; otherwise the Mac shows the phone as disconnected. That's expected.
- **No on-demand files.** Every file that isn't ignored is downloaded. Use ignore patterns to sync part of a folder; fetching individual files on demand, as iCloud Drive does, isn't implemented.
- **Folders outside the app.** Syncing into a folder picked from another location works for local storage such as other apps' "On My iPhone" folders. Cloud-backed locations like iCloud Drive can evict downloaded copies or coordinate writes in ways Syncthing doesn't expect, so they're not recommended. Access depends on a security-scoped bookmark; if the folder is moved or deleted, sync for it stops.
- **Battery.** Hashing and transferring large folders uses CPU and battery. Use *Sync on Wi-Fi Only* and bandwidth limits to reduce the impact.

### Embedded-engine notes
- **Model access via reflection.** `lib/syncthing` exposes only part of Syncthing's model, so the bridge reads the full model from an unexported field (`go/stbridge/model.go`). This is checked by tests, but it must be re-verified whenever Syncthing is upgraded.
- **Pinned Syncthing version.** Syncthing is pinned by commit (v2.1.5) because its `v2` tags don't use a `/v2` Go module path. Upgrading means bumping the commit, rebuilding the bridge and re-running the tests; it doesn't happen automatically.
- **Warnings are captured from the logger.** Syncthing's own log recorder is internal, so the app captures warning- and error-level log lines itself. Info-level logs aren't kept.
- **Ignore patterns aren't synced.** Like desktop Syncthing, `.stignore` is per device. Editing ignores requires the folder to be running (not paused).
- **Not available in the app yet:** per-folder advanced settings (rescan interval, file watcher, pull order, minimum free disk space), editing an existing folder's path, auto-accept folders, and changing the GUI/API (deliberately off). These are planned for a later version.

### Testing status
- Tested on the iOS simulator, including a real embedded node syncing files both ways with a separate Syncthing v2.1.5 process (pairing, pending requests, per-device statistics, ignore patterns, version restore). **Not yet tested on a physical iPhone or iPad, or against a real Mac over Wi-Fi**: real-network behaviour, background-task timing, Wi-Fi-only switching, Files-app integration on device, and battery impact still need verifying.
- In the simulator, the app listens on port **22010** instead of 22000, so it doesn't collide with a Syncthing running on the same Mac. Real devices use the default port.
- QR scanning needs a device camera; it isn't available in the simulator. Paste the ID there instead.

## Architecture

```
go/stbridge/          Go bridge around Syncthing's lib/syncthing (App + model).
                      Exposes a Node to Swift; data crosses as JSON shaped like
                      Syncthing's REST API. Runs Syncthing's folder-summary
                      service itself (Syncthing only starts it with its web GUI).
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

> **Simulator note:** in the simulator the app's Syncthing listens on port 22010 so it doesn't clash with a Syncthing on your Mac; see [Limitations](#limitations).

### Debugging on a device
The embedded Syncthing is Go. The Go runtime handles some memory faults and signals itself, which LLDB would otherwise stop on as `EXC_BAD_ACCESS` even though nothing crashed. The scheme loads `SuperSynch.lldbinit` to pass them through. If you debug with a scheme that doesn't, add it under *Edit Scheme → Run → Info → LLDB Init File*.

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

## Roadmap
On-demand files (download individual files via the bridge's block API) and a File Provider extension, per-folder advanced settings, widgets, testing on physical devices, and requesting the multicast entitlement for local discovery.

## License

SuperSynch is open source under the **[Mozilla Public License 2.0](LICENSE)**, the same license as Syncthing.

The app embeds Syncthing v2.1.5 and its Go dependencies unmodified, each under its own license (MPL-2.0, MIT, BSD, Apache-2.0). See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). The app's *Settings › About* screen links to this repository and to those notices.

"Syncthing" is a trademark of the Syncthing Foundation. SuperSynch is an independent project and is not affiliated with or endorsed by the Syncthing Foundation.
