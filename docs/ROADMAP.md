# Roadmap

The goal is a reliable, understandable personal Mac client—not an unmeasured claim of being better at every workflow.

## Next candidates

1. File transfer polish: recursive folders with symlink policy, resumable transfers, stronger remote durability, permissions editing, and explicitly confirmed deletion.
2. A local tunnel manager: loopback binding by default, visible source/destination, port-conflict checks, per-tunnel status and stop controls. No automatic remote exposure.
3. Terminal search, tab keyboard navigation, optional themes, and reconnect controls.
4. Synthetic long-session memory/CPU measurements and real-server compatibility testing with user-approved endpoints.
5. Complete Developer ID setup, clean-Mac release verification, and GitHub CI. MIT licensing and local ZIP/DMG release tooling are implemented.

## Port forwarding, in plain language

An SSH tunnel lets another app send traffic through an encrypted SSH connection.

- **Local forwarding:** a Mac app connects to a local port, and SSH sends that traffic to a private service reachable by the server. A typical use is accessing a database without exposing its database port publicly.
- **Remote forwarding:** a server-side port leads back to a service on the Mac. This can make a local service reachable from elsewhere, so the bind address and access rules matter.
- **Dynamic forwarding:** compatible apps use a SOCKS proxy through the server.

Tunnels are not needed for ordinary SSH terminals or SFTP. TermiFreedom currently explains them in Help but does not create them.
