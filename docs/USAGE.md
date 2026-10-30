# Using TermiFreedom

## Servers and terminals

Add a server with its hostname or SSH alias, port, optional username, group and key path. A single click selects it; a double-click opens SSH. Right-click for Connect, Browse files, Edit or Delete. Terminal text size is adjustable with Command-plus/minus and Command-0. Closing active sessions asks before disconnecting.

Metadata stays in `~/Library/Application Support/TermiFreedom/servers.json`. On first adoption, the previous data folder is copied, with managed key paths adjusted; the original folder is retained. External SSH keys, existing SSH configuration and data belonging to other apps are not migrated or overwritten by launching the app. TermiFreedom does not save terminal output.

## Passwords and keys

A previously saved Keychain password is copied on first use; macOS may mention the original item’s old name once when requesting access. The original item is retained. The requester and new item are named TermiFreedom.

The server editor’s password field stores a password in macOS Keychain. Leaving it blank retains an existing saved password; the removal checkbox deletes it. A changed host, port or username requires a new password save. An exact password-prompt match is required, so aliases that resolve to a different hostname/user may need manual password entry. Key passphrases and MFA are never answered with the server password.

From a running SSH tab, Add key to server opens a separate SSH connection to install only a public key. Choose an existing `.pub` file or create a dedicated Ed25519 key. Generated private keys have no passphrase and are protected by local file permissions; anyone with access to your Mac account could use them. Existing encrypted keys retain their normal passphrase behavior. The operation preserves existing authorized keys, avoids duplicates and does not remove password login. Saved passwords are retained. An already open tab keeps its original authentication environment; use a new tab after changing connection settings.

## SFTP files

Select a server and click Files, or choose Browse files from its context menu. The separate window starts disconnected; click Connect to browse. It uses a separate SSH process and leaves terminal sessions alone. The remote account must have an SFTP subsystem available.

Double-click folders to enter them; use Home, Up, Refresh or the path field to navigate. Search filters the current folder. Hidden files are optional. Columns show size, permissions and modification time. UTF-8 filenames with spaces, quotes and wildcard characters are handled as literal paths.

Upload accepts multiple regular files and processes them in sequence. If a name exists, replacement needs confirmation. Servers without atomic replacement support require a different destination name. Download saves one selected regular file with the native save dialog; an existing local file requires the dialog’s replacement approval. Downloads are created with private local permissions. Folder creation and renaming are available; deleting remote files and recursive folder transfers are not yet included.

Transfers use temporary sibling files and commit at completion. Cancelling attempts cleanup, then interrupts a stalled connection. A connection failure may leave a remote `.termifreedom-….part` file that can be removed later with another file client. Closing a busy file window asks before stopping it. File transfer history is kept only in memory and capped at 50 entries.

## Local builds and updates

The app is ad-hoc signed for personal use. macOS may ask for Keychain permission after a rebuild. Keep existing sessions open in the old version until ready to quit and reopen the new one. No update process automatically terminates them. Tunnels are explained in Help; they are not enabled or created in this version.
