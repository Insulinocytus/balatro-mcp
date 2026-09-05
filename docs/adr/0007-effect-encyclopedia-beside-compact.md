# Effect Encyclopedia 独立于状态快照

AI Agent需要回想本档案已发现原型的效果，但那不是当前 Decision State，也不能塞进每份 State Snapshot 或写进 MCP resource。查询单独提供 Effect Encyclopedia；`start_run` 的精简投影旁挂同一份公平模式百科，其它 Semantic Action 不带。百科不进入 State Hash。ADR 0002 / 0006 的「查询完整、动作精简」分层不变。

## Considered Options

- **每份完整快照都带**：恢复入口被整本原型表撑爆。否决。
- **只在 `start_run` 带、无独立查询**：主菜单和对局里无法再读。否决。
- **MCP resource**：违反 ADR 0003。否决。
- **AI Agent 自带静态原版文本**：无法按档案过滤 `discovered`，公平模式会剧透。否决。
