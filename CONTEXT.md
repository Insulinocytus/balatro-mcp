# Balatro MCP

本项目定义外部 AI 系统观察和操作 Balatro 对局时使用的领域语言，同时明确 AI 策略不属于游戏集成部分。

## 语言

**Game MCP Server（游戏内 MCP 服务器）**：
将 Balatro 对局以结构化状态和语义动作形式暴露给 MCP 的游戏内接口。它不选择动作，也不管理自主游玩循环。
_避免使用_：AI 玩家、AI Agent、运行器

**Vanilla Content Scope（原版内容范围）**：
Game MCP Server 的状态、效果和 Resolution Trace 合同只覆盖原版 Balatro 内容；Steamodded 作为运行框架存在，但与其他内容 Mod 混用不在兼容性或正确性保证范围内。
_避免使用_：通用 Mod MCP、第三方效果兼容层

**AI Agent（AI Agent）**：
调用 Game MCP Server 的外部决策主体，反复观察 State Snapshot、选择 Semantic Action 并推动对局。模型调用、策略、记忆和自主循环属于它，不属于 Mod。
_避免使用_：AI Runner、AI 运行器、MCP 服务器、游戏模组

**State Snapshot（状态快照）**：
对当前决策状态的筛选描述，包含当前可见性模式、状态哈希和 Legal Action Descriptor。它不是 Balatro 全局运行时状态的序列化结果；显式查询和语义动作都返回完整快照。
_避免使用_：游戏转储、`G` 序列化、精简投影

**Decision State（决策状态）**：
游戏正在等待玩家选择或已经到达终局结果的稳定状态。游戏内 MCP 服务器只暴露决策状态；动画和尚未完成的事件链属于其内部转换。
_避免使用_：帧、画面、动画状态

**State Hash（状态哈希）**：
由当前对局标识、决策序列和状态快照共同生成的指纹。即使可见状态随后再次相同，它也会拒绝在游戏经历了其他决策状态后提交的旧语义动作。
_避免使用_：状态版本、存档版本、游戏版本

**Target ID（目标 ID）**：
语义动作可指定的某一具体卡牌、物品或选择在当前快照中的标识，只与同一 State Hash 组合使用时有效。隐藏对象在变为隐藏或被意在打断玩家追踪的游戏效果打乱时更换匿名 ID；可预测的位置变化和玩家主动重排保留 ID。
_避免使用_：游戏内部 key、Lua 对象地址、跨对局持久身份

**Semantic Action（语义动作）**：
打出手牌、选择 Blind 或购买商店物品等游戏领域命令。它描述玩家意图，并在完成后返回新的完整 State Snapshot；存在可观察结算事件时还会返回 Resolution Trace，而不是暴露鼠标、键盘或内部 UI 回调。
_避免使用_：点击、输入事件、原始回调

**Legal Action Descriptor（合法动作描述）**：
State Snapshot 中描述当前可提交 Semantic Action 的数组项，包含 tool 和仅由当前 Decision State 决定的目标集合、数量边界与必要约束，不重复静态 tool Schema。满足描述的调用除过期 State Hash 等并发变化外应当合法。
_避免使用_：合法 tools 列表、工具名列表

**Resolution Trace（结算轨迹）**：
Semantic Action 成功完成过程中影响游戏状态或决策的原版效果记录，仅在至少存在一个事件时返回；调用动作本身、失败响应、纯动画和显示文本不进入该记录。事件标明原版结算阶段；每次组件触发及重触发独立包含有序原子效果、来源和原因，计分或金钱效果附带应用后的运行值，被 Debuff 阻止也显式记录。
_避免使用_：调试日志、最佳努力遥测、计分文本

**Diagnostic Trace（诊断轨迹）**：
为排查 Game MCP Server 故障而保留的本地事件序列，关联请求、Decision State、Semantic Action、内部等待门控与稳定结果。它不是客户端合同，也不受 Fair Mode 的信息边界约束；是否启用或分享由用户决定。
_避免使用_：Resolution Trace、State Snapshot、重放文件

**Resolution Source Reference（结算来源引用）**：
Resolution Trace 只用 `input_target_id` 引用动作输入 State Snapshot 中已有的来源，不建立输入与输出对象的身份映射。动作中新创建对象只返回公开语义结果，其合法 Target ID 由动作后的 State Snapshot 提供。
_避免使用_：输出 Target ID、持久对象 ID、轨迹 Target ID

**Hand Order Projection（手牌排序投影）**：
State Snapshot 的 `hand` 数组始终表示会影响结算的当前手牌顺序；只有存在背面手牌时，才额外返回 `hand_order_projections` 中精确对应游戏 UI 的点数与花色 Target ID 顺序。两种额外顺序仅供公平推断，不对应 Semantic Action，也不暴露当前排序模式。
_避免使用_：第二套手牌、复制手牌、排序工具

**Fair Mode（公平模式）**：
默认可见性策略，只允许外部系统获得人类玩家通过游戏界面、动画和合法操作能够获知或推断的信息，包括按点数与花色排序背面手牌产生的相对位置信息。它阻断稳定内部标识符、错误差异等游戏界面之外的侧信道，并由游戏内持久 Mod 设置控制。
_避免使用_：部分状态

**Omniscient Debug Mode（全知调试模式）**：
通过游戏内持久 Mod 设置显式启用的诊断可见性策略，可以为测试和调查暴露通常隐藏的当前内部信息。配置页持续显示警告，每个 State Snapshot 明示该模式。
_避免使用_：公平模式、全知模式

**Effect Encyclopedia（效果百科）**：
由独立只读 tool 返回的卡牌与物品原型名称及基础效果对照，不附带在 Semantic Action 响应中。AI Agent 在上下文缺少当前可见性模式的百科时应至少查询一次，模式切换后重新查询；Game MCP Server 不追踪或强制该上下文要求。
_避免使用_：图鉴、收藏柜、对象池、静态表

**Game Rules Skill（游戏规则 Skill）**：
与 Mod 同版本发布的可移植英文静态规则资料，供 AI Agent 加载原版 Balatro 的牌型、计分、Ante/Blind/商店循环与利息。它不是 Game MCP Server 的 tool、Effect Encyclopedia、State Snapshot 或策略指南。
_避免使用_：`get_game_rules`、玩法手册、教程全文、MCP prompt
