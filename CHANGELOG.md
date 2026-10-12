# Changelog

## 1.2.0 (unreleased)

### Breaking

- `get_effect_encyclopedia` entries now require `set` and `status` instead of `key` and `set`. In Fair Mode, locked and undiscovered entries no longer include `key`, `name`, or `description`. Clients that index entries by `key` must handle entries without a key.

### Added

- Effect Encyclopedia entries have a `status` of `locked`, `undiscovered`, or `discovered`.
- Locked Jokers, Decks, and Vouchers are listed with `unlock_condition`, the in-game unlock hint. It includes live profile progress where the game shows it.
- Fair Mode now lists Legendary Jokers as locked, with the in-game `?????` hint, and The Soul and Black Hole as undiscovered. It previously omitted them.
- The Game Rules Skill has an "Unlocks and discovery" section.
- The README has a Roadmap section.

### Changed

- `start_run` tells agents to omit `seed` unless the user asks for one, because seeded runs never unlock or discover content.
- The Game Rules Skill no longer has its own version. It ships in the same release ZIP as the mod.

## 1.1.1 - 2026-10-08

### Changed

- Supports Steamodded `1.0.0~BETA-1224a` or newer.

## 1.1.0 - 2026-10-04

### Added

- MCP clients using 2025-03-26, 2025-06-18, or 2025-11-25 are supported on the same Streamable HTTP endpoint, alongside 2026-07-28.

### Changed

- Game actions, visibility rules, and state hashes are the same for every protocol version. There are no Session IDs and no deprecated HTTP+SSE transport.
- Delayed responses and 2025-03-26 batch requests are preserved, including null values and invalid batch entries.

## 1.0.0 - 2026-09-05

- Initial release.
