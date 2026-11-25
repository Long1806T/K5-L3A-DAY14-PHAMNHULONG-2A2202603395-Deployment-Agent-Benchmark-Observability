"""
Config — 12-Factor: mọi cấu hình đọc từ biến môi trường (tiêu chí 9).

  • Không hard-code secret: AGENT_API_KEY mặc định là chuỗi rỗng, khi đó mọi
    request /ask đều bị 401 (fail closed) thay vì mở cửa cho tất cả.
  • Giá trị mặc định chỉ để chạy local; trên cloud đặt bằng biến môi trường
    của nền tảng (Railway Variables / Render Environment).
  • Danh sách đầy đủ các biến nằm trong .env.example.
"""
import os
from dataclasses import dataclass, field


def _env_str(name: str, default: str) -> str:
    value = os.getenv(name)
    return default if value is None or value.strip() == "" else value.strip()


def _env_int(name: str, default: int) -> int:
    return int(_env_str(name, str(default)))


def _env_float(name: str, default: float) -> float:
    return float(_env_str(name, str(default)))


@dataclass(frozen=True)
class Settings:
    port: int = field(default_factory=lambda: _env_int("PORT", 8000))
    environment: str = field(default_factory=lambda: _env_str("ENVIRONMENT", "development"))
    log_level: str = field(default_factory=lambda: _env_str("LOG_LEVEL", "INFO").upper())

    # Secret — chỉ đọc từ môi trường, không có giá trị mặc định thật
    agent_api_key: str = field(default_factory=lambda: os.getenv("AGENT_API_KEY", ""))

    redis_url: str = field(default_factory=lambda: _env_str("REDIS_URL", "redis://localhost:6379/0"))

    # Giới hạn
    rate_limit_per_minute: int = field(default_factory=lambda: _env_int("RATE_LIMIT_PER_MINUTE", 10))
    daily_budget_usd: float = field(default_factory=lambda: _env_float("DAILY_BUDGET_USD", 1.0))
    monthly_budget_usd: float = field(default_factory=lambda: _env_float("MONTHLY_BUDGET_USD", 10.0))


settings = Settings()
