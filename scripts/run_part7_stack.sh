#!/usr/bin/env bash
# ============================================================
# CP8 — Part 7 Bước 2 (production/): stack Prometheus + Grafana + Jaeger + Locust.
#
#   bash scripts/run_part7_stack.sh
#
# Script làm các bước chạy lệnh và ghi số liệu thật vào evidence/part7-stack.log:
#   1. bật stack với -p k5-day14-observability, chạy promtool test alert rules
#   2. Locust headless 100 user / 2 phút với 1 rồi 3 instance → benchmark-results/scale_{1,3}_stats.csv
#   3. tìm trace chậm nhất + 1 trace lỗi trong Jaeger, kèm dòng log JSON cùng trace_id
#   4. thí nghiệm A+B (MOCK_ERROR_RATE=0.2, MOCK_SLOW_RATE=0.3) và D (docker pause 1 instance),
#      đo thời gian từ lúc đổi tới lúc alert pending/firing qua API của Prometheus
# Phần BẠN phải làm tay là chụp 4 ảnh. Script dừng lại báo đúng lúc cần chụp:
#   grafana-dashboard.png, jaeger-slow-trace.png, jaeger-error-trace.png, prometheus-alert-firing.png
# Cần Docker, các cổng 8080 3000 9090 16686 4318 8089 trống. Khoảng 15 phút.
# ============================================================
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1
PY="${PYTHON:-python3}"
DIR="06-lab-complete/benchmark-observability/production"
PROJECT="k5-day14-observability"
C="docker compose -p $PROJECT -f $DIR/docker-compose.yml"
LOG="$ROOT/evidence/part7-stack.log"
LOAD_NAME="k5-obs-background-load"
mkdir -p "$ROOT/evidence" "$DIR/benchmark-results" "$ROOT/benchmark-results"
: > "$LOG"

