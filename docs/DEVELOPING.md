# Developing Vistara

How to build Vistara, run its tests, and read its logs. For what Vistara is
and how to use it, see the [README](../README.md) and the
[user guide](USER-GUIDE.md).

- [Architecture](ARCHITECTURE.md) and [interface specification](DESIGN.md)
- [Releasing](RELEASING.md) and [updating FreeRDP](UPDATING-FREERDP.md)

## Building the app

Build FreeRDP first (see below); the app links and embeds it.

Vistara builds with Xcode 26 (CI and releases pin 26.6; see `XCODE_VERSION`
in the workflows) and runs on macOS 14 and later. Built against the macOS 26
SDK, its standard controls take on Liquid Glass on macOS 26.

The Xcode project is generated from [`project.yml`](../project.yml) and is not
committed. Most code lives in local Swift packages under `Packages/`.

```bash
brew install xcodegen swiftlint
```

```bash
xcodegen generate
```

Then open `Vistara.xcodeproj`, or build and test from the command line:

```bash
xcodebuild build -project Vistara.xcodeproj -scheme Vistara
```

```bash
swift test --package-path Packages/VistaraCore && swift test --package-path Packages/RDPKit
```

```bash
swiftlint lint --strict
```

### Screenshots

`ScreenshotTests` and a few other tests write a PNG of every state of the
interface, which CI uploads as the `screenshots` artifact of each run. Liquid
Glass is drawn by the window server, so a view drawn offscreen lacks it. In CI
the tests therefore ask a helper in the test step for a real `screencapture`
of their window (`VISTARA_SCREEN_CAPTURE=1`; see `App/Tests/Screenshots.swift`).
Locally, and for a window taller than the runner's screen, they draw offscreen.
The images in `docs/images` come from that artifact.

### Files on the pasteboard

The file clipboard probes (`App/Tests/FileClipboardProbeTests.swift`) need an
app outside the sandbox that copies and pastes files the way the Finder does:
`scripts/test-pasteboard/pasteboard-helper.swift`. The CI test step builds it
and runs it when a test writes a request into
`vistara-pasteboard` in the app's container, as it does for screenshots, and
sets `TEST_RUNNER_VISTARA_PASTEBOARD_HELPER=1`. Without that variable the
probes are skipped. To run them locally, build the helper and serve requests
the same way:

```bash
swiftc -swift-version 5 -O scripts/test-pasteboard/pasteboard-helper.swift -o build/pasteboard-helper
```

What the probes found, and why Vistara provides the remote computer's files
as it does, is on issue #134.

## Integration tests

Tests that need an RDP server run only when `VISTARA_TEST_RDP_HOST` is set.
Also read: `VISTARA_TEST_RDP_PORT`, `VISTARA_TEST_RDP_USER`,
`VISTARA_TEST_RDP_DOMAIN`, and `VISTARA_TEST_RDP_PASSWORD`.

CI runs them against FreeRDP's shadow server on localhost. To do the same
locally, after building FreeRDP:

```bash
scripts/build-test-server.sh
```

```bash
set -a && eval "$(scripts/run-test-server.sh)" && set +a && swift test --package-path Packages/RDPKit
```

The test server is a build of FreeRDP's own server with a 1024x768
screen filled with one colour. It checks the protocol path (TLS, Network Level Authentication,
graphics updates). It is not a substitute for testing against Windows.

What the server does for the tests is in `scripts/test-server/sample-screen.patch`,
and it logs what it receives as lines starting with `vistara-`. The clipboard:

- **Text:** it offers a known text as soon as the client's clipboard is up, and
  logs the text a client offers in hex (`vistara-clipboard from-client`).
- **Files it offers:** along with the text, a file list. It holds a 2.5 MiB report, larger
  than a client's part of 1 MiB; a folder with a file whose name is not ASCII;
  a file named with a "/" whose size the list leaves out; and an absolute path,
  which a client must skip. Each contents request is logged with the lock it
  names (`vistara-clipboard file-request … lock=`), as are a client's locks
  (`locked id=`, `unlocked id=`). The report's parts are slowed to 100 ms
  each, so a test can cancel in the middle.
