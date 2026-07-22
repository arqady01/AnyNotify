# Claude Code CLI / Codex 任务状态监控复刻说明书

## 1. 目标和边界

目标：在不修改 Claude Code 或 Codex 本身的前提下，监控每一轮任务的：

- 开始；
- 完成；
- 失败；
- 等待用户确认/输入；
- 子 Agent 完成但不应单独通知；
- 重复事件去重。

不把“进程仍然存在”当作任务状态。进程状态只能作为独立的 `run` 模式兜底，不能覆盖交互式 CLI、VSCode 插件或桌面会话。

推荐架构：

```text
Claude Code
  ├─ 原生 Stop Hook（主路径）
  └─ ~/.claude/projects/**/*.jsonl（Watch 兜底）

Codex
  ├─ ~/.codex/sessions/**/*.jsonl（主路径）
  ├─ ~/.codex/logs*.sqlite + WAL（兼容后端）
  └─ ~/.codex/log/codex-tui.log（失败路径）

统一状态事件
  → 去重/耗时阈值
  → 通知渠道
```

## 2. 统一内部事件模型

所有来源都转换成统一事件：

```ts
type TaskEvent = {
  source: 'claude' | 'codex';
  status: 'started' | 'complete' | 'error' | 'confirm';
  taskId?: string;
  turnId?: string;
  sessionId?: string;
  cwd?: string;
  startedAt?: number;
  completedAt?: number;
  durationMs?: number | null;
  taskInfo: string;
  outputContent?: string;
  errorMessage?: string;
  dedupeKey?: string;
};
```

状态处理必须满足：

1. 同一轮任务最多发送一次完成通知；
2. `confirm` 事件不能再触发同一轮的 `complete`；
3. 子 Agent 的完成/确认事件不单独通知；
4. 事件缺少时间戳时使用接收时间；
5. 解析失败不能导致 watcher 退出。

## 3. Claude Code 实现

### 3.1 Hook 主路径

向 `~/.claude/settings.json` 写入原生 Hook。必须保留用户已有配置，只增删本项目自己的条目：

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "<monitor> notify --source claude --from-hook --force"
          }
        ]
      }
    ]
  }
}
```

`<monitor>` 可以是 Node 脚本，也可以是打包后的可执行文件。

Hook 进程要求：

- 从 stdin 读取 JSON；
- 设置有限超时，例如 1500ms，避免 Claude 被 Hook 永久阻塞；
- 解析失败时安全退出；
- 不向 stdout 输出破坏 Claude Hook 协议的内容；诊断写 stderr。

重点字段：

```text
hook_event_name
cwd
transcript_path
last_assistant_message
session_id
entrypoint
promptSource
```

处理流程：

```text
收到 Hook JSON
  → hook_event_name 不是 Stop：忽略
  → 判断是否 SDK 派生会话
  → 提取最终 assistant 文本
  → 文本为空：忽略
  → 匹配失败规则
  → 生成 complete 或 error 事件
  → 可选延迟 0~1500ms
  → 进入统一通知引擎
```

### 3.2 Claude 会话来源过滤

默认只提醒交互式会话，避免 Agent Team、后台 Agent、Workflow、worktree、`claude -p` 等子会话重复提醒。

建议识别规则：

```text
entrypoint === "sdk-cli" 或 promptSource === "sdk" → sdk
entrypoint === "cli"     或 promptSource === "typed" → interactive
否则 → unknown
```

`unknown` 不要默认过滤，否则 transcript 元数据缺失时可能漏报。只有明确识别为 `sdk` 才跳过。

### 3.3 Claude 失败规则

从最终 assistant 文本中提取第一条有效行，并匹配：

```text
API Error: <code>
Error:
错误：
Request failed / Request error
Authentication failed / Authentication error
Connection failed / Connection error
Network error
Rate limit
Timed out
Permission denied
overloaded / over capacity
internal server error
```

命中后生成：

```text
status: error
taskInfo: Claude 失败: <摘要>
skipSummary: true
```

### 3.4 Claude Watch 兜底

当 Hook 没安装或 Hook 未触发时，轮询：

```text
~/.claude/projects/**/*.jsonl
```

实现一个增量 JSONL follower：

- 记录当前文件路径和字节偏移；
- 文件增长时只读取新增内容；
- 文件截断时重置偏移；
- 保留未完成的最后一行；
- 首次接入时读取有限尾部窗口，例如 256KB；
- 每次解析失败只跳过当前行。

每个会话维护：

```text
lastUserText
lastUserAt
lastAssistantText
lastAssistantContent
lastAssistantAt
notifiedForTurn
confirmNotifiedForTurn
pendingTimer
sessionOrigin
lastCwd
```

状态推断：

```text
user 事件
  → 重置本轮状态

