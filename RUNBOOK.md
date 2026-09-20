# 运维手册（RUNBOOK）

## 一、两种运行方式

| 方式 | Linux | macOS | Windows | 适用 |
|---|---|---|---|---|
| **容器** | ✅ | ✅ | ✅ | 推荐；跨平台一致，集成测试可跑 |
| 本地原生 | ✅ | ✅ | ❌ | 需要改代码或调试时 |

**Windows 上守护进程无法本地启动。** `core/app.py` 无条件调用 `asyncio.add_signal_handler()`，该方法仅 Unix 实现，抛 `NotImplementedError`。实测：配置、日志、权限、会话存储、provider、socket server **全部正常**，端口也已成功监听，仅在最后一步的信号处理崩溃。容器提供 Linux 运行时绕开此限制。

---

## 二、容器方式（推荐）

### 首次准备

```bash
cp .env.example .env
# 编辑 .env，至少填入真实可用的 ANTHROPIC_API_KEY
```

### 启动 / 验证 / 停止

```bash
docker compose up -d                    # 构建并启动
docker compose ps                       # 应显示 Up (healthy)
uv run mood ping                        # 从宿主机验证 → pong server=0.0.1 uptime=... latency=...
docker compose logs -f mood-core        # 跟踪日志
docker compose stop                     # 优雅关停
docker compose down                     # 停止并删除容器（保留数据卷）
docker compose down -v                  # 连数据卷一起删除（会丢会话/trace/权限策略）
```

### 端口与网络

容器内绑 `0.0.0.0:7437`，宿主机映射为 `127.0.0.1:7437`。

**这两个设置都是必需的，且不能随意改动：**

- 容器内若绑 `127.0.0.1`，docker 的端口映射（DNAT 到容器 eth0）**永远到不了**——表现为端口开着但连不上
- 宿主机侧必须绑回环。**协议层没有鉴权**，任何能连上 7437 的进程都能直接调 `agent.run`；写成 `7437:7437` 等于把无认证的 agent 执行入口暴露给整个局域网

### 数据持久化

容器内 `~/.mood` 挂载到命名卷 `moodcode_mood-data`（即 `/root/.mood`）。会话、trace、日志、权限策略都在这里，`docker compose down` 不会删除它。

### 在容器里跑测试

```bash
docker build --target test -t moodcode-core:test .

# 单元测试
docker run --rm moodcode-core:test pytest tests/unit -q

# 集成测试——这批用例在 Windows 上无法运行
# 需起 daemon 的用例：provider 在 server.start() 前构造，空 key 会 SystemExit
docker run --rm -e ANTHROPIC_API_KEY=ci-placeholder moodcode-core:test \
  pytest tests/integration --ignore=tests/integration/test_run_e2e.py -v

# 需要真实 key 的端到端用例；key 置空则自行跳过
docker run --rm -e ANTHROPIC_API_KEY= moodcode-core:test \
  pytest tests/integration/test_run_e2e.py -v
```

> ⚠️ **这两批用例对 `ANTHROPIC_API_KEY` 的要求互斥，必须分开跑。**
>
> - **需起 daemon 的用例**（`test_ping_roundtrip` / `test_s2_dual_process` / `test_s4_session_ipc`）要求 key **非空**：守护进程在 `server.start()` **之前**就构造 `AnthropicProvider`，缺 key 直接 `SystemExit`——即使测试本身只是 `core.ping`、完全不碰 LLM。key 为空时的报错是 `Daemon did not start within 3 seconds`，而 stderr 里真正的原因是 `ANTHROPIC_API_KEY not set`。
> - **`test_run_e2e.py`** 的跳过条件是 key **为空**。给它占位值不会跳过，而是拿假 key 去打真实 API 并以 `401` 失败。
>
> 因此**不存在**一个能同时跑通两者的环境变量取值。`.github/workflows/ci.yml` 也是按这个前提分成两步的。

---

## 三、本地原生方式（Linux / macOS）

```bash
uv sync                                 # 安装依赖
uv run mood-core                        # 前台启动，Ctrl+C 优雅退出
MOOD_PORT=8000 uv run mood-core         # 覆盖端口
uv run mood ping                        # 另开终端验证
```

后台运行与停止：

```bash
uv run mood core start                  # 启动为后台进程，PID 写入 ~/.mood/mood-core.pid
uv run mood core status                 # 查看状态
uv run mood core stop                   # 发送 SIGTERM 优雅停止
```

