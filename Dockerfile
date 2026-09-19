# MoodCode 容器镜像
#
# 存在的理由：mood-core 在 Windows 原生跑不起来——core/app.py 无条件调用
# asyncio.add_signal_handler()，该方法仅 Unix 实现。容器提供 Linux 运行时，
# 绕开这一限制，同时给 CI 一个能跑集成测试的环境。

FROM ghcr.io/astral-sh/uv:python3.12-bookworm-slim AS base

# 虚拟环境放进项目目录，便于整目录管理
ENV UV_PROJECT_ENVIRONMENT=/app/.venv \
    UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    PYTHONUNBUFFERED=1

WORKDIR /app

# 先只解析依赖。pyproject.toml 不变时这一层始终命中缓存。
#
# 注意：本仓库刻意不提交 uv.lock（见 .gitignore），所以这里是全新解析，
# 依赖版本不跨构建固定。若要可复现构建，把 uv.lock 纳入版本控制后改成：
#     COPY pyproject.toml uv.lock ./
#     RUN uv sync --no-dev --no-install-project --frozen
COPY pyproject.toml ./
RUN uv sync --no-dev --no-install-project

# 再装项目本体
COPY . .
RUN uv sync --no-dev

ENV PATH="/app/.venv/bin:$PATH"


# ── 测试镜像 ─────────────────────────────────────────────────
# 额外装 ruff / mypy / pytest。用途是在 Linux 上跑 tests/integration——
# 这批用例在 Windows 上因 add_signal_handler 无法运行。
#     docker build --target test -t moodcode-core:test .
#     docker run --rm moodcode-core:test
FROM base AS test
RUN uv sync
CMD ["pytest", "tests/", "-v"]


# ── 运行时镜像（最后一个 stage = `docker build .` 的默认目标）──
FROM base AS runtime

# 容器内必须绑 0.0.0.0。默认的 127.0.0.1 绑在容器自己的 loopback 上，
# docker 的端口映射（DNAT 到容器 eth0）永远到不了——表现为端口开着但连不上。
# 宿主机侧务必用 -p 127.0.0.1:7437:7437 只绑回环：协议层没有鉴权，
# 任何能连上端口的进程都能直接调 agent.run。
ENV MOOD_HOST=0.0.0.0 \
    MOOD_PORT=7437

EXPOSE 7437

# exec 形式：Python 直接作为 PID 1 接收 docker stop 的 SIGTERM，
# 走完 app.py 的优雅关停（取消在跑的 run → 停 MCP → 停 server → 停 trace）。
# 若写成 `uv run mood-core`，PID 1 会变成 uv，信号能否转发取决于 uv 的行为。
CMD ["mood-core"]
