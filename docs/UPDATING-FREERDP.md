# Updating FreeRDP and OpenSSL

Vistara bundles FreeRDP and its one external dependency, OpenSSL, built from
pinned releases:

| Pin | File | Line followed |
| --- | --- | --- |
| FreeRDP | `FREERDP_VERSION` | 3.x |
| OpenSSL | `scripts/OPENSSL_VERSION` | the pinned release line, 3.5 (LTS) |

Each file holds a version and the SHA-256 of its release tarball. The
**Upstream watch** workflow checks once a day and opens an issue,
"build: FreeRDP 3.33.2 is available", for every newer release. A bump is
routine; one with a security fix goes first.

## 1. Read the release notes

The issue links them. Look for:

- **Security fixes and CVEs.** These decide how soon to ship. Check whether
  they touch what Vistara uses: TLS and NLA, certificate handling, the
  graphics and codec paths (GDI, surface commands), and the channels Vistara
  loads: `cliprdr`, `rdpsnd`, `rdpdr` with `drive` and `printer`, `drdynvc`,
  and `disp`.
- **API changes.** Vistara reaches FreeRDP only through
  `Packages/RDPKit/Sources/CFreeRDP` (`shim.c`, `audio.c`, `drive.c`,
  `clipboard_files.c`, `printer.c`). These are the parts to look for in the notes:
  - functions and settings that are renamed or deprecated;
  - changed callback signatures, for example in `rdpsndDevicePlugin`,
    `CliprdrClientContext`, the drive service and IRP handling, the printer
    backend (`rdpPrinterDriver`, and how `printer_DeviceServiceEntry` picks a
    backend from the driver name), `rdpPointer`, and the WLog appender;
  - the file list helpers in `freerdp/utils/cliprdr_utils.h`, and how the
    clipboard channel applies `ClipboardFeatureMask` to file messages;
  - changed defaults in `freerdp_settings_*`.
- **Build options.** These are the CMake options `scripts/build-freerdp.sh`
  sets: `WITH_*`, the `CHANNEL_*` list, and whether `rdpsnd`'s `mac` backend
  or `WITH_MACAUDIO` changed.
- **The shadow server.** The test server is FreeRDP's shadow server with
  `scripts/test-server/sample-screen.patch`. Changes to
  `server/shadow/shadow_client.c`, `Sample/sample_shadow.c`, or
  `channels/rdpdr/server/rdpdr_main.c` may stop the patch from applying.

## 2. Pin the release

```
scripts/update-pin.sh freerdp 3.33.2
```

It downloads the tarball, checks it against the `.sha256` file the project
publishes beside it, and writes the version and checksum into the pin file.
For OpenSSL: `scripts/update-pin.sh openssl 3.5.10`.

## 3. Rebuild

```
scripts/build-freerdp.sh
scripts/build-test-server.sh
```

Both notice the new pin and rebuild; there is no cache to clear.

- **The shim fails to compile:** an API changed. Check each failing call
  against the new headers in `build/freerdp/prefix/include/freerdp3` and
  `winpr3`, never from memory, and adjust the shim.
- **The test server's patch no longer applies:** recreate it on the new
  release. Unpack the release twice as `a/` and `b/`, apply the old patch to
  `b/` by hand, and write `diff -u` for `server/shadow/Sample/sample_shadow.c`
  and `server/shadow/shadow_client.c` (with `--label a/…` and `--label b/…`)
  to `scripts/test-server/sample-screen.patch`.
- **The header check fails:** `build-freerdp.sh` stops when the installed
  headers differ between arm64 and x86_64 in more than install paths and the
  architecture's name. That means a type or a layout now differs between the
  slices; look into it before going on.

To see what changed in the headers since the last release, build the old
prefix aside and compare:

```
VISTARA_BUILD_DIR=build/freerdp-old scripts/build-freerdp.sh   # with the old pin checked out
diff -ru build/freerdp-old/prefix/include build/freerdp/prefix/include
```

## 4. Test

```
swift test --package-path Packages/VistaraCore
set -a; eval "$(scripts/run-test-server.sh)"; set +a   # exports the test server's settings
swift test --package-path Packages/RDPKit
xcodegen generate && xcodebuild test -project Vistara.xcodeproj -scheme Vistara
```

The integration tests run against the test server: connecting, input,
resizing, the clipboard, sound, shared folders, reconnection, and logging
with redaction. Then open a pull request: CI builds both architectures and
runs everything again.

If a real Windows host is at hand, connect to it once with the new build
([Developing Vistara](DEVELOPING.md#against-a-windows-host)). The test server is FreeRDP talking to
FreeRDP and cannot catch everything.

## 5. Ship

Title the pull request after the bump, with "security" when it is one, for
example `build: FreeRDP 3.33.2 (security)`, and close the watch issue with
it. A security fix goes into a release right away (docs/RELEASING.md).

## Dry run

The procedure was dry-run while it was written, in the pull request that
added it. `scripts/update-pin.sh freerdp 3.33.0` followed by
`scripts/update-pin.sh freerdp 3.33.1` rewrote `FREERDP_VERSION` byte for
byte as it was, each checksum matching the one FreeRDP publishes. CI then
built and tested that pin.
