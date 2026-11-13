# Vistara

A native macOS app for managing and connecting to RDP servers. FreeRDP does the
protocol work; everything you see and touch is native macOS UI.

Vistara is in early development and cannot connect to anything yet. Planned
work is tracked in the [issues](https://github.com/sysmike/vistara/issues),
grouped by milestone.

- [Architecture](docs/ARCHITECTURE.md)
- [Releasing](docs/RELEASING.md)
- [Updating FreeRDP](docs/UPDATING-FREERDP.md)
- [Interface specification](docs/DESIGN.md)
- Requires macOS 14 or later

## Building the app

Build FreeRDP first (see below); the app links and embeds it.

The Xcode project is generated from [`project.yml`](project.yml) and is not
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
| Input | [`FREERDP_VERSION`](FREERDP_VERSION): FreeRDP version and the SHA-256 of its release tarball, on one line |
| Input | [`scripts/OPENSSL_VERSION`](scripts/OPENSSL_VERSION): the same for OpenSSL, FreeRDP's one external dependency |
| Output | `build/freerdp/prefix/include` and `build/freerdp/prefix/lib`: headers and relocatable (`@rpath`) libraries for libfreerdp, libfreerdp-client, WinPR, libssl, and libcrypto |
| Options | `--force` rebuilds even when the prefix is current. `VISTARA_ARCHS` (default `arm64 x86_64`) and `VISTARA_BUILD_DIR` (default `build/freerdp`) change the targets and location. With two architectures each is built on its own and the libraries are joined with `lipo` |

To move to a new FreeRDP release, replace the line in `FREERDP_VERSION` with
the new version and the checksum from the release's `.sha256` file, then run
the script again. A checksum mismatch stops the build.

## License

[MIT](LICENSE)
