# mindhikers-agy-hud

**100% 本地只读的 Antigravity macOS 极简桌面悬浮上下文监控小工具**（by MindHikers）

专为在意 **Google 账号安全**、不想占用 macOS 刘海屏顶栏、也不想安装高风险多号切换器或开启本地调试端口（CDP）的开发者设计。

---

## 核心特性

- **纯桌面悬浮极简形态（零顶栏占用）**：
  - **三胶囊悬浮条**：不抢输入框焦点、按住左侧手柄自由拖动并记住位置；依次展示活跃状态与模型、累计消耗与缓存命中率、压缩次数与上下文水位。
  - **单胶囊迷你模式**：一键折叠成极简百分比胶囊，随时还原。
  - **全功能内嵌弹出卡片**：点击任意胶囊即弹出独立详情卡（支持「会话切换 / 用量与缓存 / 上下文水位与裁剪线」三页切换），点击外部空白处或按 `Esc` 瞬间收起。
  - **右键 / 卡片菜单**：一键切换停靠位置、指定显示屏幕（默认自动跟随 Antigravity 所在屏幕，自动避让 MacBook 刘海区）、刷新、复制报告或退出。
- **反重力切会话自动跟随**：实时只读监听本地最近查看记录（`annotations/*.pbtxt`）与对话数据库（SQLite WAL），切标签后自动同步。
- **单请求裁剪预算线提示**：除模型原生窗口上限（如 1M）外，直接读取本地记录的 `request_budget_tokens`（如 256k / 512k），提前预警上下文裁剪与压缩。
- **零外部依赖**：SwiftUI + AppKit 原生构建（无需完整 Xcode，仅需 Command Line Tools），直接兼容 macOS 系统自带 Python 3.9+。

---

## 安全与隐私边界（为什么更安全）

本工具严格限定为 **纯本地只读观察者（Read-Only Observer）**：

- **零网络请求**：不访问 Google 任何云端接口，无任何第三方遥测或更新检查。
- **不碰账号凭据**：不读/写 macOS Keychain，不保存或刷新 OAuth Token，不修改官方 `state.vscdb`。
- **零侵入官方客户端**：不修改 `/Applications/Antigravity.app` 安装包，不破坏签名，也不需要以 `--remote-debugging-port` 启动 Antigravity。
- **只读数据库**：仅只读访问 `~/.gemini/antigravity/conversations/*.db` 与 `~/.gemini/antigravity/annotations/*.pbtxt`。

---

## 目录结构

```text
mindhikers-agy-hud/
├── Package.swift                 # Swift Package 清单 (macOS 13+)
├── Sources/MindHikersAgyHUD/     # 原生悬浮窗、详情卡与本地轮询层
├── Resources/
│   ├── hud_parser.py             # 本地只读聚合解析脚本
│   └── context_report.py         # 核心上下文解析器 (源自 MIT 开源项目)
├── scripts/
│   ├── build-app.sh              # 一键编译并打包 .app
│   └── pre-publish-check.sh      # 开源发布前安全检查脚本
└── tests/                        # 解析器单元测试
```

---

## 构建与运行

前置要求：macOS 13+ 与 Xcode Command Line Tools（`swiftc`）。

```bash
# 1. 运行单元测试
python3 -m unittest discover tests

# 2. 编译并打包为原生 .app
./scripts/build-app.sh

# 3. 启动运行（建议拖入 /Applications）
open dist/MindHikersAgyHUD.app
```

> 若从外部下载未经 Apple 付费公证的 `.app` 遇到系统拦截，可自行执行上述源码构建命令，或在终端执行一次 `xattr -cr /Applications/MindHikersAgyHUD.app`。

---

## 发布前检查

```bash
./scripts/pre-publish-check.sh
```

---

## 免责声明与致谢

- 本工具为独立开源辅助工具，与 Google 无关；仅读取本机已落盘的只读对话记录用于个人效率观察。
- 上下文精确分类解析逻辑致谢并基于 [dimitr-io/antigravity-desktop-context](https://github.com/dimitr-io/antigravity-desktop-context)（MIT License）。

## License

[MIT](./LICENSE)
