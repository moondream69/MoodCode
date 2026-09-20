# AGENTS.md

This file provides guidance to AI coding agents (Claude Code, Codex, and others) when working with code in this repository.

## Commands

```bash
uv sync                                     # 安装 / 同步依赖（含 dev 组）

uv run ruff check src tests scripts         # lint
uv run mypy src                             # 类型检查（strict）

uv run pytest tests/unit -v                 # 单元测试（40 文件，无需 daemon）
uv run pytest tests/integration -v          # 集成测试（5 文件，形态不一，见下）
uv run pytest tests/unit/test_envelope.py::test_request_roundtrip -v   # 单个测试

uv run python scripts/gen_protocol_doc.py           # 重新生成 WIRE_PROTOCOL.md
uv run python scripts/gen_protocol_doc.py --check   # 校验是否同源

uv run mood-core                            # 前台启动守护进程，Ctrl+C 退出
MOOD_PORT=8000 uv run mood-core             # 覆盖端口
uv run mood ping                            # 连通性检查
```

`Makefile` 提供 `lint` / `test` / `integration-test` / `docs` / `verify` 目标，内容同上。`verify` 是提交前的完整门禁（依赖 → lint + 类型 → 单元测试 → 冒烟连通 → 协议文档同源）。

三个 console script：`mood`（CLI）、`mood-core`（守护进程）、`mood-tui`（TUI）。

**⚠️ Windows 上 `mood-core` 无法启动。** `core/app.py` 无条件调用 `asyncio.add_signal_handler()`，该方法仅 Unix 实现，Windows 上抛 `NotImplementedError`。受影响的还有所有依赖 `running_daemon` fixture 的集成测试。`tests/unit` 不受影响。

## Architecture

**双进程**本地 agent 系统。`mood-core` 是常驻守护进程，`mood` / `mood-tui` 是客户端。

```
mood-core (daemon)
  └─ TCP 127.0.0.1:7437，JSON-RPC 2.0 over NDJSON
       ↑
mood (CLI)          mood-tui (TUI)
```

传输层是 **TCP，不是 Unix domain socket**（历史文档曾误写，以 `transport/socket_server.py` 的 `asyncio.start_server` 为准）。

**`mood-tui` 是主前端。** 所有面向用户的功能——任务管理、可观测性、交互——都必须先在 TUI 中设计和验证。`mood` CLI 只用于快速脚本化测试和调试，**不是产品界面**。实现涉及 UI 的功能时，要在 TUI 布局、事件渲染、键盘交互上投入；不要用"CLI 也能做"来绕过 TUI 工作。

### 协议层（`src/mood_code/core/bus/`）

所有 IPC 消息都是带 `type` 判别字段的 pydantic v2 模型，`Command` / `Event` 两个 union 就是契约边界。**新增命令或事件 = 新增一个模型类 + 扩展对应 union。**

已注册的 9 个 RPC 方法（`core/app.py`）：`core.ping`、`agent.run`、`event.subscribe`、`session.create`、`session.send_message`、`session.get_history`、`session.close`、`permission.respond`、`session.compact`。

`events.py` 定义 24 种事件：`core.started`、`run.started/finished`、`step.started/finished`、`tool.call_started/finished/failed`、`llm.token/usage/model_selected`、`log.line`、`session.created/message_received/waiting_for_input/resumed/closed`、`context.compacted`、`permission.requested/granted/denied`、`subagent.started/finished`、`skill.invoked`。

`WIRE_PROTOCOL.md` 由 `scripts/gen_protocol_doc.py` **生成**，改完 bus 模型后必须重新生成并提交。

### 守护进程启动管线（`core/app.py`）

`CoreApp.run()` 是唯一异步入口，顺序为：加载配置 → 日志 → `TraceWriter` 并订阅到 bus → `PermissionManager`（读 `~/.mood/policy.toml`）→ `IpcEventBroadcaster` → 建 `~/.mood/sessions` 与 `SessionStore` → 为手动压缩单独构造一个 `AnthropicProvider` → 启动 MCP servers → 构建 `SessionManager`（持有 runner 工厂）→ `SocketServer` 注册 9 个 handler → 等待 SIGINT/SIGTERM → 取消在跑的 run → 停 MCP → 停 server → 停 trace。

