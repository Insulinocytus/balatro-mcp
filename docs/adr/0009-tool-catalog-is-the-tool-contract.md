# Tool Catalog 是工具合同的单一来源

Game MCP Server 以 Tool Catalog 统一声明每个 tool 的用途、参数、静态有限集合、前置条件、成功 `outputSchema` 和可能的领域错误，并由它生成运行时 `tools/list`。README 只提供项目概览，不重复完整工具合同。`outputSchema` 只约束成功的 `structuredContent`，`isError: true` 继续使用独立错误结构；当前 Decision State 才能确定的动态有限集合仍由 Legal Action Descriptor 和错误响应给出。这样可以避免工具说明、Schema 和错误消息分别维护后发生漂移。
