# Publishing a release

Prerequisites: Xcode, XcodeGen, GitHub CLI, the SwiftLab Developer ID Application certificate, and access to the Sparkle signing key. The private update key is stored in the login Keychain under account `veycal` (the original internal signing-key name). The Apple notarization profile is `nimble-notary`, shared with Nimble and Thimble. Neither secret belongs in the repository.

1. Update `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml`; every published build number must increase. Run `swift test`, and the website’s `npm run check` and `npm run build`.
2. Review the changes and commit them. Build the release with the matching numbers:

   ```sh
   ./scripts/release.sh 1.0.0 1
   ```

   The script materializes the source in a temporary folder, creates a universal archive, exports Developer ID signatures for the app and Sparkle helpers, submits to Apple, staples the ticket, verifies Gatekeeper, and generates a signed update feed. The final ZIP is created **after** stapling. Output is `build/releases/1.0.0/`.

3. Tag the matching commit and push source and tag:

   ```sh
   git tag v1.0.0
   git push origin main v1.0.0
   ```

4. Prepare release notes, then publish all three files together:

   ```sh
   gh release create v1.0.0 --repo RobSwish/calibar --verify-tag \
     --title 'CaliBar 1.0.0' --notes-file /path/to/release-notes.md \
     build/releases/1.0.0/CaliBar.zip \
     build/releases/1.0.0/appcast.xml \
     build/releases/1.0.0/SHA256SUMS
   ```

5. Verify the public download and feed. In the installed app, choose More → Check for Updates. Test an actual upgrade on a disposable installation before later releases.

The app’s feed is `https://github.com/RobSwish/calibar/releases/latest/download/appcast.xml`. The website uses the matching `latest/download/CaliBar.zip` link. Feed enclosure URLs are version-specific; keep older release assets available and never replace a released ZIP with different bytes.

The public key in `project.yml` must match the Keychain signing key. Preserve that key across releases. Automatic checks can be disabled in Settings; updates still require the user’s install action. Demo mode never checks for updates or opens sample meeting links.

Environment overrides supported by the release script: `DEVELOPMENT_TEAM`, `SIGNING_IDENTITY`, `NOTARY_PROFILE`, `SPARKLE_ACCOUNT`, `SPARKLE_TOOLS_DIR`, `RELEASE_REPO`. No credentials need to be written to disk or placed in shell arguments.
