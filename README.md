# Vistara

A native macOS app for managing and connecting to RDP servers. FreeRDP does the
protocol work; everything you see and touch is native macOS UI.

Vistara is in early development and cannot connect to anything yet. Planned
work is tracked in the [issues](https://github.com/sysmike/vistara/issues),
grouped by milestone.

- [Architecture](docs/ARCHITECTURE.md)
- Requires macOS 14 or later

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
| Options | `--force` rebuilds even when the prefix is current. `VISTARA_ARCH` (default `arm64`) and `VISTARA_BUILD_DIR` (default `build/freerdp`) change the target and location |

To move to a new FreeRDP release, replace the line in `FREERDP_VERSION` with
the new version and the checksum from the release's `.sha256` file, then run
the script again. A checksum mismatch stops the build.

## License

[MIT](LICENSE)
