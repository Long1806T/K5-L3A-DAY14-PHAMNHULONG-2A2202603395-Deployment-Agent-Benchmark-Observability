"""
Rate limiting (tiêu chí 7).

  • Mỗi API key tối đa RATE_LIMIT_PER_MINUTE request trong 60 giây (sliding window)
  • Vượt giới hạn → HTTP 429, kèm header Retry-After
  • State lưu trong Redis (sorted set) nên mọi worker / instance dùng chung,
    và vẫn còn sau khi restart agent.

Cách làm: mỗi request là 1 phần tử trong sorted set, score = timestamp.
  ZREMRANGEBYSCORE  xoá các request cũ hơn 60 giây
  ZADD              thêm request hiện tại
  ZCARD             đếm số request còn trong cửa sổ
  EXPIRE            để key tự xoá khi không còn dùng
Bốn lệnh chạy trong MULTI/EXEC nên 2 worker gọi cùng lúc cũng không đếm sai.
"""
import hashlib
import time
import uuid

from fastapi import HTTPException

from app.config import settings
from app.redis_client import r

WINDOW_SECONDS = 60


def _bucket(api_key: str) -> str:
    # Không lưu API key thật trong Redis, chỉ lưu dấu SHA-256 của nó.
    return "ratelimit:" + hashlib.sha256(api_key.encode()).hexdigest()[:16]


def check_rate_limit(key: str) -> None:
    limit = settings.rate_limit_per_minute
    now = time.time()
    bucket = _bucket(key)
    member = f"{now:.6f}-{uuid.uuid4().hex[:8]}"

    pipe = r.pipeline(transaction=True)
    pipe.zremrangebyscore(bucket, 0, now - WINDOW_SECONDS)
    pipe.zadd(bucket, {member: now})
    pipe.zcard(bucket)
    pipe.expire(bucket, WINDOW_SECONDS + 1)
    _, _, count, _ = pipe.execute()

    if count > limit:
        # Request bị từ chối không được tính vào cửa sổ.
        r.zrem(bucket, member)
        oldest = r.zrange(bucket, 0, 0, withscores=True)
        retry_after = WINDOW_SECONDS
        if oldest:
            retry_after = max(1, int(oldest[0][1] + WINDOW_SECONDS - now) + 1)
        raise HTTPException(
            status_code=429,
            detail=f"Rate limit exceeded: {limit} requests per {WINDOW_SECONDS} seconds",
            headers={"Retry-After": str(retry_after)},
        )
