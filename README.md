# Balatro MCP

A Balatro mod that exposes game state and semantic actions to local AI clients through MCP.

## Installation

1. Install Lovely and Steamodded ([installation guide](https://github.com/Steamodded/smods/wiki)).
2. Download a ZIP from [Releases](https://github.com/Insulinocytus/balatro-mcp/releases), extract it, and copy `balatro-mcp/` to `%APPDATA%/Balatro/Mods/`.
3. Copy `balatro-game-rules/` to your AI agent's skills directory.
4. Start Balatro and connect your MCP client via **Streamable HTTP** to `http://127.0.0.1:18790/mcp`.

## Compatibility

- MCP: `2026-07-28`, `2025-11-25`, `2025-06-18`, `2025-03-26`.
- Steamodded: `1.0.0~BETA-1224a` or newer. [26.1002.0](https://github.com/Steamodded/smods/releases/tag/26.1002.0) or newer is recommended for its vanilla-behavior fixes.

## Features

- Filtered game state.
- Semantic actions: play, discard, buy, select, and more.
- Fair and omniscient debugging modes.
- Bundled English Balatro Game Rules Skill.
- Loopback-only server.

## Development

- `mise run check`: run all checks.
- `mise run package`: build `dist/balatro-mcp-<version>.zip`.

## License

Licensed under the [GNU General Public License v3.0 or later](LICENSE).

Copyright (C) 2026 Insulinocytus
