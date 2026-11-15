This build is **not notarized**: it is signed ad hoc, not with a Developer ID. macOS asks before opening it the first time.

To open it:

1. Open the DMG and drag Vistara to Applications.
2. Open Vistara. macOS says it can't verify the app. Choose **Done**.
3. In System Settings › Privacy & Security, under Security, choose **Open Anyway** for Vistara, and confirm with your password or Touch ID.

macOS remembers the choice for this copy. Each new build is a new app to macOS, so do this again after an update. The Keychain asks again too, once, before Vistara can read the passwords an earlier build saved.

Check the download against SHA256SUMS: `shasum -a 256 -c SHA256SUMS`.
