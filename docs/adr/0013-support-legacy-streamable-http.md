# 同端点支持新旧 MCP 生命周期

取代 [ADR 0003](0003-target-modern-mcp-only.md)。实际安装后的旧版客户端因 `initialize` 被拒绝而无法连接，因此同一 `/mcp` 现在支持 `2025-03-26`、`2025-06-18`、`2025-11-25` 的初始化生命周期，同时保留 `2026-07-28` 的无状态发现与请求元数据合同。采用无 Session ID 的 Streamable HTTP；不增加旧式 HTTP+SSE、客户端会话存储或第二套游戏动作实现。

旧版初始化回显受支持的请求版本；未知版本协商到最新支持的旧版 `2025-11-25`。后续请求独立按 `MCP-Protocol-Version` 解释，缺失时按 `2025-03-26` 处理，不记忆上一个客户端的协商结果。现代请求仍须满足原有元数据和头部一致性校验；所有版本共享 loopback、Host、Origin、媒体类型、大小和超时约束。March 接受其规范要求的批请求，顺序处理并等待延迟动作完成，通知不产生 JSON-RPC 回复；初始化不得批处理，其他版本继续拒绝批请求。GET 仍返回 `405`。

Steamodded 的 JSON 解码器会丢弃 `null`，因此请求入口先保护未加引号的 null 字面量，解码后还原为专用哨兵；保留元数据键是否存在及批请求数组位置，防止错误降级和有效邻项丢失，不改变 JSON 字符串或合法对象。

兼容只投影线上协议：旧版结果不含现代 `resultType` 或缓存字段，March 的完整语义负载通过 JSON 文本返回，不公告 `outputSchema` 或返回 `structuredContent`。June 和 November 保留完整输出 Schema 与结构化结果。工具目录仍是唯一合同来源，成功输出在投影之前校验；即时、延迟和错误响应均使用发起请求的协议版本。State Snapshot 的固定 `protocol_version = 2026-07-28` 是既有语义合同标记，不随客户端传输版本改变，避免同一对局产生不同 State Hash；公平信息边界、动作语义和并发仲裁保持不变。

依据：[旧版生命周期](https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle)、[Streamable HTTP 的可选会话与版本头](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports)、[March 批请求](https://modelcontextprotocol.io/specification/2025-03-26/basic/transports)、[新旧协议互操作](https://modelcontextprotocol.io/specification/2026-07-28/basic/versioning)。
