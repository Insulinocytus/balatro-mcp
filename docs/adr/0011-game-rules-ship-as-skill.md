# Game Rules 作为 Skill 发布

原版规则不依赖当前对局，也不需要从运行中的游戏读取，因此删除运行时 `get_game_rules` tool，改为维护可移植的英文 `balatro-game-rules` Skill。Skill 与 Mod 使用同一版本，在发布 ZIP 中作为与 `balatro-mcp/` 并列的文件夹交付，正式源码位于 `skills/balatro-game-rules/`。
