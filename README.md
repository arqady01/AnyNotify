# AnyNotify

AnyNotify 是一个原生 macOS 菜单栏工具，用来监控 Claude Code 和 Codex 的任务状态，并在任务开始、完成、失败、中断或等待用户输入时发送桌面通知。

所有日志解析都在本机完成，应用不会上传会话内容。

## 功能

- 监控 Claude Code 和 Codex 的本地会话日志；
- 识别任务开始、完成、失败、中断和等待输入；
- 通过 macOS 通知中心发送横幅和声音提醒；
- 所有控制集中在 macOS 菜单栏，不显示常驻主窗口或 Dock 图标；
- 过滤 Codex 子 Agent，避免父子任务重复通知；
- 对 Hook 和日志产生的重复事件进行短时间去重；
- 支持安装、卸载 Claude Code 原生 Hooks；
- Claude Code 或 Codex 任务完成时显示可拖动悬浮窗，并启动可配置倒计时；
- 启动时从日志末尾开始读取，不会重新通知历史任务。

完成提醒悬浮窗会保持置顶。提醒时长可在菜单栏中设置为 1–60 分钟，默认 3 分钟。倒计时归零后显示“已超时”；如果倒计时期间又检测到新的完成事件，会立即按当前设置重新开始。

倒计时剩余 30 秒时会连续播放八次系统提示音，每次间隔约 2 秒；归零时会再次播放一次提示音。手动关闭提醒或检测到新任务开始后，尚未触发的倒计时声音会被取消。

悬浮窗可以点击“我知道了”手动关闭；检测到 Claude Code 或 Codex 的新任务开始后，也会自动关闭上一条完成提醒并停止倒计时。

## 支持的状态

| 状态 | Claude Code | Codex |
| --- | --- | --- |
| 开始 | 用户消息事件 | `task_started` |
| 完成 | Assistant `end_turn`、Stop Hook | `task_complete`、`final_answer` |
| 等待输入 | `AskUserQuestion`、PermissionRequest Hook | `request_user_input` |
| 中断 | `agents_killed` 等明确事件 | `turn_aborted`、`task_aborted` |
| 失败 | 最终回复中的终止性错误 | Session 错误事件、`codex-tui.log` |

Claude Code 对“等待权限”和部分中断场景不会始终写入稳定的会话事件，因此建议在应用中安装 Claude Hooks。

## 工作原理

```text
~/.claude/projects/**/*.jsonl ─┐
Claude Stop/Permission Hooks ──┤
                              ├─> 状态解析 -> 子任务过滤 -> 去重 -> macOS 桌面通知
~/.codex/sessions/**/*.jsonl ──┤
~/.codex/log/codex-tui.log ────┘
```

日志采用增量读取方式：每个文件分别保存读取偏移，只处理新增内容。文件被截断时会自动从头重新读取，尚未写完的最后一行会保留到下一次轮询。

应用当前同时跟踪每个来源最近更新的 8 个 JSONL 文件，以支持并行会话。

## 使用方法

### 1. 构建并启动

在项目根目录执行：

```bash
./script/build_and_run.sh
```

脚本会停止已经运行的 AnyNotify、使用 Xcode 构建 Debug 版本，然后启动新生成的应用。

也可以使用 Codex 桌面端中的 `Run` 操作，配置位于：

```text
.codex/environments/environment.toml
```

### 2. 允许桌面通知

首次启动时，macOS 会请求通知权限。请选择“允许”。如果之前拒绝，可以前往：

```text
系统设置 -> 通知 -> AnyNotify
```

在菜单栏中点击“发送测试提醒”，可以检查横幅、声音和悬浮倒计时是否正常。

### 3. 安装 Claude Hooks

在 AnyNotify 菜单栏中点击“安装 Claude Hooks”。应用会向 `~/.claude/settings.json` 添加两个 Hook：

- `Stop`：Claude Code 一轮任务停止时通知；
- `PermissionRequest`：Claude Code 等待权限确认时通知。

安装过程会保留用户已有配置，只添加 AnyNotify 自己的命令。点击“卸载 Hooks”时，也只会删除 AnyNotify 添加的条目。

即使不安装 Hooks，应用仍会监控 Claude JSONL 日志；但权限等待通知和任务完成的及时性可能稍弱。

### 4. 保持应用运行

AnyNotify 是纯菜单栏应用，需要保持运行才能持续监听日志。从菜单栏选择“退出”才会结束进程。

## 运行脚本参数

```bash
./script/build_and_run.sh [run|--debug|--logs|--telemetry|--verify]
```

| 参数 | 用途 |
| --- | --- |
| `run` | 默认模式，构建并启动应用 |
| `--debug` | 使用 LLDB 启动应用二进制 |
| `--logs` | 启动应用并持续查看进程日志 |
| `--telemetry` | 查看 `com.mengfs.AnyNotify` 子系统日志 |
| `--verify` | 启动后确认 AnyNotify 进程存在 |

构建产物默认位于：

```text
.build/DerivedData/Build/Products/Debug/AnyNotify.app
```