- **Files a client offers:** it fetches the list, logs each entry with its name
  in hex (`client-file`), then locks the client's files (`client-lock=`) and
  fetches every file in parts, 150 ms apart, logging its size and FNV-1a
  checksum (`client-file-done`). Something the client copies meanwhile is
  logged (`client-copied-during-fetch`) and not fetched. Last, it asks for a
  folder's contents and for an entry beyond the list, which the client must
  refuse (`client-refused`).
- **Printing:** when a client announces a printer, the server logs its name
  and driver (`vistara-printer announced`). It then prints two documents to
  it, each opened, written, and closed as a print job: a small PDF in three
  parts, and a short text that isn't a PDF (`wrote`, `printed`). The patch
  also lets FreeRDP's server take a printer's open answer without its optional
  last byte, which FreeRDP's own printer leaves out.
- **Copying during a fetch:** after a client offers a file whose name holds
  "copy something else while I fetch", the server copies a new text in the
  middle of that client's next locked fetch of the report
  (`copied-during-fetch`).

### Through an RD Gateway

CI also runs [rdpgw](https://github.com/bolkedebruin/rdpgw), an open-source
RD Gateway, in front of the test server. It is built from the source pinned in
`scripts/RDPGW_VERSION` and needs Go (`brew install go`):

```bash
scripts/build-test-gateway.sh
```

Start it after the test server, in the same shell:

```bash
set -a && eval "$(scripts/run-test-server.sh)" && eval "$(scripts/run-test-gateway.sh)" && set +a
```

The gateway listens on `localhost:34443` with the HTTP transport and NTLM. Each
start makes a new certificate authority and a gateway certificate it signs,
and one gateway user with a new password. That user may reach the test server
and nothing else. The environment it prints:

| Variable | What it is |
| --- | --- |
| `VISTARA_TEST_GATEWAY_HOST`, `VISTARA_TEST_GATEWAY_PORT` | Where the gateway listens |
| `VISTARA_TEST_GATEWAY_USER`, `VISTARA_TEST_GATEWAY_PASSWORD` | The gateway user. Any other name or password fails |
| `VISTARA_TEST_GATEWAY_CA` | The authority that signed the gateway's certificate. Without it the certificate is untrusted |
| `VISTARA_TEST_GATEWAY_REFUSED_HOST` | An address the gateway refuses to reach (port 3389) |
| `VISTARA_TEST_GATEWAY_LOG` | The gateway's log. It names the user it accepted, the host it reached, and the hosts it refused |

The gateway log lines tests can wait for:

| Line | When |
| --- | --- |
| `NTLM: User <name> authenticated` | The gateway accepted the user |
| `Failed to process NTLM authenticate message` | A wrong password |
| `NTLM: unknown username specified: <name>` | A user the gateway does not know |
| `Establishing connection to RDP server: <host>:<port>` | The gateway reaches the server for the client |
| `Not allowed to connect to <host>:<port> by policy handler` | The policy refused the address |

To check the gateway setup on its own, with FreeRDP's minimal client instead
of Vistara:

```bash
scripts/check-test-gateway.sh
```

CI runs this before the tests, so a broken gateway setup is not taken for a
fault in Vistara.

Two files beside the pin keep the build reproducible on macOS:

- `scripts/test-gateway/go.sum`: rdpgw's release has none, so this one pins
  every Go module it uses.
- `scripts/test-gateway/no-pam.patch`: rdpgw's authentication helper also
  checks passwords with PAM, which does not build against macOS's PAM. The
  patch takes that mode out; the gateway tests use NTLM only.

To move to a newer rdpgw, change `scripts/RDPGW_VERSION`, check that the patch
still applies, and delete the `go.sum`. The next build resolves the modules
with `go mod tidy`, which checks them against Go's checksum database, prints
the new `go.sum`, and stops. Review it, commit it, and build again.

### Against a Windows host

The same tests run against any RDP host. Use a computer you may test
against, with Remote Desktop and Network Level Authentication turned on, and
a dedicated test account:

```bash
export VISTARA_TEST_RDP_HOST=win11-test.example.com
export VISTARA_TEST_RDP_USER=vistara-test
export VISTARA_TEST_RDP_DOMAIN=EXAMPLE   # optional
read -rs VISTARA_TEST_RDP_PASSWORD && export VISTARA_TEST_RDP_PASSWORD
```

```bash
swift test --package-path Packages/RDPKit
```

The app's tests take the same values with a `TEST_RUNNER_` prefix, which
`xcodebuild` passes on to the test process:

```bash
TEST_RUNNER_VISTARA_TEST_RDP_HOST="$VISTARA_TEST_RDP_HOST" \
TEST_RUNNER_VISTARA_TEST_RDP_USER="$VISTARA_TEST_RDP_USER" \
TEST_RUNNER_VISTARA_TEST_RDP_DOMAIN="${VISTARA_TEST_RDP_DOMAIN:-}" \
TEST_RUNNER_VISTARA_TEST_RDP_PASSWORD="$VISTARA_TEST_RDP_PASSWORD" \
xcodebuild test -project Vistara.xcodeproj -scheme Vistara -destination 'platform=macOS'
```

What changes against a real host:

- **Failed logins are left out** unless `VISTARA_TEST_RDP_ALLOW_FAILED_LOGINS=1`
  is set. A run signs in with a wrong password about five times, which can
  lock the account under a typical lockout policy. Set it only for an account
  without one.
- Checks that need the test server are left out: its screen colour, its
  cursor shape, and everything read from its log (keyboard, pointer, and
  desktop-size requests as the server received them).
- Connecting repeatedly runs five rounds instead of fifty.
- The certificate tests expect a certificate the Mac does not trust, such as
  the self-signed one Windows uses by default. A host with a publicly trusted
  certificate connects without the question they wait for.
- The tests ask for a 1024x768 desktop and expect to get it.

Never put the password in a file in this repository or in your shell
history; `read -rs` above keeps it out of both.

## Logs

Vistara writes to the unified log under the subsystem
`io.github.sysmike.vistara`. To collect what it says while you reproduce a
problem:

```bash
log stream --level debug --predicate 'subsystem == "io.github.sysmike.vistara"'
```

FreeRDP's own messages appear under the category `FreeRDP`. Before they are
logged, the hosts, user names, domains, and passwords of your sessions, and
anything that looks like an IP address, are replaced with `<host>`, `<user>`,
`<redacted>`, or `<address>`, so the output is meant to be safe to paste into
a bug report. Read it before you post it anyway. FreeRDP logs warnings and
errors only; set `WLOG_LEVEL=DEBUG` in the environment for more.

## Building FreeRDP

Vistara embeds FreeRDP as libraries built from a pinned release.

```bash
scripts/build-freerdp.sh
```

Needs macOS with the Xcode command line tools and CMake (Ninja is used when
present). Nothing from Homebrew or MacPorts is linked.

| | |
| --- | --- |
| Input | [`FREERDP_VERSION`](../FREERDP_VERSION): FreeRDP version and the SHA-256 of its release tarball, on one line |
| Input | [`scripts/OPENSSL_VERSION`](../scripts/OPENSSL_VERSION): the same for OpenSSL, FreeRDP's one external dependency |
| Output | `build/freerdp/prefix/include` and `build/freerdp/prefix/lib`: headers and relocatable (`@rpath`) libraries for libfreerdp, libfreerdp-client, WinPR, libssl, and libcrypto |
| Options | `--force` rebuilds even when the prefix is current. `VISTARA_ARCHS` (default `arm64 x86_64`) and `VISTARA_BUILD_DIR` (default `build/freerdp`) change the targets and location. With two architectures each is built on its own and the libraries are joined with `lipo` |

To move to a new FreeRDP or OpenSSL release, follow
[Updating FreeRDP](UPDATING-FREERDP.md). A checksum mismatch stops the build.
