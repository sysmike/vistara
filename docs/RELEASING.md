# Releasing Vistara

A tag such as `v0.1.0` runs `.github/workflows/release.yml`. It builds the
universal app and creates a **draft** GitHub release with the DMG and
`SHA256SUMS`. A person publishes the draft.

- **With the secrets below**, the app is signed with a Developer ID, and Apple
  notarizes the app and the DMG; both are stapled. It opens like any app.
- **Without them**, the app is signed ad hoc and not notarized. The release
  is titled "(not notarized)", and its notes
  ([`scripts/release/unsigned-notes.md`](../scripts/release/unsigned-notes.md))
  say how to open it: once, with Open Anyway in System Settings › Privacy &
  Security.

Both open on any Mac because the app carries no libraries of its own: FreeRDP,
WinPR, and OpenSSL are linked into its binary. Under the hardened runtime,
library validation loads a library only when it is signed by the app's own
team, and an ad hoc build has no team, so 0.5.0-beta, which still carried
them, did not start on another Mac.

Every other run is a dry run: a manual run from the Actions tab, or a pull
request that changes the release scripts. It is signed ad hoc, and the DMG is
uploaded as a workflow artifact only. Only a `v*` tag uses the `release`
environment, so a run on a branch never sees the signing secrets.

## One-time setup

Only the repository owner can do this; no credential ever goes into the
repository.

1. **Developer ID certificate.** In Keychain Access, export the "Developer ID
   Application" certificate *with its private key* as a `.p12` file, with a
   password.
2. **Notary key.** In App Store Connect, under Users and Access › Integrations,
   create an API key with the Developer role. Download the `.p8` file (it can
   be downloaded once) and note its key ID and the issuer ID.
3. **Environment.** In the repository's Settings › Environments, create an
   environment named `release`. Restrict it to tags matching `v*`, and add
   yourself as a required reviewer, so every release waits for your approval.
4. **Secrets.** Add these as *environment* secrets of `release`, not as
   repository secrets:

   | Secret | Value |
   | --- | --- |
   | `DEVELOPER_ID_CERTIFICATE` | the `.p12` file, base64-encoded: `base64 -i DeveloperID.p12 \| pbcopy` |
   | `DEVELOPER_ID_CERTIFICATE_PASSWORD` | the `.p12` file's password |
   | `DEVELOPER_ID_TEAM_ID` | the team ID, ten characters |
   | `NOTARY_KEY` | the contents of the `.p8` file |
   | `NOTARY_KEY_ID` | the API key's ID |
   | `NOTARY_ISSUER_ID` | the issuer ID |

GitHub never passes secrets to workflows run for pull requests from forks.
Environment secrets are passed only to jobs that use that environment, after
its protection rules pass. The workflow imports the certificate into a
throwaway keychain and deletes it, and the notary key file, at the end of the
job.

## Making a release

1. Set `MARKETING_VERSION` in `project.yml` if it changed, and merge to `main`.
2. Tag the commit on `main` and push the tag:

   ```
   git tag -s v0.1.0 -m "Vistara 0.1.0"
   git push origin v0.1.0
   ```

3. Approve the `release` environment when GitHub asks.
4. When the workflow is done, review the draft release, add notes, and publish.

The version comes from the tag; the build number is the workflow run number.

## What the workflow checks

- **Toolchain:** the same pinned Xcode as CI (`XCODE_VERSION`), on the
  `macos-26` runner, so the release is built the way it was tested.
- **App:** it has an arm64 and an x86_64 slice.
- **Signature:** it verifies deeply and strictly. Signed with a Developer ID,
  the app carries the hardened runtime flag, that team, and a secure
  timestamp.
- **Libraries:** the app has no `Frameworks` folder and loads nothing but
  macOS's own libraries (`otool -L`). It is started with the build's FreeRDP
  prefix hidden.
- **Entitlements:** the app is sandboxed and has no hardened runtime exception,
  no `com.apple.security.cs.*` entitlement. Vistara needs none: FreeRDP and
  OpenSSL are linked into the app, nothing is generated or loaded at
  run time, and no debugger attaches to a release.
- **Notarization:** the app and the DMG are notarized and stapled.
  `spctl --assess` accepts both.

## After the first signed release

Check these by hand on a Mac that has never run Vistara:

- **Gatekeeper:** the DMG opens and the app starts without a Gatekeeper
  warning. `spctl --assess --type execute -vv /Applications/Vistara.app` says
  `source=Notarized Developer ID`.
- **Keychain:** an update reads the passwords an earlier signed version saved,
  without a Keychain prompt (#64). Ad hoc builds are a new app to the Keychain
  each time, so this can only be checked between two signed builds. If it
  prompts, consider the data protection keychain, which needs the
  `keychain-access-groups` entitlement.