> **Windows 上不要用 `mood core stop`**。`os.kill(pid, SIGTERM)` 在 Windows 上走 `TerminateProcess`，是**硬杀**——已实测：子进程注册的 SIGTERM 处理器根本不会执行。后果是 `app.py` 的优雅关停路径（取消在跑的 run → 停 MCP → 停 server → 停 trace）整段被跳过，trace 文件可能没 flush。
>
> 也不要用 `kill $(pgrep -f mood-core)`（Unix-only）。Windows 上用 `taskkill /PID <pid>`，或直接用容器。

---

## 四、配置

### 优先级（低 → 高）

**内建默认值 → `~/.mood/config.toml` → `.mood/config.toml`（项目级，相对当前工作目录）→ `.env` → 系统环境变量**

- 设了 `MOOD_CONFIG` 则**只**读该文件，跳过另外两个 TOML
- `.env` 在读取 `MOOD_CONFIG` **之前**加载，所以 `MOOD_CONFIG` 本身可以写在 `.env` 里
- 配置文件不存在则静默跳过
- **出现未知小节或未知键会直接退出进程**（`SystemExit`），不是警告

### `~/.mood/config.toml`

```toml
[core]
host = "127.0.0.1"          # 容器内必须改成 "0.0.0.0"
port = 7437

[logging]
level  = "INFO"              # DEBUG / INFO / WARNING / ERROR
file   = "~/.mood/logs/core.log"   # 留空则仅输出 stderr，不写文件
format = "text"              # "text" | "json"

[agent]
max_steps = 20

[llm]
default_model = "claude-sonnet-4-6"
router = "static"            # 注意：此键目前不生效，见下方「已知未接线」

[trace]
enabled = true
file = "~/.mood/traces/daemon.jsonl"
include_llm_payload = true   # false 时 LLM 记录只保留摘要

[permission]
timeout_s = 60.0             # 0 表示不超时

[compaction]
auto_threshold = 0.0         # 0 = 关闭自动压缩；取值 0~1
tool_result_limit = 8000     # 注意：此键目前不生效，见下方「已知未接线」
tool_result_keep = 4000      # 同上

# [[mcp.servers]]             # MCP 服务器，stdio 或 tcp
# name = "example"
# transport = "stdio"
# command = "npx"
# args = ["-y", "@example/mcp-server"]
```

### 环境变量全表

| 变量 | 默认值 | 说明 |
|---|---|---|
| `MOOD_CONFIG` | `~/.mood/config.toml` | 覆盖配置文件路径；设置后只读该文件 |
| `MOOD_HOST` | `127.0.0.1` | 监听地址（容器内需为 `0.0.0.0`） |
| `MOOD_PORT` | `7437` | 监听端口（必须为整数） |
| `MOOD_LOG_LEVEL` | `INFO` | 日志级别 |
| `MOOD_LOG_FILE` | `~/.mood/logs/core.log` | 日志文件；空字符串则仅 stderr |
| `MOOD_LOG_FORMAT` | `text` | `text` \| `json` |
| `MOOD_MAX_STEPS` | `20` | agent 单次运行最大步数（正整数） |
| `MOOD_LLM_DEFAULT_MODEL` | `claude-sonnet-4-6` | 默认模型 |
| `MOOD_TRACE_ENABLED` | `true` | 关闭写 `0`/`false`/`no` |
| `MOOD_TRACE_FILE` | `~/.mood/traces/daemon.jsonl` | trace 文件路径 |
| `MOOD_TRACE_INCLUDE_LLM_PAYLOAD` | `true` | 是否记录完整 LLM 载荷 |
| `MOOD_PERMISSION_TIMEOUT_S` | `60.0` | 权限询问超时秒数（≥ 0） |
| `MOOD_COMPACT_THRESHOLD` | `0.0` | 自动压缩阈值（0~1） |
| `MOOD_COMPACT_TOOL_LIMIT` | `8000` | *目前不生效* |
| `MOOD_COMPACT_TOOL_KEEP` | `4000` | *目前不生效* |
| `MOOD_TUI_LOG_FILE` | `~/.mood/logs/tui.log` | TUI 日志路径 |
| `ANTHROPIC_API_KEY` | 无 | **必填**，缺失则守护进程启动失败 |

### 已知未接线

以下配置项**存在但代码从不消费**，改了不会有任何效果：

