"""
API Key authentication (tiêu chí 6).

  • Client gửi header  X-API-Key: <key>
  • Key phải trùng biến môi trường AGENT_API_KEY
  • Thiếu hoặc sai key → HTTP 401 (không phải 403 hay 422)
"""
import hmac

from fastapi import HTTPException, Security
from fastapi.security.api_key import APIKeyHeader

from app.config import settings

# auto_error=False: thiếu header thì FastAPI trả None cho mình tự xử lý → 401.
# (Nếu để FastAPI tự báo lỗi thì thiếu header sẽ ra 403/422, không đúng hợp đồng.)
api_key_header = APIKeyHeader(name="X-API-Key", auto_error=False)


def verify_api_key(api_key: str | None = Security(api_key_header)) -> str:
    """Dependency cho FastAPI — dùng trong /ask: Depends(verify_api_key)."""
    expected = settings.agent_api_key
    # compare_digest: so sánh thời gian hằng, tránh dò key bằng timing attack.
    # Chưa cấu hình AGENT_API_KEY thì từ chối tất cả (fail closed).
    if not expected or not api_key or not hmac.compare_digest(api_key.encode(), expected.encode()):
        raise HTTPException(
            status_code=401,
            detail="Invalid or missing API key. Send header: X-API-Key: <key>",
            headers={"WWW-Authenticate": "ApiKey"},
        )
    return api_key
