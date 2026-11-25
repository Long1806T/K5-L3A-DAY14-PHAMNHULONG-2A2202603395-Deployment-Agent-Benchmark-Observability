# ============================================================
# Production Dockerfile — Part 6 (tiêu chí 1)
#   • Multi-stage: builder cài dependencies vào virtualenv,
#     runtime chỉ copy virtualenv + source code → image nhỏ, không có pip cache
#   • Base python:3.11-slim, chạy bằng user non-root
#   • HEALTHCHECK gọi GET /health
#   • CMD nghe theo biến PORT (mặc định 8000), `exec` để uvicorn là PID 1
#     → nhận được SIGTERM khi `docker stop` và tắt êm (exit code 0)
#
# Build & run (trong thư mục 06-lab-complete/):
#   docker build -t day14-agent .
#   docker run -p 8000:8000 -e AGENT_API_KEY=dev-key day14-agent
# ============================================================

# ── Stage 1: builder ─────────────────────────────────────────
FROM python:3.11-slim AS builder

ENV PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

WORKDIR /build
# Copy requirements trước source code: code đổi thì layer cài thư viện vẫn dùng cache
COPY requirements.txt .
RUN pip install -r requirements.txt


# ── Stage 2: runtime ─────────────────────────────────────────
FROM python:3.11-slim AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/opt/venv/bin:$PATH" \
    PORT=8000

# User hệ thống, không có shell đăng nhập, không có quyền root
RUN groupadd --system agent \
    && useradd --system --gid agent --no-create-home --shell /usr/sbin/nologin agent

WORKDIR /app
COPY --from=builder /opt/venv /opt/venv
# Code thuộc root (chỉ đọc với user agent) → process bị chiếm quyền cũng không sửa được code
COPY app/ ./app/
COPY utils/ ./utils/

USER agent

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD ["python", "-c", "import os, urllib.request; urllib.request.urlopen('http://127.0.0.1:' + os.environ.get('PORT', '8000') + '/health', timeout=3)"]

CMD ["sh", "-c", "exec uvicorn app.main:app --host 0.0.0.0 --port ${PORT:-8000} --workers 2"]
