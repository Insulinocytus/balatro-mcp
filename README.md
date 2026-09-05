# Balatro MCP

A Balatro mod that exposes game state and semantic actions to local AI clients through MCP.

## Installation

1. Install Lovely and Steamodded by following the [Steamodded installation guide](https://github.com/Steamodded/smods/wiki).
2. Download the release ZIP and copy `balatro-mcp/` to `%APPDATA%/Balatro/Mods/`.
3. Copy `balatro-game-rules/` to your AI agent's skills directory.
4. Start Balatro and connect your MCP client to `http://127.0.0.1:18790/mcp`. Set the protocol version to `2026-07-28` or `auto`.

## Features

- Read filtered Balatro game state.
- Perform semantic actions such as playing, discarding, buying, and selecting.
- Switch between fair and omniscient debugging modes.
- Includes an English Balatro Game Rules Skill.
- Listens only on the local loopback interface.

## License

Licensed under the [GNU General Public License v3.0 or later](LICENSE).

Copyright (C) 2026 Insulinocytus
