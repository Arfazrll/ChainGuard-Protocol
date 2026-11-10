# syntax=docker/dockerfile:1
# A ChainGuard Python service (uv, locked dependencies). Built from the repository root:
#   docker build -f deploy/docker/python-service.Dockerfile --build-arg SERVICE=anomaly .
#   docker build -f deploy/docker/python-service.Dockerfile --build-arg SERVICE=report .
FROM ghcr.io/astral-sh/uv:python3.12-bookworm-slim
ARG SERVICE
ENV UV_COMPILE_BYTECODE=1 UV_LINK_MODE=copy UV_PYTHON_DOWNLOADS=never
WORKDIR /app
COPY services/${SERVICE}/pyproject.toml services/${SERVICE}/uv.lock services/${SERVICE}/README.md ./
RUN uv sync --locked --no-dev --no-install-project
COPY services/${SERVICE}/src ./src
RUN uv sync --locked --no-dev \
 && useradd --system --uid 10001 --home /app chainguard
USER chainguard
ENV PATH="/app/.venv/bin:$PATH"