## 开发环境

当前项目配置：

- SwiftUI + AppKit；
- Xcode 工程：`AnyNotify.xcodeproj`；
- Scheme：`AnyNotify`；
- Bundle Identifier：`com.mengfs.AnyNotify`；
- 当前 macOS Deployment Target：`26.2`；
- App Sandbox 已关闭。

关闭 App Sandbox 是有意设计：应用需要在不反复弹出目录选择器的情况下读取 `~/.claude`、`~/.codex`，并在用户点击安装按钮后修改 `~/.claude/settings.json`。

## 项目结构

```text
AnyNotify/
├── AnyNotifyApp.swift                  应用入口和菜单栏场景
├── Models/
│   ├── TaskEvent.swift                统一任务事件模型
│   └── CompletionReminder.swift       可配置完成提醒状态
├── Services/
│   ├── LogMonitoringEngine.swift      日志发现、增量读取和轮询
│   ├── LogParsers.swift               Claude/Codex 状态解析器
│   ├── DesktopNotificationService.swift macOS 通知服务
│   ├── CompletionReminderPanelController.swift 完成提醒悬浮面板
│   └── ClaudeHookManager.swift        Claude Hooks 安装和卸载
├── Stores/
│   └── MonitorStore.swift             应用状态、去重和通知调度
└── Views/
    ├── CompletionReminderView.swift   完成提醒倒计时
    └── MenuBarView.swift              菜单栏菜单

AnyNotifyTests/AnyNotifyTests.swift     状态解析单元测试
script/build_and_run.sh                 统一构建运行入口
AnyNotifyInfo.plist                     URL Scheme 和应用元数据
```

## 构建和测试

构建：

```bash
xcodebuild \
  -project AnyNotify.xcodeproj \
  -scheme AnyNotify \
  -configuration Debug \
  -derivedDataPath .build/DerivedData \
  build
```

运行所有测试：

```bash
xcodebuild \
  -project AnyNotify.xcodeproj \
  -scheme AnyNotify \
  -configuration Debug \
  -derivedDataPath .build/DerivedData \
  test
```

只运行解析单元测试：

```bash
xcodebuild \
  -project AnyNotify.xcodeproj \
  -scheme AnyNotify \
  -configuration Debug \
  -derivedDataPath .build/DerivedData \
  -only-testing:AnyNotifyTests \
  test
```

当前单元测试覆盖：

- Claude Code 正常完成；
- Codex 等待输入和任务中断；
- Codex 子 Agent 通知过滤。
- 完成提醒倒计时与自定义时长持久化。
- 完成提醒手动关闭和新任务开始时自动关闭。

## 隐私和权限

- 会话日志只在本机解析；
- 没有网络请求或远程数据上传；
- 通知摘要只有在用户主动开启后才会显示最终回复的第一条有效文本；
- 最近状态只保存在内存中，应用退出后会清空；
- Claude Hooks 只有在用户点击安装按钮后才会写入配置；写入前会备份原始配置，配置 JSON 损坏时不会覆盖；
- 通知默认只显示来源和状态，不显示任务摘要；开启“通知中显示任务摘要”后，摘要仍会过滤常见 API Key、Token、密码和私钥标记。

如果不希望锁屏通知显示任务摘要，可以保持“通知中显示任务摘要”关闭，或在 macOS 通知设置中关闭 AnyNotify 的通知预览。

## 常见问题

### 来源状态显示为灰色

这通常说明对应目录还不存在：

```text
~/.claude/projects
~/.codex/sessions
```

至少运行一次对应 CLI 后，目录和会话文件才会生成。

### 没有收到通知

依次检查：

1. AnyNotify 是否仍在运行；
2. 菜单栏中的“监控任务状态”开关是否打开；
3. macOS 是否允许 AnyNotify 发送通知；
4. 点击“发送测试提醒”是否成功；
5. Claude Code 是否已安装 Hooks；
6. 对应来源目录是否显示为可用。

### 同一任务收到两次通知

应用会依据来源、状态、会话/轮次和摘要进行去重，并对 Hook 与 JSONL 的重复事件设置短窗口过滤。如果 Claude/Codex 日志格式发生变化，仍可能出现无法关联的重复事件。

### Claude 中断没有通知

只有日志或 Hook 提供明确终止事件时才能可靠识别。直接强制结束整个 Claude 进程可能来不及写入事件，这种情况当前不会使用“进程是否存在”进行猜测。

## 已知限制

- Claude Code 和 Codex 的 JSONL 日志格式不是稳定的公共 API，升级 CLI 后可能需要同步调整解析规则；
- Claude 权限等待依赖 `PermissionRequest` Hook 才最可靠；
- 强制杀死 CLI 进程时可能没有中断事件；
- 最近事件没有持久化，应用重启后历史列表会清空；
- 当前只提供 Debug 构建运行流程，尚未加入正式发布、归档和公证配置。

## 设计参考

更完整的最初设计和兼容性规划见：

- [`claude-codex-monitor-replication.md`](claude-codex-monitor-replication.md)
