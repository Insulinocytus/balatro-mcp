# Semantic Action 返回完整 State Snapshot

AI Agent 在收到 Compact Projection 后仍会再次调用 `get_game_state`，因此精简响应没有减少实际调用，反而引入两套状态合同。Semantic Action 和可附带状态的工具错误改为返回完整 State Snapshot，并删除 `detail` 与 Compact Projection；这取代 ADR 0006 的精简投影决定及 ADR 0008 对其继续有效的表述，短 State Hash、Target ID 和 `content.text` JSON 镜像仍然保留。
