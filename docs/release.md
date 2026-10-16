# Direct macOS release

GitHub downloads need a **Developer ID Application** signature and Apple notarization. The `Apple Development` certificate used for local builds is not a distribution identity. The release script builds a universal arm64/x86_64 app, signs it with the hardened runtime and a secure timestamp, submits a ZIP to Apple's notary service, staples the returned ticket to the app, checks Gatekeeper acceptance, and creates the ZIP intended for GitHub.

## Prepare the Apple account

1. Create or install a Developer ID Application certificate **with its private key** in this Mac's keychain. In Xcode, use **Xcode > Settings > Accounts > your team > Manage Certificates > + > Developer ID Application**. The Apple Developer account holder can also create one in [Certificates, Identifiers & Profiles](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/).
2. Confirm it appears in `security find-identity -v -p codesigning` as `Developer ID Application: ... (TEAMID)`. Use **that** Team ID for notarization. A separate `Apple Development` identity on the same Mac may belong to a different team.
3. Store notarization credentials in the keychain. `notarytool` prompts for the app-specific password; do not put it in this repository or in a shell command:

   ```sh
   xcrun notarytool store-credentials lode-runner --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID
   ```

   An App Store Connect API key can also be stored under the same profile name using `notarytool store-credentials`.

## Build and verify

The app version comes from [`Sources/LodeRunnerMac/Info.plist`](../Sources/LodeRunnerMac/Info.plist). Build the unsigned universal candidate before signing if you want to inspect it:

```sh
sh scripts/build-release-app.sh --build-only
```

Once the certificate and keychain profile are ready, run:

```sh
DEVELOPER_ID_APPLICATION='Developer ID Application: YOUR NAME (YOUR_TEAM_ID)' \
NOTARY_PROFILE=lode-runner sh scripts/build-release-app.sh
```

The script writes `Build/Release/LodeRunner-VERSION-macOS.zip` and a matching `.sha256` file. **Upload only this final ZIP and checksum** to a GitHub release. It contains the stapled `LodeRunner.app`; the intermediate ZIP in `Build/Release/Staging` was made before stapling. The script leaves the ordinary `Build/LodeRunner.app` untouched.

The release script stops if signing, notarization, stapling, or Gatekeeper verification fails. Do not distribute an unsigned build or the un-stapled intermediate archive. For a fresh-install check, extract the final ZIP on another Mac and launch the app there.

Apple's [notarization guide](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) and [custom workflow guide](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow) describe these requirements.