assistant 事件
  → 保存文本和时间
  → 启动 quiet timer，例如 60 秒

quiet timer 到期且期间没有新 assistant 事件
  → 生成 complete/error
```

注意：Claude Watch 是静默时间推断，不是官方完成事件，因此必须允许通过配置调整 quiet time。

### 3.5 Claude 授权等待限制

本复刻版本不要把普通文本中的“是否授权”“请确认”直接当作可靠状态。流式输出很容易误报。

如果确实需要精确识别 Claude 权限请求，应单独研究并接入 Claude 对应的权限 Hook 事件，例如 `PermissionRequest`，并为它定义独立的 `confirm` 状态；不要复用 `Stop` 事件。

## 4. Codex 实现

### 4.1 Watch 后端选择

启动时选择后端：

1. 如果存在最近的 `~/.codex/sessions/**/*.jsonl`，优先使用 sessions 后端；
2. 否则查找最近的 `~/.codex/logs*.sqlite`，使用 SQLite 后端；
3. 无论使用哪一个后端，都同时监听 `~/.codex/log/codex-tui.log` 以捕获失败。

允许通过环境变量强制：

```text
CODEX_WATCH_BACKEND=sessions|sqlite|auto
```

### 4.2 Codex sessions JSONL 后端

轮询：

```text
~/.codex/sessions/**/*.jsonl
```

建议同时跟踪最近 N 个文件，例如 5 个，以支持并行会话。每个文件独立维护 follower 和状态机。

需要处理的事件：

| 事件 | 处理 |
|---|---|
| `session_meta` | 保存 session id、cwd、父线程、Agent 信息 |
| `turn_context` | 保存 turn id、协作模式、Plan 模式 |
| `event_msg/task_started` | 标记本轮开始，清理上一轮标志 |
| `event_msg/user_message` | 保存用户文本和开始时间 |
| `response_item` user message | 同上，兼容另一种格式 |
| assistant message | 保存回复文本和时间 |
| `event_msg/task_complete` | 优先生成完成事件 |
| `event_msg/token_count` | 旧格式完成兜底 |
| `response_item` tool call | 检查是否为 `request_user_input` |
| tool call output | 清除已解决的交互等待 |
| reasoning/tool call | 标记会话仍在工作，取消待完成计时器 |

### 4.3 Codex 完成判定

优先级：

```text
1. event_msg.payload.type === "task_complete"
2. assistant message 的 phase === "final_answer"
3. 兼容模式下 assistant 输出 + 静默窗口
4. token_count + grace timer
```

`task_complete` 到达后：

1. 读取 `last_agent_message`、`last_assistant_message`、`message`、`content`、`text`；
2. 保存最终文本；
3. 如果是子 Agent，跳过通知；
4. 如果本轮需要用户输入，转为确认提醒，不发送完成；
5. 如果已经发过确认，跳过完成；
6. 否则生成 `Codex 完成`。

### 4.4 Codex 等待确认/输入

重点检测以下工具调用：

```text
response_item.payload.type ∈ {
  function_call,
  custom_tool_call,
  tool_use
}

