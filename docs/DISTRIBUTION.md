# Release TermiFreedom

TermiFreedom is a self-contained `.app`. ZIP and drag-to-Applications DMG
downloads need no installer package or privileged helper.

## Local development packages

```sh
./scripts/test.sh
python3 scripts/package-release.py --development
python3 scripts/package-source.py
```

The generated filenames include version, architecture, and `development`.
Development packages are locally signed with hardened runtime, but not
notarized. Do not present them as notarized downloads. The build targets
the host architecture; this is not yet a universal Intel/Apple silicon build.

To install the current local build on this Mac:

```sh
python3 scripts/install-local.py
```

Quit TermiFreedom first. This verifies the signature, installs in Applications,
and removes the superseded `outputs/TermiFreedom.app` so app search finds one
copy. It never launches the app or changes saved server data. If replacing an
existing install, a recovery ZIP is kept under ignored `work.noindex/`.
Use `--destination ~/Applications` for a per-user install. Build again before
packaging another release after installation.

## Developer ID releases

Install your **Developer ID Application** certificate and private key in
Keychain using Xcode/Apple Developer. Store notarization credentials
interactively in Keychain, never in source or workflow files:

```sh
xcrun notarytool store-credentials TermiFreedom-notary
export TERMIFREEDOM_SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)'
export TERMIFREEDOM_NOTARY_PROFILE='TermiFreedom-notary'
./scripts/test.sh
python3 scripts/package-release.py
python3 scripts/package-source.py
```

The script signs with hardened runtime and a secure timestamp, submits the
app for notarization, staples and validates its ticket, checks Gatekeeper,
then creates ZIP/DMG downloads. It also signs, notarizes, and staples the DMG.
Only successful packages are moved into `outputs/`. SHA-256 checksums accompany
the two app downloads. Notarization reports remain in ignored `work.noindex/`.
There are no credentials in these scripts. Missing credentials fail before
building; rejected submissions never silently become public release packages.

Apple references: [Developer ID](https://developer.apple.com/developer-id/)
and [customizing notarization](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).

## GitHub publication

Use `mrecom-ai/TermiFreedom`, licensed MIT. Keep product copy focused on
TermiFreedom's implemented features; don't claim unavailable features or
comparative performance. The README is the public product page.

Before pushing, run the privacy audit and inspect **only** the allowlisted
source package produced by `scripts/package-source.py`. Never stage the
workspace wholesale: `work/`, `work.noindex/`, `outputs/`, build caches,
runtime server records, and credentials must stay private. The source
package excludes Xcode's generated vendored build caches too.

For each public binary release:

1. Run tests and privacy/branding checks. Bump the bundle version/build.
2. Run the Developer ID packaging command above, without `--development`.
3. Test installation from the DMG, launch, update, and uninstall on a clean
   Mac, and test representative SSH/SFTP servers with explicit permission.
4. Create a GitHub release for the matching source commit/tag. Upload the
   notarized DMG, app ZIP, source ZIP, and SHA256SUMS file. State supported
   architectures and macOS version. Include known limitations.

Do not publish an ad-hoc development binary as a production release while
waiting for Apple credentials. Source can be published independently.
