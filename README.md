# Balatro MCP

A Balatro mod that exposes game state and semantic actions to local AI clients through MCP.

## Installation

1. Install Lovely and Steamodded by following the [Steamodded installation guide](https://github.com/Steamodded/smods/wiki).
2. Download a ZIP from [Releases](https://github.com/Insulinocytus/balatro-mcp/releases), extract it, and copy `balatro-mcp/` to `%APPDATA%/Balatro/Mods/`.
3. Copy `balatro-game-rules/` to your AI agent's skills directory.
4. Start Balatro and connect your MCP client using **Streamable HTTP** to `http://127.0.0.1:18790/mcp`.

If the version you need is not listed in Releases, build the current checkout with `mise run package` and install the generated ZIP.

### Upgrading

Close Balatro, replace the existing `balatro-mcp/` folder with the one from the new ZIP, and update `balatro-game-rules/` in your agent's skills directory. Restart the game and reconnect the MCP client. Updating a source checkout does not update an installed copy of the Mod.

## Features

- Read filtered Balatro game state.
- Perform semantic actions such as playing, discarding, buying, and selecting.
- Switch between fair and omniscient debugging modes.
- Includes an English Balatro Game Rules Skill.
- Listens only on the local loopback interface.

## MCP compatibility

Version `1.1.0` adds support for initialization-based MCP clients while preserving the modern protocol. Use a `1.1.0` or newer build for the legacy compatibility described below.

- Supports MCP `2026-07-28`, `2025-11-25`, `2025-06-18`, and `2025-03-26` on the same endpoint.
- Legacy clients use `initialize`, then `notifications/initialized`, followed by normal tool requests. No modern request metadata or `Mcp-Method` header is required for legacy clients. Send the negotiated `MCP-Protocol-Version` on subsequent requests; requests without that header default to `2025-03-26`.
- Modern clients keep the `2026-07-28` discovery and per-request metadata lifecycle. Use `auto` only if the client supports protocol auto-detection.
- The server does not assign Session IDs or provide the deprecated HTTP+SSE transport. Opening `/mcp` in a browser sends GET and returns `405`; this is expected, not a startup failure.
- March clients receive the complete tool payload as JSON in `content[].text`; June and November clients also receive `structuredContent` and `outputSchema`. Game semantics and state hashes are shared across versions. The snapshot's fixed `protocol_version` describes its existing semantic contract, not the client's negotiated transport version.

## Development

Set `STEAMODDED_SOURCE` and `BALATRO_SOURCE` to the Steamodded and extracted Balatro source directories, then run `mise run check`. To run just the legacy HTTP regressions, use `mise exec -- lovec tests -p test_legacy -p test_march`.

Run `mise run package` to build a ZIP from the current checkout. The archive is written to `dist/balatro-mcp-<version>.zip`; the command verifies that the Mod and Skill versions match and that the archive contains only runtime files.

## License

Licensed under the [GNU General Public License v3.0 or later](LICENSE).

Copyright (C) 2026 Insulinocytus