并且工具名称为：
request_user_input
```

检测到后：

```text
interactionRequiredForTurn = true
保存 call_id / tool_call_id
解析 question、header、options
如果 confirmAlert.enabled=true → 发送 confirm
```

需要识别的参数形态：

```json
{
  "questions": [
    {
      "header": "权限",
      "question": "是否继续？",
      "options": [
        { "label": "继续" },
        { "label": "取消" }
      ]
    }
  ]
}
```

当收到对应的 `function_call_output` 或 `custom_tool_call_output`，按 call id 清除等待状态。

此外，可以在 `task_complete` 时对最后几行文本做有限兜底匹配，例如：

```text
请确认、是否继续、是否执行、是否授权、请选择、please confirm、approve、proceed
```

这个文本兜底只能在 `task_complete` 时执行，不能在流式输出的每一行执行。

### 4.5 Codex 失败检测

sessions/SQLite 事件主要用于完成和交互；失败单独读取：

```text
~/.codex/log/codex-tui.log
```

匹配终止性错误：

```text
Turn error:
stream disconnected before completion
API Error:
error sending request for url
Please run /login
Authentication failed
Request failed
Connection failed
Network error
timeout waiting for child process to exit
```

必须忽略：

```text
stream disconnected - retrying sampling request
插件同步失败但会继续重试
应用列表/工具建议加载失败但当前 turn 未停止
```

失败事件必须带上最近一次 user prompt、cwd 和 assistant 文本，方便通知内容定位。

### 4.6 子 Agent 与并行会话

从 `session_meta` 识别：

```text
thread_source === "subagent"
source === "subagent"
source.subagent.thread_spawn 存在
```

子 Agent 的完成和确认都不单独通知。

对于同一 `cwd` 下的多个会话：

- 记录所有 active session；
- 某个 session 完成时先暂存；
- 只有同一 cwd 下没有 active session 后才 flush 完成通知；
- 可增加 500~1000ms 的 multi-session quiet window。

不同 cwd 的会话不能互相阻塞。

### 4.7 SQLite 后端

读取最近的 `logs*.sqlite` 和对应 WAL，提取日志中类似：

```text
SSE event: { ... }
```

使用事件唯一键去重：

```text
created:<response.id>
completed:<response.id>
item_done:<item.id>:<sequence_number>
text_done:<item_id>:<sequence_number>
```

完成规则：

- `response.output_item.done` 中 assistant message 的 `phase=final_answer`：可立即通知；
- `response.completed`：作为兜底完成事件；
- 如果之前发现 `request_user_input`，则跳过完成通知。

## 5. 统一通知引擎

所有状态最后进入统一函数：

```text
sendNotifications(event)
```

处理顺序：

1. 来源是否启用；
2. 是否达到耗时阈值；
3. 是否是重复事件；
4. 生成 complete/error/confirm 样式；
5. 并行发送桌面、声音、Webhook、Telegram、邮件等渠道；
6. 返回每个渠道的成功/失败结果。

推荐去重键：

```text
source + cwd + turnId + status + normalizedOutput
```

如果 Hook 和 Watch 可能使用不同 cwd，则应使用显式的 session/turn/content dedupe key，不要只依赖 cwd。

## 6. 推荐开发拆分清单

### P0：基础框架

- [ ] 定义 `TaskEvent` 和 `TaskState` 类型；
- [ ] 实现统一通知接口；
- [ ] 实现配置：来源开关、确认开关、quiet 时间、去重时间；
- [ ] 实现安全 JSON 解析、时间戳解析、文本截断；
- [ ] 实现可持久化 watcher 日志。

### P1：Claude Hook

- [ ] 实现 settings.json 读写和保留用户配置；
- [ ] 实现 Hook 安装、卸载、状态检查；
- [ ] 实现 stdin JSON reader 和超时；
- [ ] 实现 Stop 事件解析；
- [ ] 实现最终 assistant 文本提取；
- [ ] 实现 Claude 失败规则；
- [ ] 实现 SDK/interactive 会话过滤；
- [ ] 添加 Hook 完成、失败、空文本测试。

### P2：Claude Watch

- [ ] 实现 JSONL follower；
- [ ] 轮询最近 transcript 文件；
- [ ] 实现 user/assistant 状态机；
- [ ] 实现 quiet timer；
- [ ] 复用 Claude 失败识别和 session origin 过滤；
- [ ] 添加文件轮换、半行、旧 seed、重复通知测试。

### P3：Codex sessions

- [ ] 实现最近 N 个 session JSONL 跟踪；
- [ ] 处理 `session_meta`、`turn_context`；
- [ ] 处理 `task_started`、`user_message`、assistant message；
- [ ] 处理 `task_complete`；
- [ ] 实现 final_answer/token_count fallback；
- [ ] 实现 request_user_input；
- [ ] 实现子 Agent 过滤；
- [ ] 实现按 cwd 的多会话协调。

### P4：Codex 失败和 SQLite

- [ ] 实现 TUI 日志增量读取；
- [ ] 实现终止性错误匹配；
- [ ] 排除可恢复 WARN 和 retry 日志；
- [ ] 实现 SQLite/WAL 后端；
- [ ] 实现 SSE JSON 提取和事件去重；
- [ ] 添加失败、重试、403 背景告警测试。

### P5：交付和运维

- [ ] GUI 或服务进程能够启动/停止 watcher；
- [ ] watcher 崩溃后可重启；
- [ ] 日志中打印当前 backend 和跟踪文件；
- [ ] 提供 `hooks status`、`watch status`、`paths` 命令；
- [ ] 支持环境变量覆盖路径；
- [ ] 对日志格式变更提供诊断信息，而不是静默失败。

## 7. 验收标准

### Claude

- [ ] 交互式 Claude 一轮完成只通知一次；
- [ ] Claude Stop Hook 能读取最终回复；
- [ ] API Error 能显示为失败；
- [ ] SDK 子会话不会单独通知；
- [ ] Hook 未安装时 Watch 仍能在 quiet window 后通知；
- [ ] transcript 文件切换不会复用上一轮输出。

### Codex

- [ ] `task_complete` 能立即触发完成；
- [ ] 缺少 `task_complete` 时 final_answer fallback 生效；
- [ ] `request_user_input` 只触发确认提醒，不触发完成提醒；
- [ ] 用户回答后后续完成能正常通知；
- [ ] Codex TUI 的终止性错误能触发失败提醒；
- [ ] 可恢复 WARN 不触发失败提醒；
- [ ] 子 Agent 和父 Agent 不重复提醒；
- [ ] 不同 cwd 的并行任务互不阻塞。

## 8. 关键限制和版本适配策略

1. Claude Hook 和 Codex session/SQLite 日志都属于外部接口，CLI 升级后必须保留样本日志回归测试。
2. 不要把任意问号或“授权”关键词直接当成等待确认，否则流式输出会造成误报。
3. 所有 watcher 都必须是增量读取，不能每秒完整扫描大文件。
4. 所有异步事件处理必须串行化或按 session 排队，避免 JSONL 写入竞争导致漏报。
5. 通知失败不能反向终止 watcher。
6. 真正需要精确监控 Claude 权限请求时，应额外接入 Claude 的权限 Hook，而不是继续扩大文本匹配规则。

## 9. 推荐交付顺序

如果团队希望先交付 MVP，建议按以下顺序：

1. Claude `Stop` Hook；
2. Codex sessions JSONL 的 `task_complete`；
3. Codex `request_user_input`；
4. Codex TUI 失败检测；
5. 统一去重和通知引擎；
6. Claude Watch；
7. Codex SQLite、旧格式 fallback 和多 Agent 协调。

前五项完成后，已经可以覆盖大多数正常 CLI 场景；后续项目主要用于提高兼容性和降低误报、漏报。

## 10. 本项目源码参考入口

团队复刻时可以重点对照：

```text
src/hooks.js                 Claude Hook 安装、卸载、状态检查
src/hooks-stdin.js           Hook stdin JSON 读取
src/hook-context.js          Claude 最终回复和失败解析
src/watch.js                 Claude/Codex Watch、状态机、SQLite、TUI 失败
src/engine.js                去重、阈值、通知分发
src/cli.js                   watch/notify/run 命令入口
tests/claude-sdk-session-filter.test.js
tests/watch-codex-multi-session.test.js
tests/watch-codex-tui-failure.test.js
```
