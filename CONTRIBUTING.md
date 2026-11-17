# Release documentation policy

Keep the first-launch verification instructions in the installation sections of both `README.md` and `README.en.md`, and in `docs/installation.txt`. Every DMG must contain the same installation text as `安装说明.txt`. Keep the official release source, per-app approval steps, missing-button retry, and distinction from malicious or damaged-app warnings together.

Retain the GUI Open Anyway guide first, followed by the user-authorized optional Terminal route. Its only commands are `xattr -dr com.apple.quarantine "/Applications/DualDock.app"` and then `open "/Applications/DualDock.app"`, after the trusted official app has been copied to that exact location. Explain that this removes only that app bundle's quarantine attribute, does not sign or notarize it, and does not grant Accessibility or Screen Recording access. Do not broaden the target, clear all extended attributes, disable Gatekeeper, or add `sudo` by default. The reported success on a user's Mac is not validation across all Macs or macOS versions.

These instructions are a standing release requirement. They may be retired only after **both** of the following are established and recorded for the release:

1. The maintainer's Apple Developer Program account and Developer ID distribution credentials are configured. An account, Personal Team, or local ad-hoc signature alone is insufficient.
2. The final distributed app is properly Developer ID signed and Apple-notarized. Record the signing authority and Team ID, successful strict signature verification, the accepted notarization submission, ticket validation, and Gatekeeper acceptance for the final release artifact. A successful local build or `codesign --verify` alone does not establish this.

Even after these conditions are met, update both READMEs, the DMG text, and the guard together in an explicitly reviewed signing/notarization change. Do not remove the instructions merely because a version changes or a developer account becomes available. The current guard intentionally has no environment-variable bypass.

Before packaging:

```sh
python3 script/check_installation_guidance.py
python3 Tests/InstallationGuidanceChecks.py
```

`script/package_dmg.sh` runs the documentation guard before building, then verifies the installation text in the read-only mounted DMG before publishing the local asset and checksum. A missing or stale installation text fails packaging. The fixture checks cover both routes, the exact Terminal commands and target, and missing/stale DMG contents; they do not claim a clean-machine Gatekeeper launch test.

Apple references: [first-launch alerts](https://support.apple.com/en-us/102445) and [per-app approval](https://support.apple.com/en-gb/guide/mac-help/mh40617/mac).
