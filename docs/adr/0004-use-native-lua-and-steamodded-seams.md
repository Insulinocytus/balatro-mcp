# 使用原生 Lua 和 Steamodded 接缝

Mod 以无需构建的 Lua 5.1/LuaJIT 源码形式发布，并且只使用 Balatro、LÖVE、Lovely 和 Steamodded 提供的运行时能力。网络轮询通过保留调用链的 `Game.update` 包装进入游戏，玩法观察使用 Mod calculate contexts；除非这些受支持接缝被证明不足，否则不使用 Lovely 源码补丁、转译、原生扩展、LuaRocks 或生产环境 vendored 库。
