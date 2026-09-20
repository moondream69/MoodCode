.PHONY: lint test integration-test docs verify

lint:
	uv run ruff check src tests scripts
	uv run mypy src

test:
	uv run pytest tests/unit -v

integration-test:
	uv run pytest tests/integration -v

docs:
	uv run python scripts/gen_protocol_doc.py

# 提交前的完整门禁：同步依赖 → lint + 类型 → 单元测试 → 冒烟连通 → 协议文档同源
verify:
	uv sync
	uv run ruff check src tests scripts
	uv run mypy src
	uv run pytest tests/unit -v
	uv run pytest tests/integration -k ping -v
	uv run python scripts/gen_protocol_doc.py --check
