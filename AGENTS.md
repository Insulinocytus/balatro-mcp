# Repository Guidelines

## Project Structure & Module Organization

`main.lua` is the Steamodded entry point; `config.lua` and `balatro-mcp.json` define runtime defaults and mod metadata. Core code lives in `src/`: `game_mcp_server.lua` handles MCP requests, `http_worker.lua` owns loopback HTTP I/O, `balatro_adapter.lua` translates Balatro state and actions, and `tool_catalog.lua` defines the public tool contract. Tests and fixtures are under `tests/`, including vendored LuaUnit. Architectural decisions belong in `docs/adr/`; domain terminology is defined in `CONTEXT.md`. The published agent skill lives at `skills/balatro-game-rules/SKILL.md`.

## Build, Test, and Development Commands

- `mise install` installs the pinned LÖVE, StyLua, Lua language server, Node, and MCP conformance tools.
- `mise run check` runs formatting checks, static diagnostics, LÖVE/LuaUnit tests, and MCP `2026-07-28` conformance. Set `STEAMODDED_SOURCE` to a Steamodded source checkout first.
- `mise run package` creates `dist/balatro-mcp-<version>.zip` and verifies its runtime-only layout.
- `mise exec -- stylua .` formats Lua files before the full check.

## Coding Style & Naming Conventions

Follow `stylua.toml`: four spaces, Unix line endings, 100-column lines, double quotes when either quote style works, and parentheses on calls. Use `snake_case` for files, locals, and functions; use `PascalCase` for module tables and LuaUnit suites. Keep modules as small returned tables and preserve existing EmmyLua annotations. Treat `tool_catalog.lua` as the source of truth for schemas rather than duplicating tool definitions.

## Testing Guidelines

Write LuaUnit methods named `test_<behavior>` in `tests/*_test.lua`; place reusable game-state doubles in `fake_balatro_adapter.lua` and vanilla prototype fixtures in the existing `vanilla_*_prototypes.lua` files. Every behavior or protocol change should include a regression test. There is no percentage coverage target; existing assertions enforce protocol, runtime-branch, and vanilla-content coverage. Run `mise run check` before submitting.

## Commit & Pull Request Guidelines

Recent history favors short Conventional Commit subjects such as `feat: capture vanilla blind effects`, `fix: fail closed on invalid resolution output`, and `test: prove vanilla runtime contract`. Keep each commit focused. Pull requests should explain observable behavior, link relevant issues, list validation performed, and call out MCP schema or compatibility changes. Add screenshots only for UI/configuration changes and concise logs for runtime failures.

## Security & Configuration

Keep the server bound to loopback. Preserve host, origin, content-type, size, and timeout validation in `http_worker.lua`. Do not commit local paths, generated `dist/` archives, or conformance results.
