# Vistara architecture

Vistara is a native macOS app for managing and connecting to RDP servers.
FreeRDP is the protocol engine. Everything the user sees and touches is native
macOS UI. Changes to anything on this page need an issue labeled `decision`.

## Platform

- macOS 14 or later, as a universal app: arm64 and x86_64 (#33). Measured in
  CI on macos-15: an x86_64 build of OpenSSL and FreeRDP takes 154 s next to
  156 s for arm64, and only when the pins change, since the result is
  cached. The libraries grow from 20.1 MB (arm64) to 30.8 MB universal, and
  the Release app is 27 MB. The x86_64 slice is cross-built on Apple silicon
  and launched under Rosetta in CI; it has not run on an Intel Mac.
- Swift 6 with SwiftUI for the app chrome. AppKit where SwiftUI falls short,
  which includes the session view and raw keyboard handling.
- The Xcode project is generated from `project.yml` with XcodeGen and is not
  committed. Most code lives in local Swift packages.

## Layers

Each layer depends only on the one below it.

| Layer | What it is | Rule |
| --- | --- | --- |
| `Vistara` | The app: library UI, session windows, persistence, Keychain | Never imports `CFreeRDP` |
| `RDPKit` | Swift wrapper that owns session lifecycle, settings, and callbacks, exposed as Swift types and async streams | No C pointers or FreeRDP types leave this layer |
| `CFreeRDP` | C shim and module map over the FreeRDP headers | No logic beyond what Swift cannot call directly |

App logic that needs no UI (connection store, `.rdp` parser, key map,
certificate trust store) lives in its own package so it can be unit tested
without the app.

## FreeRDP

- FreeRDP 3.x is embedded as libraries: libfreerdp, libfreerdp-client, WinPR.
- Vistara does not shell out to `xfreerdp` or `sdl-freerdp` and does not reuse
  upstream's `client/Mac` code. `xfreerdp` needs XQuartz, the SDL client brings
  its own non-native window, and the upstream Mac client is unmaintained.
- `scripts/build-freerdp.sh` builds a pinned release tag, and the result is
  bundled in the app. The pinned version lives in one file. FreeRDP ships
  security fixes often, so a bump is a one-line change plus a rebuild:
  `scripts/update-pin.sh`, and a daily workflow opens an issue for every new
  release (docs/UPDATING-FREERDP.md).
- Every FreeRDP call is checked against the headers of the pinned version. The
  API shifts between minor releases, so calls are never written from memory.

## Sessions, threads, and rendering

- Each session runs on its own thread, which owns its FreeRDP instance. The
  main thread does UI only and never waits on a session thread.
- FreeRDP's GDI software framebuffer is drawn into a Metal-backed `NSView`.
  Only dirty rectangles are uploaded.
- Session state, framebuffer updates, and prompts (credentials, certificates)
  cross from RDPKit to the app as Swift values and async streams.
- One window per session. Session windows are ordinary Mac windows with system
  chrome and the system's full-screen mode.

## Persistence

- Connections are stored as versioned JSON in
  `~/Library/Application Support/Vistara/` (inside the app's container when
  sandboxed). The file holds no secrets.
- Trusted certificate fingerprints are stored beside it.
- Passwords live only in the Keychain, keyed by connection identifier.

## Security posture

- Passwords never appear in logs, exported files, UserDefaults, crash reports,
  or process arguments.
- Certificate verification is on by default and is never skipped silently.
  Unknown certificates are trusted on first use after the user sees the
  fingerprint; a changed certificate produces a loud warning.
- Hostnames, usernames, and credentials are redacted from logs at the default
  level.
- The hardened runtime is enabled with no exceptions: no
  `com.apple.security.cs.*` entitlement, which the release workflow checks.
  The App Sandbox is enabled; if a feature cannot work inside it, that becomes
  a `decision` issue, not a quiet opt-out.
- Releases are signed with a Developer ID, notarized, and stapled by a
  workflow that runs for version tags only (docs/RELEASING.md).

## Testing and CI

- Unit tests cover the connection store, the `.rdp` parser, keyboard mapping,
  and the certificate trust store.
- Integration tests run against a real RDP host only when
  `VISTARA_TEST_RDP_HOST` is set. CI skips them.
- CI runs on a macOS runner: build FreeRDP (cached by pinned version), build
  the app, run tests and the linter.

## Scope

Version 1 covers the connection library, per-connection settings, the session
window, certificate trust on first use, and `.rdp` import and export.
Session tabs follow in milestone M4 (see Session tabs in DESIGN.md). Multiple
monitors, RD Gateway, smart cards, file clipboard, RemoteApp, printer
redirection, and sync are tracked as issues labeled `later`.
