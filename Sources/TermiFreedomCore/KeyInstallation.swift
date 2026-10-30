import Foundation

public struct SSHPublicKey: Equatable {
    public let algorithm: String
    public let blob: String
    public var material: String { "\(algorithm) \(blob)" }
    public init(_ text: String) throws {
        let fields = text.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: { $0 == " " || $0 == "\t" })
        let types = ["ssh-ed25519", "ssh-rsa", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521", "sk-ssh-ed25519@openssh.com", "sk-ecdsa-sha2-nistp256@openssh.com"]
        guard fields.count >= 2, types.contains(String(fields[0])), let bytes = Data(base64Encoded: String(fields[1])), (40...16384).contains(bytes.count), !text.trimmingCharacters(in: .whitespacesAndNewlines).contains("\n") else { throw ValidationError("Choose a single OpenSSH public key (.pub), not a private key or certificate.") }
        let length = bytes.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length < 128, bytes.count >= 4 + Int(length), String(data: bytes.subdata(in: 4..<(4 + Int(length))), encoding: .utf8) == String(fields[0]) else { throw ValidationError("The public key format is invalid.") }
        algorithm = String(fields[0]); blob = String(fields[1])
    }
}

public enum KeyInstallation {
    // The key arrives on stdin; no untrusted key text is interpolated into commands.
    // Refuse symlinks and nonregular files. Do not weaken an existing key's restrictions.
    public static let script = #"""
    set -eu
    IFS= read -r material
    type=${material%% *}
    blob=${material#* }
    command -v awk >/dev/null 2>&1 || { echo "Server requires awk to safely check existing keys" >&2; exit 1; }
    umask 077
    directory="$HOME/.ssh"
    file="$directory/authorized_keys"
    [ ! -L "$directory" ] && [ ! -L "$file" ] || { echo 'Refusing symlinked SSH files' >&2; exit 1; }
    [ ! -e "$directory" ] || [ -d "$directory" ] || exit 1
    mkdir -p "$directory"
    [ ! -e "$file" ] || [ -f "$file" ] || exit 1
    touch "$file"
    chmod 700 "$directory"
    chmod 600 "$file"
    if ! awk -v t="$type" -v b="$blob" '{for(i=1;i<NF;i++) if($i==t && $(i+1)==b) found=1} END {exit !found}' "$file"; then
        printf '\n%s TermiFreedom\n' "$material" >> "$file"
    fi
    printf 'TERMIFREEDOM_KEY_INSTALLED\n'
    """#
    public static var remoteCommand: String { "sh -c " + shellQuote(script) }
    public static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    public static func arguments(server: Server) throws -> [String] {
        var args = try server.sshArguments()
        args.removeAll { $0 == "-tt" }
        args.insert("-T", at: 0)
        args += [remoteCommand]
        return args
    }
}
