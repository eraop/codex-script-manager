# Codex Actions

在 Codex 桌面端管理 macOS 本地项目的脚本。

| 入口 | 使用方式 |
| --- | --- |
| 插件侧栏 | 从 Codex 侧栏打开「脚本管理 / Script Manager」，管理已添加的本地项目脚本和日志 |
| 会话技能 | 在本地项目会话中选择 `script-manager` 技能，用原生浮窗打开当前项目或工作树 |
| 项目 Action（可选） | 在项目会话中运行「脚本管理」，直接打开同一个原生浮窗 |

所有入口共用一个本地运行管理器。关闭浮窗或切走侧栏界面后，脚本会继续运行，重新打开任一入口即可查看状态和最近一次运行的日志。退出本地脚本管理器时会停止它托管的脚本。

## 安装脚本管理插件

需要 macOS 13+、Xcode 或 Command Line Tools、Python 3.9+ 和支持本地插件的 Codex 桌面端。在仓库根目录执行以下命令。

```bash
./scripts/package-plugin.sh
codex plugin marketplace add "$(pwd -P)/build/codex-marketplace"
codex plugin add script-manager@codex-actions
```

在 Codex 最左侧的「探索」（…）找到「脚本管理 / Script Manager」，选择固定到侧栏。若刚安装的插件尚未显示，可在当前任务结束后重开桌面端。 [Codex 插件安装](https://developers.openai.com/plugins/build/plugins#install-a-local-plugin-manually) · [侧栏 App](https://developers.openai.com/plugins/build/extensions#sidebar-apps)

侧栏面板随 Codex 界面切换简体中文和英文。原生浮窗打开时读取 Codex 的当前语言，读不到时使用 macOS 首选语言。插件列表和侧栏入口使用固定的双语名称。脚本自身的日志保留原文。

侧栏默认显示 Codex 已添加的本地项目。Codex 中置顶的项目按置顶顺序显示在最上方。用「打开项目」也可以添加其他本机文件夹，它们会保存在脚本管理中。项目和脚本可分别搜索，脚本还可按包或运行状态筛选。宽度不足时，日志移到项目和脚本下方。

若安装过独立的「脚本管理 MCP」，安装新版后可移除旧插件和它的市场。

```bash
codex plugin remove script-manager-mcp@codex-actions-mcp
codex plugin marketplace remove codex-actions-mcp
```

## 安装项目 Action（可选）

在仓库根目录执行以下命令，安装器需要 Python 3.11+ 或装有 `tomli` 的 Python。

```bash
./scripts/build.sh
./scripts/install-action.py '/目标项目根目录'
```

安装器将「脚本管理」添加到项目的 `.codex/environments/environment.toml`，保留其他配置。可用 `--environment 文件名.toml` 选择已有环境、`--app '/应用路径.app'` 指定应用，或用 `--dry-run` 查看生成的命令。

在目标项目的本地会话中，按 `⌘K` 搜索并运行「脚本管理」。若当前会话已打开，切换到其他会话后再回来即可刷新环境配置。 [Codex 项目 Actions](https://learn.chatgpt.com/docs/environments/local-environment#actions)

## 支持的脚本

- Node.js 项目从 `package.json` 发现脚本，按声明或锁文件选择 npm、pnpm、Yarn 或 Bun。
- Spring Boot 的 Maven 和 Gradle 模块支持 Run 和 Debug。调试地址为 `127.0.0.1:5005`。
- 脚本和构建任务均在各自配置文件所在的目录执行，子模块也一样。
- 各入口都使用 `apps/macos/` 的脚本发现和进程管理代码，插件位于 `plugins/script-manager/`。
