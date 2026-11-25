#!/usr/bin/env bash
# ============================================================
# Chạy các lệnh của Part 1, 2, 4, 5, 6 và lưu OUTPUT THẬT vào evidence/part1-5.log
# để điền MISSION_ANSWERS.md (token JWT được che trước khi ghi file).
#
# Yêu cầu: chạy từ gốc repo, trong virtualenv Python 3.11/3.12, Docker đang chạy,
#          cổng 8000, 80, 443, 8080 đang trống.
#   python3 -m venv .venv && source .venv/bin/activate
#   bash scripts/collect_evidence.sh            # chạy tất cả
#   bash scripts/collect_evidence.sh 4 5        # chỉ chạy Part 4 và 5
# Windows: chạy trong WSL2 (Docker Desktop bật WSL integration).
# ============================================================
set -u
set -m   # mỗi tiến trình nền có process group riêng → dừng được cả worker con

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1
PY="${PYTHON:-python3}"
OUT_DIR="$ROOT/evidence"
LOG="$OUT_DIR/part1-5.log"
PARTS="${*:-1 2 4 5 6}"
APP_LOGS="${TMPDIR:-/tmp}/k5-day14-app-logs"   # log thô của từng app (không commit)
mkdir -p "$OUT_DIR" "$APP_LOGS"

BG_PID=""
TOKEN=""
STACKS=()

mask() { sed -E -e 's/eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/<JWT-da-che>/g' \
                -e 's/(Bearer )[A-Za-z0-9._-]{20,}/\1<da-che>/g'; }
say() { printf '%s\n' "$*" | mask | tee -a "$LOG"; }
section() { printf '\n===== %s =====\n' "$1" | tee -a "$LOG"; }
run() {  # in lệnh rồi chạy, ghi cả output vào log
  printf '$ %s\n' "$1" | mask | tee -a "$LOG"
  eval "$1" 2>&1 | mask | tee -a "$LOG"
}
http_code() { curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$1"; }
wait_http() {  # chờ tới khi URL trả về bất kỳ mã HTTP nào (server đã lên)
  local url="$1" secs="${2:-30}" i
  for i in $(seq 1 $((secs * 5))); do
    [ "$(http_code "$url")" != "000" ] && return 0
    sleep 0.2
  done
  say "!! $url không phản hồi sau ${secs}s"
  return 1
}
wait_200() {  # chờ tới khi URL trả 200 (vd stack Docker đã healthy, không chỉ Nginx đã lên)
  local url="$1" secs="${2:-120}" i
  for i in $(seq 1 "$secs"); do
    [ "$(http_code "$url")" = "200" ] && return 0
    sleep 1
  done
  say "!! $url chưa trả 200 sau ${secs}s"
  return 1
}
pip_install() { "$PY" -m pip install -q -r "$1" 2>&1 | tail -n 3 | tee -a "$LOG"; }
start_app() {  # start_app <thư mục> <tên log> <lệnh...>
  local dir="$1" name="$2"; shift 2
  if [ "$(http_code http://localhost:8000/)" != "000" ]; then
    say "!! Cổng 8000 đang bận — tắt server cũ rồi chạy lại phần này"
    return 1
  fi
  ( cd "$dir" && exec "$@" ) >"$APP_LOGS/app-$name.log" 2>&1 &
  BG_PID=$!
  if ! wait_http http://localhost:8000/ 40; then
    say "--- log của app:"; tail -n 20 "$APP_LOGS/app-$name.log" | mask | tee -a "$LOG"
    return 1
  fi
}
stop_app() {
  if [ -n "$BG_PID" ] && kill -0 "$BG_PID" 2>/dev/null; then
    kill -TERM -- "-$BG_PID" 2>/dev/null || kill -TERM "$BG_PID" 2>/dev/null
    for _ in $(seq 1 50); do kill -0 "$BG_PID" 2>/dev/null || break; sleep 0.2; done
    kill -KILL -- "-$BG_PID" 2>/dev/null || true
  fi
  BG_PID=""
}
cleanup() {
  stop_app
  docker rm -f k5-day14-develop >/dev/null 2>&1 || true
  for s in "${STACKS[@]:-}"; do [ -n "$s" ] && eval "$s down" >/dev/null 2>&1; done
}
trap cleanup EXIT
trap 'exit 130' INT TERM

wants() { case " $PARTS " in *" $1 "*) return 0;; *) return 1;; esac; }

