# 使用自足的 Diagnostic Trace 排查 MCP 故障

Game MCP Server 将同一次启动的 Lovely 日志作为所有已进入服务器请求的首要支持材料：`debug` 级别记录可关联请求、Decision State、Semantic Action、等待门控与稳定结果的自足 Diagnostic Trace，失败在较低日志级别也保留密集摘要。Diagnostic Trace 与客户端协议和 Resolution Trace 分离，可以包含不受 Fair Mode 限制的本地游戏诊断信息，但只能序列化白名单字段、不得改变游戏行为；当前日志中开始的对局支持按 seed 和动作轨迹重放，载入存档只承诺生成诊断检查点和最小测试 fixture。