<p align="center">
  <img src="Assets/TermiFreedom-icon.png" width="128" alt="TermiFreedom icon">
</p>

# TermiFreedom

**Your servers. Your terminal. Your Mac.**

A native SSH and SFTP app for macOS. Keep your servers organized, work across
terminal tabs, and move files in a dedicated browser. Save passwords in macOS
Keychain and switch to SSH keys with guided key installation.

No account to create. No cloud sync to configure. Your server list and keys
stay on your Mac. Free and open source under the [MIT license](LICENSE).

## Connect and get to work

- **Servers within reach.** Save hosts, usernames, ports, and key paths. Arrange
  servers in groups, search the sidebar, and double-click to connect.
- **A terminal built for macOS.** Native terminal tabs with text-size shortcuts,
  bounded scrollback, and prompts before disconnecting active sessions.
- **Passwords when you need them.** Store server passwords in macOS Keychain.
  SSH keys are tried first, with a saved password available as a fallback.
- **An easier move to keys.** Choose an existing key or generate a dedicated
  Ed25519 key, then use “Add key to server.” Existing authorized keys are retained.
- **Files alongside your terminal.** Browse SFTP folders in a separate window.
  Search and sort listings, show hidden files, upload or download files with
  progress, create folders, and rename items.
- **Transfers with care.** Temporary files and atomic completion protect existing
  destinations on failure. Remote replacement requires server support for atomic
  replacement. Cancel transfers from the Files window.
- **Control over local data.** An explicit, confirmed cleanup option removes
  saved servers, app-managed keys, and app-owned Keychain entries before uninstalling.

Built with SwiftUI, AppKit, the Mac's OpenSSH, and SwiftTerm.

## Get TermiFreedom

Requires **macOS 14 or later**. This is an early release. Source builds are
available now; notarized public app downloads are pending Developer ID setup.
Check [Releases](https://github.com/mrecom-ai/TermiFreedom/releases) for the
status and supported architectures of each download.

For a DMG download, open it and drag TermiFreedom to Applications. For a ZIP,
unzip it and move the app to Applications. Quit the old app before replacing
it with an update. A fresh installation starts with an empty server list.

### Build from source

Install a **Swift 6.2+ toolchain**, then:

```sh
git clone https://github.com/mrecom-ai/TermiFreedom.git
cd TermiFreedom
./scripts/test.sh
./scripts/build-app.sh
open outputs/TermiFreedom.app
```

Move the built app into Applications to install it. Source builds target
the host architecture and are locally signed, not Apple-notarized.
SwiftTerm is vendored, so no package download is required for that dependency.

## Your data

Saved servers are runtime data in Application Support, never compiled into the
app. Passwords stay in Keychain. App-generated private keys stay in the local
app data folder; external keys remain wherever you chose them. Terminal output
is not saved by the app. Previous local app data is copied on adoption without
removing the original; passwords are adopted on first use.

To uninstall, quit and move TermiFreedom from Applications to Trash. This retains
local data for reinstalling. For a full local cleanup, first choose
**TermiFreedom → Erase Local TermiFreedom Data…**, close connections, and type
the requested confirmation. This deletes app-managed private keys too: keep
another way to access your servers. External SSH keys, SSH configuration,
downloads, and remote server files remain. Installed public keys must be revoked
on each server separately. See [installation and removal](docs/INSTALL.txt).

## Current scope

SFTP supports individual regular-file transfers. Recursive folder transfers,
resume, remote file deletion, and SSH tunnels are planned, not implemented.
Real-server authentication, compatibility, and performance need broader testing.

See the [usage guide](docs/USAGE.md), [architecture](docs/ARCHITECTURE.md),
[roadmap](docs/ROADMAP.md), and [release guide](docs/DISTRIBUTION.md).

## Development and privacy checks

```sh
./scripts/test.sh
python3 scripts/package-source.py
python3 scripts/package-release.py --development
```

The source archive uses an audited allowlist. Generated files, runtime records,
keys, credentials, and build caches are excluded. Never stage the workspace
wholesale. See the release guide before publishing source or app downloads.
Temporary app bundles belong in `work.noindex/` and must be removed after checks
so they do not clutter macOS application search.

Core SFTP tests run against the local SFTP subsystem over pipes, without network
connections. App checks use disposable Keychain entries. The build currently uses
SwiftPM's native build system to work around a cache/dSYM issue in the original
development environment.

## License and credits

TermiFreedom is [MIT licensed](LICENSE). SwiftTerm retains its own
[MIT license](Vendor/SwiftTerm/LICENSE); its pinned revision and local changes
are documented in [UPSTREAM.txt](Vendor/SwiftTerm/UPSTREAM.txt).
The app icon was generated for TermiFreedom; its prompt is in
[Assets/ICON-PROMPT.txt](Assets/ICON-PROMPT.txt).
