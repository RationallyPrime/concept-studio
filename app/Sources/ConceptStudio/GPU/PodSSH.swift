import Foundation

enum PodSSH {
    static let preferenceKey = "sshPublicKey"
    static let port = "22/tcp"

    /// Public keys may be sent in a pod environment; private keys stay on the person's Mac.
    static func publicKey(_ text: String) throws -> String {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return "" }
        let algorithms: Set = [
            "ssh-ed25519", "ssh-rsa", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521",
            "sk-ssh-ed25519@openssh.com", "sk-ecdsa-sha2-nistp256@openssh.com",
        ]
        for line in value.split(separator: "\n", omittingEmptySubsequences: false) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2, algorithms.contains(String(fields[0])),
                  let bytes = Data(base64Encoded: String(fields[1])), bytes.count > 4 else {
                throw StudioError.message("Paste an SSH public key, such as the contents of id_ed25519.pub. "
                    + "Keep the private key on this Mac.")
            }
            let length = bytes.prefix(4).reduce(0) { $0 * 256 + Int($1) }
            guard length > 0, length < bytes.count - 4,
                  String(data: bytes.dropFirst(4).prefix(length), encoding: .utf8) == String(fields[0]) else {
                throw StudioError.message("This SSH public key is incomplete or has the wrong key type. "
                    + "Copy the full line from its .pub file.")
            }
        }
        return value
    }
}
