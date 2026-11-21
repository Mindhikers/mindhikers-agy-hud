# Changelog

## v0.1.0 (2026-11-21)

- 首次发布 MindHikers AGY HUD 原生 macOS 极简桌面悬浮上下文监控小工具（100% 本地只读，零顶栏占用，零外部网络请求）。
- 自动只读解析 `~/.gemini/antigravity/conversations/*.db`（兼容 SQLite WAL 实时与休眠历史会话）与 `~/.gemini/antigravity/annotations/*.pbtxt`（反重力内切会话秒跟随）。
- 三胶囊悬浮条默认自动对齐 Antigravity 输入栏模型选择器右侧（并预留右侧 Turbo 按钮避让区），支持单胶囊迷你模式、自定义拖拽与停靠预设、双屏自动跟随及 MacBook 刘海安全区避让。
- 独立弹出详情卡支持「会话切换 / 用量与缓存 / 上下文水位（含单请求裁剪预算线与全部分类明细）」三页查看、一键复制 CLI 格式报告与右键快捷设置。
- 内置 `scripts/pre-publish-check.sh` 开源发布前安全门禁。
