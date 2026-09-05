# content.text 重新编码 structuredContent

只读取 MCP `content` 的宿主看不到 `structuredContent`，ADR 0006 的短摘要因此让模型无法提交 Target ID。协议仍可破，因此成功与错误的 `content.text` 都改回同一份 `structuredContent` 的 JSON；解码结果必须与结构化字段相同。ADR 0006 的短 State Hash、短 Target ID、目标来源和精简投影仍然有效，只取代其中「`content.text` 只保留短摘要」一句。接受百科与规则正文重新进入文本通道。

## Considered Options

- **只把合法 Target ID 等可决策子集写入文本**：模型能出招，但两套载荷会分叉，错误恢复还要另定义摘要。否决。
- **改客户端去读 structuredContent / 强制 mcpScript**：只救一种宿主，本仓库范围外的 AI Agent每次都会再踩。否决。
- **双 content block（一行摘要 + JSON）**：仍要维护摘要通道，测试与文档更复杂。否决。
