"""
Kết nối Redis dùng chung cho rate limiter và cost guard.

  • Đọc REDIS_URL từ config.
  • redis.from_url() KHÔNG mở kết nối ngay: kết nối chỉ được tạo ở lệnh đầu tiên,
    nên app vẫn khởi động được (và /health vẫn 200) khi Redis chưa sẵn sàng.
  • Timeout ngắn để /ready trả 503 nhanh thay vì treo khi Redis không tới được.
"""
import redis

from app.config import settings

r = redis.from_url(
    settings.redis_url,
    decode_responses=True,
    socket_connect_timeout=2,
    socket_timeout=2,
    health_check_interval=30,
)


def redis_healthy() -> bool:
    """Dùng cho GET /ready: ping được Redis → True, lỗi kết nối → False."""
    try:
        return bool(r.ping())
    except redis.RedisError:
        return False


def close_redis() -> None:
    """Đóng connection pool khi app tắt (graceful shutdown)."""
    try:
        r.close()
    except redis.RedisError:
        pass