新增 handler：在 `CoreApp` 上写一个方法，再 `server.register("method.name", handler)`。

## Subsystem map

| 子系统 | 代码位置 | 配置 | 磁盘路径 / 搜索顺序 |
|---|---|---|---|
| Skills | `core/skills/loader.py` | 无配置键 | `.mood/skills/<n>.md` 或 `<n>/SKILL.md` → `~/.mood/skills/` → 内建 `core/skills/builtin/`（init / orchestrate / review / summarize） |
| Memory | `core/memory/loader.py` | 无 | `~/.mood/context.md`、`.mood/context.md`；会话笔记 `~/.mood/sessions/<sid>/notes.md` |
| Agent profiles | `core/agents/loader.py` | 无 | `.mood/agents/<n>.toml` → `~/.mood/agents/` → 内建 `core/agents/builtin/`（planner / executor / reviewer） |
| MCP | `core/mcp/{client,server,tool}.py` | `[mcp.servers]` | 无文件；stdio 子进程或 TCP 连接；工具名格式 `服务器名__工具名` |
| Permissions | `core/permissions/` | `permission.timeout_s` | `~/.mood/policy.toml`（仅 `[always]` 表，在用户选 always_allow/deny 时写入） |
| Compaction | `core/compact/compactor.py` | `compaction.auto_threshold`（默认 0 = 关闭） | 摘要写 `~/.mood/sessions/<sid>/summary_<ts>.md`；手动压缩会重写 `thread.jsonl` 并备份为 `thread_<ts>.jsonl.bak` |
| Budget | `core/compact/budget.py` | 无（模块常量 8000/4000） | 纯内存 |
| Sessions | `core/session/` | 无 | `~/.mood/sessions/<sid>/`：`meta.json`、`thread.jsonl`、`notes.md`、`runs/<run_id>/events.jsonl` |
| Tasks | `core/task/` | 无 | `<run_path>/.tasks/task_<N>.json` |
| Sub-agents | `core/subagent/` | 继承 `agent.max_steps` | 子 run 落在父 runs 目录下；嵌套深度上限 2 |
| Trace | `core/trace/` | `trace.enabled/file/include_llm_payload` | `~/.mood/traces/daemon.jsonl`（异步队列 → 追加式 JSONL） |

无会话的 run 写在仓库根的 `runs/` 目录。守护进程 PID 文件在 `~/.mood/mood-core.pid`。

## Tool system

工具继承 `core/tools/base.py` 的 `BaseTool`，需要 `name`、`description`、`input_schema`、`params_model`、`async invoke()`。

**关键约定——双声明**：每个工具同时声明
1. `params_model`：pydantic 模型，**只用于校验**（`tools/invocation.py`）；校验失败发 `tool.call_failed`，`error_class="schema_error"`
2. `input_schema`：手写的 JSON Schema 字典，这份才是发给模型的

MCP 工具是唯一例外（`params_model = None`，schema 来自 MCP server）。

9 个内建工具：`read_file`、`bash`、`write_file`、`list_dir`、`task_create`、`task_update`、`task_list`、`task_get`、`note_save`。运行时追加的还有 `spawn_agent`、`agent_result` 和 MCP 工具。

调用管线（`core/tools/invocation.py`）：发 `tool.call_started` → 未知工具检查 → 参数校验 → **权限检查**（`PermissionManager.check_and_wait`）→ `asyncio.wait_for(..., timeout=120s)` → 失败时对 `runtime_error` / `rate_limited` 重试至多 2 次（退避 2s / 4s）。

Skill 和 agent profile 都能通过 `allowed_tools` 按名字过滤注册到 registry 的工具。

## Config

优先级（低 → 高）：**内建默认 → `~/.mood/config.toml` → `.mood/config.toml`（项目级，相对 CWD）→ `.env` → 环境变量**。

- 设了 `MOOD_CONFIG` 则**只**读该文件，跳过其余 TOML
- `.env` 在读取 `MOOD_CONFIG` **之前**加载，所以 `MOOD_CONFIG` 本身可以写在 `.env` 里
- 配置文件不存在则静默跳过；**出现未知小节或未知键会 `SystemExit` 硬退出**——加新键时必须同步改 `config.py` 的校验白名单
- 配置项与全部 `MOOD_*` 环境变量的权威清单见 `core/config.py`（8 个小节、15 个键、17 个环境变量），不要照抄别处