say() { printf '%s\n' "$*" | tee -a "$LOG"; }
section() { printf '\n===== %s =====\n' "$1" | tee -a "$LOG"; }
run() { printf '$ %s\n' "$1" | tee -a "$LOG"; eval "$1" 2>&1 | tee -a "$LOG"; return "${PIPESTATUS[0]}"; }
code() { curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$1"; }
wait_200() {
  local url="$1" secs="${2:-180}"
  for _ in $(seq 1 "$secs"); do [ "$(code "$url")" = "200" ] && return 0; sleep 1; done
  say "!! $url chưa trả 200 sau ${secs}s"; return 1
}
pause_for_user() {  # dừng cho người dùng chụp ảnh (chỉ khi chạy trong terminal)
  say ""
  say "📸 $1"
  if [ -t 0 ]; then read -r -p "   Chụp xong thì nhấn Enter để chạy tiếp... " _; else sleep "${2:-60}"; fi
}
agents_up() {  # agents_up <số instance> [VAR=value...] — áp dụng cấu hình mới cho agent
  local n="$1"; shift
  run "env $* $C up -d --no-deps --scale agent=$n agent 2>&1 | tail -n 4"
}
stop_bg_load() { docker rm -f "$LOAD_NAME" >/dev/null 2>&1; }
start_bg_load() {  # Locust chạy nền 30 user cho dashboard và thí nghiệm
  stop_bg_load
  run "$C run -d --no-deps --name $LOAD_NAME locust -f /mnt/locust/locustfile.py --host http://nginx --headless -u 30 -r 5 -t 30m >/dev/null"
}
alerts_json() { curl -s --max-time 5 http://localhost:9090/api/v1/alerts; }
cleanup() { stop_bg_load; }
trap cleanup EXIT
trap 'exit 130' INT TERM

say "Part 7 stack — $(date '+%Y-%m-%d %H:%M:%S %z') | $(docker --version) | $(docker compose version | head -1)"

# ── 1. Bật stack ───────────────────────────────────────────
section "7.4 — bật stack (1 instance agent)"
run "$C up -d --build --quiet-pull --scale agent=1 2>&1 | tail -n 12"
wait_200 http://localhost:8080/health 240 || exit 1
wait_200 http://localhost:9090/-/ready 120
wait_200 http://localhost:3000/api/health 120
run "$C ps --format 'table {{.Service}}\t{{.Name}}\t{{.State}}\t{{.Ports}}'"

section "7.6 — unit test alert rules (promtool)"
run "docker run --rm -v \"$ROOT/$DIR/prometheus:/p\" --entrypoint promtool prom/prometheus:v3.16.0 test rules /p/alert_rules_test.yml"

section "7.4 — gọi thử qua Nginx; /metrics không public"
run "curl -s -i -X POST http://localhost:8080/ask -H 'X-API-Key: day14-lab-key' -H 'Content-Type: application/json' -d '{\"question\": \"Trong distributed tracing, span là gì?\"}'; echo"
run "curl -s -i http://localhost:8080/metrics; echo"

# ── 2. Benchmark scaling ───────────────────────────────────
section "2.7 — Locust headless 100 user, ramp 10/s, 2 phút — 1 instance"
run "$C run --rm --no-deps locust -f /mnt/locust/locustfile.py --host http://nginx --headless -u 100 -r 10 -t 2m --csv /mnt/results/scale_1 2>&1 | tail -n 25"

section "2.7 — scale lên 3 instance rồi chạy lại"
agents_up 3
say "Chờ 20s để Nginx và Prometheus thấy instance mới (DNS refresh 10s)..."
sleep 20
say ""
say "📸 Trong 2 phút tới đang có tải 100 user: mở http://localhost:3000 (dashboard 'Day 14 — AI Agent Overview')"
say "   và chụp grafana-dashboard.png khi các panel đã có số (khoảng sau 1 phút)."
run "$C run --rm --no-deps locust -f /mnt/locust/locustfile.py --host http://nginx --headless -u 100 -r 10 -t 2m --csv /mnt/results/scale_3 2>&1 | tail -n 25"

section "Tóm tắt CSV Locust (dòng /ask và Aggregated)"
"$PY" - "$DIR/benchmark-results" <<'PYEOF' | tee -a "$LOG"
import csv, sys, pathlib
d = pathlib.Path(sys.argv[1])
cols = ["Request Count", "Failure Count", "Requests/s", "50%", "95%", "99%", "Average Response Time"]
for n in (1, 3):
    p = d / f"scale_{n}_stats.csv"
    if not p.exists():
        print(f"scale_{n}: không có file {p}"); continue
    for row in csv.DictReader(open(p, encoding="utf-8")):
        if row["Name"] in ("/ask", "Aggregated"):
            print(f"scale_{n} {row['Name']:<10} " + "  ".join(f"{c}={row[c]}" for c in cols))
PYEOF
cp "$DIR"/benchmark-results/scale_*_stats.csv "$ROOT/benchmark-results/" 2>/dev/null

# ── 3. Tracing ─────────────────────────────────────────────
section "7.5 — tìm trace trong Jaeger + dòng log cùng trace_id"
start_bg_load
sleep 20
"$PY" - <<'PYEOF' > "$ROOT/evidence/.traces" 2>&1
import json, urllib.request, urllib.parse
BASE = "http://localhost:16686/api/traces"
def fetch(**params):
    q = {"service": "observable-agent", "limit": "500", "lookback": "1h", **params}
    with urllib.request.urlopen(f"{BASE}?{urllib.parse.urlencode(q)}", timeout=20) as r:
        return json.load(r)["data"]
def describe(t):
    spans = t["spans"]
    ids = {s["spanID"] for s in spans}
    root = next((s for s in spans if not any(r["spanID"] in ids for r in s.get("references", []))),
                max(spans, key=lambda s: s["duration"]))
    children = {}
    for s in spans:
        for r in s.get("references", []):
            if r["refType"] == "CHILD_OF":
                children.setdefault(r["spanID"], []).append(s)
    def self_time(s):
        return s["duration"] - sum(c["duration"] for c in children.get(s["spanID"], []))
    worst = max(spans, key=self_time)
    total = root["duration"] / 1000
    print(f"trace_id={t['traceID']}  tổng={total:.1f} ms  root={root['operationName']}")
    for s in sorted(spans, key=lambda s: s["startTime"]):
        print(f"    - {s['operationName']:<28} {s['duration']/1000:8.1f} ms")
    print(f"  span chiếm nhiều thời gian nhất: {worst['operationName']} "
          f"({worst['duration']/1000:.1f} ms, {worst['duration']/root['duration']*100:.0f}% tổng)")
try:
    traces = [t for t in fetch(operation="POST /ask") if t["spans"]]
    slow = max(traces, key=lambda t: max(s["duration"] for s in t["spans"]))
    print("SLOW"); describe(slow)
    errs = fetch(tags=json.dumps({"error": "true"}))
    if errs:
        print("ERROR"); describe(errs[0])
    else:
        print("ERROR none")
except Exception as e:
    print("FAILED", type(e).__name__, e)
PYEOF
tee -a "$LOG" < "$ROOT/evidence/.traces"
SLOW_ID=$(grep -A1 '^SLOW' "$ROOT/evidence/.traces" | grep -o 'trace_id=[0-9a-f]*' | cut -d= -f2)
ERR_ID=$(grep -A1 '^ERROR' "$ROOT/evidence/.traces" | grep -o 'trace_id=[0-9a-f]*' | cut -d= -f2)
rm -f "$ROOT/evidence/.traces"
$C logs --no-color agent 2>/dev/null | sed 's/^[^|]*| //' > "$ROOT/evidence/.agent.log"
for id in $SLOW_ID $ERR_ID; do
  say "# dòng log có trace_id $id:"
  grep "\"trace_id\": \"$id\"" "$ROOT/evidence/.agent.log" | head -n 3 | tee -a "$LOG"
done
say "# ví dụ dòng log llm_error:"
grep '"llm_error"' "$ROOT/evidence/.agent.log" | head -n 1 | tee -a "$LOG"
rm -f "$ROOT/evidence/.agent.log"
pause_for_user "Mở http://localhost:16686 → ô 'Lookup by Trace ID' dán ${SLOW_ID:-<trace chậm>} → chụp jaeger-slow-trace.png;
   rồi dán ${ERR_ID:-<trace lỗi>} (span 'chat ...' có event exception) → chụp jaeger-error-trace.png." 90

# ── 4. Alerts: thí nghiệm phá hệ thống ─────────────────────
watch_alerts() {  # watch_alerts <tên thí nghiệm> <T0> <số giây tối đa> <alert cần firing...>
  local label="$1" t0="$2" max="$3"; shift 3
  local need="$*"
  ALERT_TIMELINE="$ROOT/evidence/.alerts-$label"
  : > "$ALERT_TIMELINE"
  for _ in $(seq 1 $((max / 5))); do
    alerts_json | "$PY" -c '
import json, sys, time
t0, path = float(sys.argv[1]), sys.argv[2]
seen = {}
for line in open(path, encoding="utf-8"):
    name, state, sec = line.split()
    seen.setdefault((name, state), sec)
try:
    alerts = json.load(sys.stdin)["data"]["alerts"]
except Exception:
    alerts = []
now = int(time.time() - t0)
with open(path, "a", encoding="utf-8") as f:
    for a in alerts:
        key = (a["labels"]["alertname"], a["state"])
        if key not in seen:
            seen[key] = now
            f.write(f"{key[0]} {key[1]} {now}\n")
            print(f"  +{now:>4}s  {key[0]:<22} → {key[1]}", flush=True)
' "$t0" "$ALERT_TIMELINE" | tee -a "$LOG"
    missing=$(alerts_json | "$PY" -c 'import json,sys
need = set(sys.argv[1:])
try: firing = {a["labels"]["alertname"] for a in json.load(sys.stdin)["data"]["alerts"] if a["state"]=="firing"}
except Exception: firing = set()
print(len(need - firing))' $need)
    [ "$missing" = "0" ] && return 0
    sleep 5
  done
  return 1
}

section "7.6 — trạng thái alert lúc bình thường (30 user, cấu hình mặc định, 3 instance)"
run "alerts_json | \"$PY\" -c 'import json,sys; a=json.load(sys.stdin)[\"data\"][\"alerts\"]; print(\"Không có alert nào\" if not a else \"\n\".join(x[\"labels\"][\"alertname\"]+\" \"+x[\"state\"] for x in a))'"

section "7.6 — Thí nghiệm A + B: MOCK_ERROR_RATE=0.2, MOCK_SLOW_RATE=0.3 (Locust 30 user vẫn chạy)"
T0=$(date +%s)
say "T0 = $(date '+%H:%M:%S') — áp dụng cấu hình lỗi"
agents_up 3 MOCK_ERROR_RATE=0.2 MOCK_SLOW_RATE=0.3
if watch_alerts AB "$T0" 420 AgentHighErrorRate AgentHighLatencyP95; then
  say "→ AgentHighErrorRate và AgentHighLatencyP95 cùng firing sau $(( $(date +%s) - T0 ))s"
else
  say "!! Sau 7 phút chưa có đủ 2 alert firing (xem timeline ở trên)"
fi
pause_for_user "Mở http://localhost:9090/alerts → chụp prometheus-alert-firing.png (thấy ≥ 2 alert FIRING).
   Nên chụp thêm dashboard Grafana lúc này (panel Error rate, Latency p95 đỏ) để dùng cho báo cáo." 60

section "Trả cấu hình agent về mặc định"
T_RESTORE=$(date +%s)
agents_up 3
say "Theo dõi alert hết firing (tối đa 4 phút)..."
for _ in $(seq 1 48); do
  n=$(alerts_json | "$PY" -c 'import json,sys
try: print(len([a for a in json.load(sys.stdin)["data"]["alerts"] if a["labels"]["alertname"] in ("AgentHighErrorRate","AgentHighLatencyP95")]))
except Exception: print(0)')
  [ "$n" = "0" ] && { say "Alert lỗi/latency đã hết sau $(( $(date +%s) - T_RESTORE ))s"; break; }
  sleep 5
done

section "7.6 — Thí nghiệm D: docker pause 1 instance agent"
AGENT1=$($C ps -q agent | head -n 1)
AGENT1_NAME=$(docker inspect -f '{{.Name}}' "$AGENT1" | sed 's#^/##')
T0=$(date +%s)
run "docker pause $AGENT1_NAME"
watch_alerts D "$T0" 180 AgentInstanceDown || say "!! Chưa thấy AgentInstanceDown firing sau 3 phút"
run "docker unpause $AGENT1_NAME"

section "Timeline alert (giây tính từ lúc đổi cấu hình)"
for f in "$ROOT"/evidence/.alerts-*; do
  [ -f "$f" ] || continue
  say "## Thí nghiệm ${f##*.alerts-}:"; sed 's/^/   /' "$f" | tee -a "$LOG"; rm -f "$f"
done

stop_bg_load
section "Xong"
say "CSV Locust: $DIR/benchmark-results/ (đã copy sang benchmark-results/). Log: evidence/part7-stack.log"
say "Stack VẪN ĐANG CHẠY để bạn chụp thêm ảnh nếu cần. Dọn dẹp khi xong:"
say "   $C down -v"
say "Commit: git add benchmark-results evidence/part7-stack.log screenshots && git commit -m 'Part 7: observability evidence' && git push"
