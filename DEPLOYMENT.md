# Deployment Information

Agent được deploy là agent Part 6 trong thư mục `06-lab-complete/` (Dockerfile multi-stage + Redis).

## Public URL

⏳ `https://<điền-sau-khi-deploy>.up.railway.app`

## Platform

Railway (nền tảng chính). Cấu hình: [`06-lab-complete/railway.toml`](06-lab-complete/railway.toml).
Cấu hình Render tương đương: [`06-lab-complete/render.yaml`](06-lab-complete/render.yaml).

## Test Commands

Đặt `BASE` là URL public, `AGENT_API_KEY` là key đã đặt trên Railway. Mỗi lệnh chỉ in mã HTTP nên chụp màn hình không lộ key:

```bash
export BASE="https://<your-app>.up.railway.app"
export AGENT_API_KEY="<key đã đặt trên Railway>"

curl -sS -o /dev/null -w '%{http_code}\n' "$BASE/health"     # 200
curl -sS -o /dev/null -w '%{http_code}\n' "$BASE/ready"      # 200 (Redis kết nối được)
curl -sS -o /dev/null -w '%{http_code}\n' -X POST "$BASE/ask" -H 'Content-Type: application/json' -d '{"question":"Hello"}'   # 401
curl -sS -o /dev/null -w '%{http_code}\n' -X POST "$BASE/ask" -H 'Content-Type: application/json' -H "X-API-Key: $AGENT_API_KEY" -d '{"question":"Hello"}'   # 200
```

Kết quả: ⏳

```text
(chưa có)
```

### Health Check

```bash
curl "$BASE/health"
# {"status": "ok", "version": "1.0.0", "environment": "production", "uptime_s": ...}
```

### API Test (with authentication)

```bash
curl -X POST "$BASE/ask" \
  -H "X-API-Key: $AGENT_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"user_id": "test", "question": "What is deployment?"}'
```

### Kiểm tra thêm bằng script chấm

```bash
cd 06-lab-complete
python check_production_ready.py --public-url "$BASE"
```

## Environment Variables Set

Đặt trên Railway (tab **Variables** của service agent), **không** ghi trong code hay trong repo:

| Biến | Giá trị | Ghi chú |
|------|---------|---------|
| `PORT` | do Railway tự cấp | CMD trong Dockerfile nghe theo `${PORT:-8000}` |
| `REDIS_URL` | `${{Redis.REDIS_URL}}` | tham chiếu tới service Redis trong cùng project |
| `AGENT_API_KEY` | chuỗi ngẫu nhiên (secret) | tạo bằng `python -c "import secrets; print(secrets.token_urlsafe(32))"` |
| `ENVIRONMENT` | `production` | |
| `LOG_LEVEL` | `INFO` | |
| `RATE_LIMIT_PER_MINUTE` | `10` | không đặt thì mặc định 10 |
| `DAILY_BUDGET_USD` / `MONTHLY_BUDGET_USD` | `1.0` / `10.0` | không đặt thì dùng giá trị mặc định này |

## Cách deploy (Railway CLI)

```bash
npm i -g @railway/cli          # cần Node.js
railway login
cd 06-lab-complete
railway init                   # tạo project mới
railway add --database redis   # thêm service Redis
railway add --service agent    # tạo service cho agent
railway service agent          # link thư mục này với service agent (CLI hỏi thì chọn agent)
railway variable set AGENT_API_KEY=<key-ngẫu-nhiên>
railway variable set ENVIRONMENT=production
railway variable set 'REDIS_URL=${{Redis.REDIS_URL}}'
railway up                     # upload 06-lab-complete/, build bằng Dockerfile (railway.toml)
railway domain                 # tạo public URL *.up.railway.app
```

Sau khi deploy, kiểm tra `/ready` trả 200 (agent đã kết nối được Redis) rồi mới chụp ảnh.

Cú pháp CLI thay đổi theo phiên bản (bản cũ dùng `railway variables --set KEY=value`); `railway --help` để xem lệnh đúng của bản bạn cài.

Cách khác qua Dashboard: New Project → Deploy from GitHub repo → chọn repo này → Settings của service: **Root Directory** `06-lab-complete`, **Config file path** `/06-lab-complete/railway.toml` → `+ New` → Database → Redis → đặt Variables như bảng trên → Networking → Generate Domain.

## Screenshots

- [Deployment dashboard](screenshots/dashboard.png) ⏳
- [Service running](screenshots/running.png) ⏳
- [Test results](screenshots/test.png) ⏳