| 项 | 实际行为 |
|---|---|
| `llm.router` | 只赋值从不读；provider 恒发 `strategy="static"` |
| `compaction.tool_result_limit` / `tool_result_keep` | 被解析，但 `session/store.py` 实际调用的是 `compact/budget.py` 里的模块常量 8000/4000 |
| agent profile 的 `model` 字段 | 被解析，但子 agent 实际继承父 provider 的模型 |

---

## 五、状态目录

**`~/.mood/`（容器内为 `/root/.mood`）**

| 路径 | 内容 | 何时产生 |
|---|---|---|
| `config.toml` | 全局配置 | 可选，缺失静默跳过 |
| `context.md` | 全局 agent 记忆 | 只读 |
| `policy.toml` | 权限持久化（仅 `[always]` 表） | 选择 always_allow/deny 时写入 |
| `sessions/` | 会话存储：`meta.json`、`thread.jsonl`、`notes.md`、`runs/<run_id>/events.jsonl` | **启动即创建** |
| `traces/daemon.jsonl` | trace 记录 | `trace.enabled` 为真时 |
| `logs/core.log` | 滚动日志（10 MB × 5） | `logging.file` 非空时 |
| `mood-core.pid` | 后台进程 PID | `mood core start` |
| `skills/` | 用户级技能 | 只读 |
| `agents/` | 用户级 agent profile | 只读 |

**项目级 `.mood/`**（相对当前工作目录）：`context.md`、`config.toml`、`skills/`、`agents/`

**无会话的运行**：写在仓库根的 `runs/` 目录，结构为 `runs/<run_id>/events.jsonl`

---

## 六、日志与追踪

```bash
tail -f ~/.mood/logs/core.log                     # 守护进程日志
tail -f ~/.mood/logs/tui.log                      # TUI 日志

uv run mood trace                                 # 读 trace
uv run mood trace --follow                        # 实时跟踪
uv run mood trace --layer llm                     # 只看 LLM 层（ipc / event / llm）
uv run mood trace --direction CORE→LLM            # 按方向过滤
uv run mood trace --raw                           # 不染色
```

方向取值：`CLIENT→CORE`、`CORE→CLIENT`、`CORE`、`CORE→LLM`、`LLM→CORE`。

> Windows 提示：`--direction` 的值里含 `→` 字符，Windows 控制台对它有编码问题（`mood trace --help` 的帮助文本里该字符就会显示成乱码）。在 Windows 上过滤方向建议改用 `--layer`，或先 `--raw` 输出再自行 grep。

容器方式：

```bash
docker compose logs -f mood-core
docker compose exec mood-core mood trace --follow
```

---

## 七、常用命令

```bash
uv run mood ping                    # 连通性检查
uv run mood chat                    # 多轮对话 REPL
uv run mood run --goal "..."        # 一次性执行
uv run mood --version
```

---

## 八、常见错误

| 报错 | 原因 | 处理 |
|---|---|---|
| `ANTHROPIC_API_KEY not set` | 缺 API key | 在 `.env` 或环境变量中设置。**即使只跑 ping 也需要** |
| `Daemon did not start within 3 seconds` | 集成测试中守护进程启动失败 | 查 stderr；最常见是上一条缺 key |
| `core already running at host:port` | 已有守护进程在监听 | 先 `mood core status` 确认；本地用 `mood core stop`，容器用 `docker compose stop` |
| `core not running` | 未启动守护进程 | `uv run mood-core` 或 `docker compose up -d` |
| `Address already in use` | 端口被其他进程占用 | `MOOD_PORT=8000 uv run mood-core`，或改 compose 的端口映射 |
| `Config error: ... must be an integer` | 环境变量或 TOML 值类型不对 | 按上表核对取值格式 |
| `Unknown top-level config keys: ...` | TOML 里有拼错的小节名 | 小节只允许：`core`、`logging`、`agent`、`llm`、`trace`、`permission`、`compaction`、`mcp` |
| `NotImplementedError` | Windows 上本地启动守护进程 | 用容器方式，或参考 `core/app.py` 的信号处理 |

---

## 九、开发

```bash
uv sync
uv run ruff check src tests scripts
uv run mypy src
uv run pytest tests/unit -v
```

仓库根的 `Makefile` 提供 `lint` / `test` / `integration-test` / `docs` / `verify` 目标。注意 `make` 在部分 Windows 环境的 Git Bash 中不可用，此时手动执行上述命令。

代码风格、架构、子系统地图等开发向说明见 `AGENTS.md`。
