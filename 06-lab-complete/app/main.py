"""
Production AI Agent — Part 6 Final Project.

Chạy local (cần Redis cho rate limit / cost guard):
    AGENT_API_KEY=dev-key uvicorn app.main:app --reload

Kiểm tra 12 tiêu chí:
    python check_production_ready.py
"""
import json
import logging
import sys
import time
import uuid
from contextlib import asynccontextmanager
from datetime import datetime, timezone

from fastapi import Depends, FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict, Field
from redis.exceptions import RedisError

from app.auth import verify_api_key
from app.config import settings
from app.cost_guard import check_budget, estimate_tokens, record_cost
from app.rate_limiter import check_rate_limit
from app.redis_client import close_redis, redis_healthy
from utils.mock_llm import ask as llm_ask

APP_VERSION = "1.0.0"
START_TIME = time.monotonic()


# ─────────────────────────────────────────────────────────
# Structured logging (tiêu chí 10): mỗi dòng log là 1 JSON object
# ─────────────────────────────────────────────────────────
_RESERVED_ATTRS = set(vars(logging.makeLogRecord({}))) | {"message", "asctime"}


class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        entry = {
            "ts": datetime.now(timezone.utc).isoformat(timespec="milliseconds"),
            "lvl": record.levelname,
            "logger": record.name,
            "event": record.getMessage(),
        }
        # Các field truyền qua extra={...} được đưa thẳng vào JSON
        for key, value in record.__dict__.items():
            if key not in _RESERVED_ATTRS and not key.startswith("_"):
                entry[key] = value
        if record.exc_info:
            entry["exc"] = self.formatException(record.exc_info)
        return json.dumps(entry, ensure_ascii=False, default=str)


def setup_logging() -> None:
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JsonFormatter())
    logging.basicConfig(level=settings.log_level, handlers=[handler], force=True)


setup_logging()
logger = logging.getLogger("agent")


# ─────────────────────────────────────────────────────────
# Graceful shutdown (tiêu chí 11)
# Khi nhận SIGTERM, uvicorn ngừng nhận kết nối mới và chờ các request đang chạy
# xử lý xong, sau đó mới chạy phần sau `yield` rồi thoát với exit code 0.
# Không tự đăng ký signal handler để không đè mất handler của uvicorn.
# ─────────────────────────────────────────────────────────
@asynccontextmanager
async def lifespan(app: FastAPI):
    logger.info("startup", extra={
        "version": APP_VERSION,
        "environment": settings.environment,
        "redis_ok": redis_healthy(),
    })
    yield
    close_redis()
    logger.info("shutdown", extra={"uptime_s": round(time.monotonic() - START_TIME, 1)})


app = FastAPI(title="Production AI Agent", version=APP_VERSION, lifespan=lifespan)


@app.middleware("http")
async def log_requests(request: Request, call_next):
    request_id = request.headers.get("x-request-id") or uuid.uuid4().hex[:12]
    started = time.perf_counter()
    try:
        response = await call_next(request)
    except Exception:
        logger.exception("request_failed", extra={
            "method": request.method,
            "path": request.url.path,
            "request_id": request_id,
            "ms": round((time.perf_counter() - started) * 1000, 1),
        })
        raise
    response.headers["X-Request-ID"] = request_id
    logger.info("request", extra={
        "method": request.method,
        "path": request.url.path,
        "status": response.status_code,
        "ms": round((time.perf_counter() - started) * 1000, 1),
        "request_id": request_id,
    })
    return response


# ─────────────────────────────────────────────────────────
# Xử lý lỗi: trả JSON rõ ràng, không lộ stack trace cho client
# ─────────────────────────────────────────────────────────
@app.exception_handler(RedisError)
async def redis_unavailable(request: Request, exc: RedisError):
    logger.error("redis_unavailable", extra={"path": request.url.path, "error": type(exc).__name__})
    return JSONResponse(
        status_code=503,
        content={"detail": "Storage backend unavailable, please retry later."},
        headers={"Retry-After": "5"},
    )


@app.exception_handler(Exception)
async def unhandled_error(request: Request, exc: Exception):
    return JSONResponse(status_code=500, content={"detail": "Internal server error"})


# ─────────────────────────────────────────────────────────
# Endpoints
# ─────────────────────────────────────────────────────────
class AskRequest(BaseModel):
    model_config = ConfigDict(str_strip_whitespace=True)

    question: str = Field(..., min_length=1, max_length=2000)
    user_id: str | None = Field(default=None, max_length=64)


@app.get("/")
def root():
    return {
        "service": "production-ai-agent",
        "version": APP_VERSION,
        "endpoints": {"health": "GET /health", "ready": "GET /ready", "ask": "POST /ask (X-API-Key)"},
    }


@app.get("/health")
def health():
    """Liveness (tiêu chí 4): process còn sống là 200, không phụ thuộc Redis."""
    return {
        "status": "ok",
        "version": APP_VERSION,
        "environment": settings.environment,
        "uptime_s": round(time.monotonic() - START_TIME, 1),
    }


@app.get("/ready")
def ready():
    """Readiness (tiêu chí 5): chỉ nhận traffic khi Redis kết nối được, không thì 503."""
    if not redis_healthy():
        raise HTTPException(status_code=503, detail="Not ready: Redis is not reachable")
    return {"status": "ready"}


@app.post("/ask")
def ask(body: AskRequest, api_key: str = Depends(verify_api_key)):
    check_rate_limit(api_key)          # 429 khi vượt RATE_LIMIT_PER_MINUTE
    check_budget()                     # 402 khi hết budget

    started = time.perf_counter()
    answer = llm_ask(body.question)
    llm_ms = round((time.perf_counter() - started) * 1000, 1)

    input_tokens = estimate_tokens(body.question)
    output_tokens = estimate_tokens(answer)
    cost = record_cost(input_tokens, output_tokens)

    logger.info("llm_call", extra={
        "user_id": body.user_id,
        "input_tokens": input_tokens,
        "output_tokens": output_tokens,
        "cost_usd": round(cost, 8),
        "llm_ms": llm_ms,
    })
    return {
        "question": body.question,
        "answer": answer,
        "usage": {
            "input_tokens": input_tokens,
            "output_tokens": output_tokens,
            "cost_usd": round(cost, 8),
        },
    }
