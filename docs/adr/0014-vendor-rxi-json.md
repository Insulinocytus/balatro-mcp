# 自带 rxi/json.lua 作为 JSON 编解码器

部分取代 [ADR 0004](0004-use-native-lua-and-steamodded-seams.md)：仅对 JSON 编解码器放开「不使用生产环境 vendored 库」一句，其余约束（无构建、无 Lovely 源码补丁、无转译、无原生扩展、无 LuaRocks）不变；再引入其他 vendored 库需另立 ADR。Game MCP Server 只在 HTTP 上与 AI Agent 交换 JSON，与 Balatro/Steamodded 之间是 Lua 调用，因此没有理由依赖 Steamodded 未在文档中承诺的全局 `JSON`；自带编解码器后，生产与测试使用同一份实现，测试也不再需要外部 Steamodded 源码。

`src/json.lua` 是 [rxi/json.lua](https://github.com/rxi/json.lua) 提交 `dbf4b2dd2eb7c23be2773c89eb059dadd6436f94`（`_version = "0.1.2"`）的逐字节副本，保留 MIT 许可头，与本项目 GPL-3.0-or-later 兼容；StyLua 忽略该文件以保持与上游一致。它与 Steamodded 自带的 `libs/json/json.lua` 是同一版本，解码时同样把 `null` 丢弃为 `nil`，因此 [ADR 0013](0013-support-legacy-streamable-http.md) 的 null 保护仍然需要。