if [ $# -eq 0 ]; then : > "$LOG"; fi   # chạy tất cả → ghi lại từ đầu; chạy lẻ → ghi nối tiếp
say "Evidence log — $(date '+%Y-%m-%d %H:%M:%S %z')"
say "Python: $("$PY" --version 2>&1) | $(docker --version 2>&1) | $(docker compose version 2>&1 | head -1)"
say "OS: $(uname -srm)"

# ─────────────────────────────────────────────────────────── Part 1
if wants 1; then
  pip_install 01-localhost-vs-production/production/requirements.txt

  section "PART 1.2 — develop: POST /ask?question=Hello"
  if start_app 01-localhost-vs-production/develop part1-develop "$PY" app.py; then
    run 'curl -s -i -X POST "http://localhost:8000/ask?question=Hello"'
    run 'curl -s -o /dev/null -w "GET /health -> HTTP %{http_code}\n" http://localhost:8000/health'
    say "--- console của app (để ý dòng in ra API key):"
    run "tail -n 8 '$APP_LOGS/app-part1-develop.log'"
  fi
  stop_app

  section "PART 1.3 — production: /health, /ready, /ask (JSON body)"
  if start_app 01-localhost-vs-production/production part1-production env ENVIRONMENT=development "$PY" app.py; then
    run 'curl -s http://localhost:8000/health; echo'
    run 'curl -s http://localhost:8000/ready; echo'
    run "curl -s -X POST http://localhost:8000/ask -H 'Content-Type: application/json' -d '{\"question\": \"Hello\"}'; echo"
    say "--- log của app:"
    run "tail -n 8 '$APP_LOGS/app-part1-production.log'"
  fi
  stop_app
fi

# ─────────────────────────────────────────────────────────── Part 2
if wants 2; then
  section "PART 2.2 — build + run image develop"
  run 'docker build -q -f 02-docker/develop/Dockerfile -t my-agent:develop .'
  docker rm -f k5-day14-develop >/dev/null 2>&1
  run 'docker run -d --rm --name k5-day14-develop -p 8000:8000 my-agent:develop'
  if wait_http http://localhost:8000/ 40; then
    run 'curl -s -X POST "http://localhost:8000/ask?question=What%20is%20Docker"; echo'
    run 'curl -s http://localhost:8000/health; echo'
  fi
  run 'docker stop k5-day14-develop'

  section "PART 2.3 — image size develop vs production"
  run 'docker build -q -f 02-docker/production/Dockerfile -t my-agent:advanced .'
  run 'docker images my-agent'
  run "docker image inspect --format '{{.Size}}' my-agent:develop my-agent:advanced | \"$PY\" -c 'import sys; d, a = [int(x) for x in sys.stdin.read().split()]; print(f\"develop  = {d/1e6:.0f} MB ({d} bytes)\"); print(f\"advanced = {a/1e6:.0f} MB ({a} bytes)\"); print(f\"advanced nhỏ hơn develop {(d-a)/d*100:.1f}%\")'"

  section "PART 2.4 — docker compose stack (agent + redis + qdrant + nginx)"
  touch 02-docker/production/.env.local
  C2="docker compose -p k5-day14-docker -f 02-docker/production/docker-compose.yml"
  STACKS+=("$C2")
  run "$C2 up -d --build --quiet-pull 2>&1 | tail -n 8"
  if wait_200 http://localhost/health 180; then
    run "$C2 ps"
    run 'curl -s http://localhost/health; echo'
    run "curl -s -X POST http://localhost/ask -H 'Content-Type: application/json' -d '{\"question\": \"Explain microservices\"}'; echo"
  fi
  run "$C2 down"
fi

# ─────────────────────────────────────────────────────────── Part 4
if wants 4; then
  pip_install 04-api-gateway/production/requirements.txt

  section "PART 4.1 — API key (develop, AGENT_API_KEY=secret-key-123)"
  if start_app 04-api-gateway/develop part4-develop env AGENT_API_KEY=secret-key-123 "$PY" app.py; then
    say "# 1) không có key"
    run "curl -s -i -X POST http://localhost:8000/ask -H 'Content-Type: application/json' -d '{\"question\": \"Hello\"}'; echo"
    say "# 2) sai key"
    run "curl -s -i -X POST http://localhost:8000/ask -H 'X-API-Key: wrong-key' -H 'Content-Type: application/json' -d '{\"question\": \"Hello\"}'; echo"
    say "# 3) đúng key"
    run "curl -s -i -X POST http://localhost:8000/ask -H 'X-API-Key: secret-key-123' -H 'Content-Type: application/json' -d '{\"question\": \"Hello\"}'; echo"
  fi
  stop_app

  section "PART 4.2 — JWT (production, user student/demo123)"
  if start_app 04-api-gateway/production part4-production "$PY" app.py; then
    run "curl -s -X POST http://localhost:8000/auth/token -H 'Content-Type: application/json' -d '{\"username\": \"student\", \"password\": \"demo123\"}'; echo"
    TOKEN=$(curl -s -X POST http://localhost:8000/auth/token -H 'Content-Type: application/json' \
      -d '{"username": "student", "password": "demo123"}' | "$PY" -c 'import sys, json; print(json.load(sys.stdin)["access_token"])')
    say "# không có token"
    run "curl -s -i -X POST http://localhost:8000/ask -H 'Content-Type: application/json' -d '{\"question\": \"Explain JWT\"}'; echo"
    say "# có token"
    run "curl -s -i -X POST http://localhost:8000/ask -H \"Authorization: Bearer \$TOKEN\" -H 'Content-Type: application/json' -d '{\"question\": \"Explain JWT\"}'; echo"
  fi
  stop_app

  section "PART 4.3 — rate limit: 12 request liên tiếp bằng token student (restart app để cửa sổ sạch)"
  if start_app 04-api-gateway/production part4-ratelimit "$PY" app.py; then
    for i in $(seq 1 12); do
      code=$(curl -s -o "$APP_LOGS/.body" -w '%{http_code}' -X POST http://localhost:8000/ask \
        -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d "{\"question\": \"Test $i\"}")
      say "Request $(printf '%2d' "$i"): HTTP $code  $(head -c 110 "$APP_LOGS/.body")"
    done
    say "# header của response 429:"
    run "curl -s -i -X POST http://localhost:8000/ask -H \"Authorization: Bearer \$TOKEN\" -H 'Content-Type: application/json' -d '{\"question\": \"one more\"}' | head -n 12; echo"
    rm -f "$APP_LOGS/.body"
  fi
  stop_app
fi

# ─────────────────────────────────────────────────────────── Part 5
if wants 5; then
  pip_install 05-scaling-reliability/develop/requirements.txt

  section "PART 5.1 — /health và /ready (develop)"
  if start_app 05-scaling-reliability/develop part5-develop "$PY" app.py; then
    run 'curl -s -i http://localhost:8000/health; echo'
    run 'curl -s -i http://localhost:8000/ready; echo'

    section "PART 5.2 — graceful shutdown: gửi request rồi SIGTERM ngay"
    APP_PID=$BG_PID
    ( curl -s -o "$APP_LOGS/.inflight" -w '%{http_code}' -X POST \
        "http://localhost:8000/ask?question=Long%20task" > "$APP_LOGS/.inflight_code" ) &
    CURL_PID=$!
    sleep 0.05
    say "\$ kill -TERM $APP_PID   (gửi SIGTERM khi request đang chạy)"
    kill -TERM "$APP_PID"
    wait "$CURL_PID"
    for _ in $(seq 1 200); do kill -0 "$APP_PID" 2>/dev/null || break; sleep 0.2; done
    if kill -0 "$APP_PID" 2>/dev/null; then
      say "!! Agent chưa thoát sau 40s → kill -9"; kill -KILL -- "-$APP_PID" 2>/dev/null
    fi
    wait "$APP_PID"; app_exit=$?
    say "Request đang chạy nhận được: HTTP $(cat "$APP_LOGS/.inflight_code")  body: $(cat "$APP_LOGS/.inflight")"
    say "Process agent thoát với exit code: $app_exit"
    say "--- log của app lúc tắt:"
    run "tail -n 12 '$APP_LOGS/app-part5-develop.log'"
    rm -f "$APP_LOGS/.inflight" "$APP_LOGS/.inflight_code"
    BG_PID=""
  fi
  stop_app

  section "PART 5.4 — 3 agent + Redis + Nginx (cổng 8080)"
  touch 05-scaling-reliability/production/.env.local
  C5="docker compose -p k5-day14-scaling -f 05-scaling-reliability/production/docker-compose.yml"
  STACKS+=("$C5")
  run "$C5 up -d --build --scale agent=3 --quiet-pull 2>&1 | tail -n 8"
  if wait_200 http://localhost:8080/health 180; then
    sleep 3
    run "$C5 ps"
    say "# 10 request /chat → instance nào phục vụ:"
    for i in $(seq 1 10); do
      say "Request $(printf '%2d' "$i") → $(curl -s -X POST http://localhost:8080/chat -H 'Content-Type: application/json' \
        -d "{\"question\": \"Request $i\"}" | "$PY" -c 'import sys, json; print(json.load(sys.stdin).get("served_by"))')"
    done

    section "PART 5.5 — python test_stateless.py"
    run "(cd 05-scaling-reliability/production && \"$PY\" test_stateless.py)"
    run "$C5 logs --no-color --tail 6 agent"
  fi
  run "$C5 down"
fi

# ─────────────────────────────────────────────────────────── Part 6
if wants 6; then
  section "PART 6 — python check_production_ready.py (bản đầy đủ, có Docker)"
  pip_install 06-lab-complete/requirements.txt
  run "(cd 06-lab-complete && \"$PY\" check_production_ready.py)"
fi

say ""
say "Xong. Output nằm ở: $LOG"
