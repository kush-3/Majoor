# Releasing Majoor

How to ship a new version so existing installs pick it up via Sparkle auto-update.

## One-time setup (already done)

- A Sparkle EdDSA key pair was generated with `generate_keys`. The **private key lives in the
  login Keychain** as "Private key for signing Sparkle updates". The public key is embedded in
  `Majoor/Info.plist` under `SUPublicEDKey`.
- **Back up the private key** — if it's lost, installed apps can no longer verify updates and
  users must re-download manually:

  ```bash
  DERIVED=$(ls -dt ~/Library/Developer/Xcode/DerivedData/Majoor-*/ | head -1)  # most recently used
  "$DERIVED/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys" -x ~/sparkle_private_key_backup.pem
  ```

  Store the exported file somewhere safe (not in this repo).

## Release steps

1. **Bump the version** in Xcode (target → General), or edit both build configurations in
   `project.pbxproj`: `MARKETING_VERSION` (e.g. `1.0.3`) and `CURRENT_PROJECT_VERSION`
   (increment by 1 — Sparkle compares this build number, so it must strictly increase).
   Keep Debug and Release in sync.

2. **Build, package, and sign the update:**

   ```bash
   ./Scripts/build-dmg.sh
   ```

   This produces `dist/Majoor-<version>.dmg` and `dist/appcast.xml` (EdDSA-signed via the
   Keychain key). Add `--notarize` once an Apple ID / Developer ID certificate is set up —
   the rest of the flow is unchanged.

3. **Publish the DMG** as a GitHub release asset. The appcast expects the tag `v<version>`.
   Name the exact DMG — never glob `dist/Majoor-*.dmg`, which would attach every historical
   DMG sitting in `dist/`:

   ```bash
   gh release create "v1.0.3" dist/Majoor-1.0.3.dmg --title "Majoor 1.0.3" --notes "What changed"
   ```

4. **Publish the appcast** — copy `dist/appcast.xml` into the `majoor-releases` repo
   (served at `https://kush-3.github.io/majoor-releases/`) and push. The appcast contains
   only the newest release; older DMGs stay downloadable from GitHub releases.

5. **Verify:** `curl -s https://kush-3.github.io/majoor-releases/appcast.xml` shows the new
   version, then open an older installed build → Settings → General → "Check for Updates Now".

## Notes

- The app itself doesn't need to be code-signed for updates to work — Sparkle verifies the
  EdDSA signature in the appcast against `SUPublicEDKey`.
- `generate_appcast` reads the version from the app inside the DMG, so a wrong appcast version
  means the built app's Info.plist is wrong — check both build configurations.
- **One-time cutover:** builds shipped before 1.0.2 (the 1.0.0/1.0.1 DMGs) contain no
  `SUPublicEDKey` and are ad-hoc signed, so Sparkle in those installs has nothing to verify
  updates against — "Check for Updates" will not work from them. Anyone on an older build must
  re-download the DMG manually once. Auto-update works from 1.0.2 (build 4) onward.
- Notarization order matters: stapling rewrites the DMG, so the appcast must be generated from
  the final bytes. `build-dmg.sh` already does this in the right order — don't staple a DMG
  after its appcast entry has been generated.
