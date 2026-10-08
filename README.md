# Balatro MCP

A Balatro mod that exposes game state and semantic actions to local AI clients through MCP.

## Installation

1. Install Lovely and Steamodded by following the [Steamodded installation guide](https://github.com/Steamodded/smods/wiki).
2. Download a ZIP from [Releases](https://github.com/Insulinocytus/balatro-mcp/releases), extract it, and copy `balatro-mcp/` to `%APPDATA%/Balatro/Mods/`.
3. Copy `balatro-game-rules/` to your AI agent's skills directory.
4. Start Balatro and connect your MCP client using **Streamable HTTP** to `http://127.0.0.1:18790/mcp`.

Supported MCP versions: `2026-07-28`, `2025-11-25`, `2025-06-18`, and `2025-03-26`.

Supported Steamodded versions: `1.0.0~BETA-1224a` (the Nexus Mods release) or newer. [SMODS 26.1002.0](https://github.com/Steamodded/smods/releases/tag/26.1002.0) or newer is recommended: older Steamodded releases have their own vanilla-behavior bugs, such as seeded runs picking different Boss Blinds across game launches ([smods#1529](https://github.com/Steamodded/smods/issues/1529)).

## Features

- Read filtered Balatro game state.
- Perform semantic actions such as playing, discarding, buying, and selecting.
- Switch between fair and omniscient debugging modes.
- Includes an English Balatro Game Rules Skill.
- Listens only on the local loopback interface.

## Development

- Run `mise run check`.
- Run `mise run package` to create `dist/balatro-mcp-<version>.zip`.

## License

Licensed under the [GNU General Public License v3.0 or later](LICENSE).

Copyright (C) 2026 Insulinocytus