## Code style

**函数注释**：`def` 正上方一行中文注释说明该函数做什么，不写多行 docstring。

```python
# 发送 JSON-RPC 响应并刷新写缓冲区
async def _send(self, writer: asyncio.StreamWriter, msg: BaseModel) -> None:
```

实测覆盖率 `src/` 为 252/298（84.6%）。已知的系统性例外：`__init__` 方法、嵌套闭包、Textual 生命周期方法（`compose` / `on_mount`）、以及 `_now()` 一类自解释的小助手。新写的普通函数应当遵守。

**测试注释**：每个测试函数上方**必须**有两行中文注释，缺一不可。实测 268/268 全部遵守——这是硬规则。

```python
# 功能：验证 publish 后订阅者能收到事件对象
# 设计：用内联 handler 收集事件引用，断言 is 而非 ==，排除序列化中间步骤的干扰
async def test_publish_reaches_subscriber() -> None:
```

- `# 功能：` — 该测试验证的具体行为或不变式，说清"测什么"
- `# 设计：` — 为什么这样测：覆盖了什么边界、为什么用这个 stub/fixture、这种断言相比其他方式的优势

## Known-unwired

以下配置项 / 模型**存在但代码从不消费**。看到它们不要以为功能已生效：

| 项 | 实际行为 |
|---|---|
| `llm.router` | 只赋值从不读；provider 恒发 `strategy="static"` |
| `compaction.tool_result_limit` / `tool_result_keep` | 被解析，但 `session/store.py` 调用的是 `compact/budget.py` 里的模块常量 8000/4000 |
| agent profile 的 `model` 字段 | 被解析，但子 agent 实际继承父 provider 的模型 |
| `CoreStartedEvent`、`LogLineEvent` | 已定义，全仓库从不发布 |
| `PermissionDeniedError` | 已定义，从不 raise |

**`scripts/gen_protocol_doc.py` 已落后于 `bus/`**：它没有导入 `PermissionRespondCommand/Result`、`SessionCompactCommand/Result`，以及 `ContextCompacted`、`Permission*`、`Subagent*`、`SkillInvoked` 事件。因此当前 `WIRE_PROTOCOL.md` 只覆盖 18 个命令模型中的 14 个、24 个事件模型中的 17 个。改 bus 模型时请注意这个生成器需要同步补齐。

## Testing

`tests/unit/`（40 文件）与 `tests/integration/`（5 文件），共 268 个测试函数。

`tests/conftest.py` 提供两个 fixture：`free_port`（绑 0 号端口取号后释放）和 `running_daemon`（以 `MOOD_PORT=<free_port>` 启动真实的 `python -m mood_code.core` 子进程，轮询 `asyncio.open_connection` 直至就绪，结束时 terminate + 2s 宽限再 kill）。注意该 fixture **不重定向** `MOOD_TRACE_FILE` 和会话根目录，所以跑通会往 `~/.mood/` 写真实状态。

集成测试有**三种形态**，不要一概而论：

1. **真子进程 daemon** — `test_ping_roundtrip.py`、`test_s2_dual_process.py`、`test_s4_session_ipc.py`（用 `running_daemon`）
2. **进程内** — `test_s5_permission_flow.py`：直接构造 `AgentRunner` + 真 `PermissionManager` + mock provider，跑真 `bash` 子进程，不启 daemon
3. **调真实 Anthropic API** — `test_run_e2e.py`：标记 `integration`，无 `ANTHROPIC_API_KEY` 时自我跳过

形态 1 在 Windows 上不可运行（见上文 `add_signal_handler`），形态 2、3 与 `tests/unit` 不受影响。

`ruff` 对 `tests/**` 和 `scripts/**` 放宽了 `E501`，因为中文注释容易超行宽。

## Agent skills

### Issue tracker

Issues live in this repo's GitHub Issues, operated via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Five canonical triage roles, each label string equal to its role name. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `CONTEXT.md` at the repo root plus `docs/adr/`. See `docs/agents/domain.md`.
