#!/usr/bin/env bash
# ============================================================
# CP7 — Part 7 Bước 1 (develop/): load test + eval, lưu report JSON thật.
#
#   python3 -m venv .venv && source .venv/bin/activate     # Python 3.11/3.12
#   bash scripts/run_part7_local.sh
#
# Kết quả:
#   06-lab-complete/benchmark-observability/develop/reports/*.json  (+ bản copy ở reports/)
#   evidence/part7-local.log   (toàn bộ output, kể cả /metrics cho Exercise 7.1)
#
# Thứ tự đúng như CHECKPOINTS.md (CP7):
#   1. agent v1 (:8001) và v2 (:8002) với KNOWLEDGE_BASE GỐC của đề
#   2. load test v2 ở concurrency 1/10/50/100, rồi MOCK_SLOW_RATE = 0 / 0.03 / 0.1
#   3. eval v1, eval v2 (v2 còn sai 2 câu)
#   4. dùng KNOWLEDGE_BASE đã sửa (bản trong repo), restart v2, eval cuối với --min-accuracy 1.0
# Script tạm lấy mock_llm.py gốc từ commit đề bài cho bước 1–3 rồi trả lại bản đã sửa.
# Nếu bị dừng giữa chừng mà file chưa được trả lại: git checkout -- <đường dẫn mock_llm.py>
# ============================================================
set -u
set -m

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1
PY="${PYTHON:-python3}"
DEV="06-lab-complete/benchmark-observability/develop"
KB="$DEV/utils/mock_llm.py"
ORIG_REF="83e677f"            # commit đề bài (fork từ đây) — KNOWLEDGE_BASE chưa sửa
LOG="$ROOT/evidence/part7-local.log"
TMP="$(mktemp -d)"
mkdir -p "$ROOT/evidence" "$DEV/reports" "$ROOT/reports"
: > "$LOG"

PIDS=()
say() { printf '%s\n' "$*" | tee -a "$LOG"; }
section() { printf '\n===== %s =====\n' "$1" | tee -a "$LOG"; }
run() { printf '$ %s\n' "$1" | tee -a "$LOG"; ( cd "$DEV" && eval "$1" ) 2>&1 | tee -a "$LOG"; return "${PIPESTATUS[0]}"; }

start_agent() {  # start_agent <version> <port> [VAR=value...]
  local ver="$1" port="$2"; shift 2
  if [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://localhost:$port/health")" != "000" ]; then
    say "!! Cổng $port đang bận — tắt process đang dùng cổng này rồi chạy lại"; exit 1
  fi
  ( cd "$DEV" && exec env AGENT_VERSION="$ver" PORT="$port" "$@" "$PY" app.py ) \
    >"$TMP/agent-$ver-$port.log" 2>&1 &
  local pid=$!
  PIDS+=("$pid")
  for _ in $(seq 1 100); do
    [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://localhost:$port/health")" = "200" ] && {
      say "agent $ver đang chạy ở :$port $* (pid $pid)"; eval "PID_$port=$pid"; return 0; }
    sleep 0.2
  done
  say "!! agent $ver không khởi động được. Log:"; tail -n 20 "$TMP/agent-$ver-$port.log" | tee -a "$LOG"
  exit 1
}
stop_port() {  # stop_port <port>
  local var="PID_$1" pid
  pid="${!var:-}"
  [ -z "$pid" ] && return 0
  kill -TERM "$pid" 2>/dev/null
  for _ in $(seq 1 50); do kill -0 "$pid" 2>/dev/null || break; sleep 0.2; done
  kill -KILL "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  eval "PID_$1="
}
restore_kb() {
  if [ -f "$TMP/mock_llm_fixed.py" ]; then cp "$TMP/mock_llm_fixed.py" "$KB"; fi
}
cleanup() {
  for p in "${PIDS[@]:-}"; do [ -n "$p" ] && kill -TERM "$p" 2>/dev/null; done
  restore_kb
  rm -rf "$TMP"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

say "Part 7 local benchmark — $(date '+%Y-%m-%d %H:%M:%S %z')"
say "Python: $("$PY" --version 2>&1) | OS: $(uname -srm)"

# ── Chuẩn bị ───────────────────────────────────────────────
"$PY" -m pip install -q -r "$DEV/requirements.txt" || { say "!! pip install thất bại"; exit 1; }
if ! git diff --quiet -- "$KB"; then
  say "!! $KB đang có thay đổi chưa commit — commit hoặc bỏ thay đổi rồi chạy lại"; exit 1
fi
if ! git cat-file -e "$ORIG_REF:$KB" 2>/dev/null; then
  say "!! Không tìm thấy commit đề bài $ORIG_REF trong lịch sử git (clone đầy đủ, không --depth)"; exit 1
fi
cp "$KB" "$TMP/mock_llm_fixed.py"
git show "$ORIG_REF:$KB" > "$KB"
say "Đang dùng KNOWLEDGE_BASE gốc của đề (commit $ORIG_REF) cho bước load test + eval v1/v2"

# ── Exercise 7.1 — metrics ─────────────────────────────────
section "7.1 — agent v1 :8001, v2 :8002 và /metrics"
start_agent v1 8001
start_agent v2 8002
run "curl -s -X POST http://localhost:8002/ask -H 'Content-Type: application/json' -d '{\"question\": \"Prometheus thu thập metrics như thế nào?\"}'; echo"
say "# /metrics của v2 (bỏ dòng comment #, chỉ giữ các series tiêu biểu):"
curl -s http://localhost:8002/metrics | grep -v '^#' \
  | grep -E '^(http_requests_total|http_request_duration_seconds_(sum|count)|http_request_duration_seconds_bucket\{le="0\.2"|agent_in_flight_requests|llm_requests_total|llm_tokens_total|llm_cost_usd_total|agent_info|agent_question_length_chars)' \
  | tee -a "$LOG"

# ── Exercise 7.2 — load test ───────────────────────────────
section "7.2 — load test v2: concurrency 1 / 10 / 50 / 100 (300 request mỗi mức)"
for c in 1 10 50 100; do
  run "\"$PY\" load_test.py --url http://localhost:8002 --requests 300 --concurrency $c --out reports/load_v2_c$c.json"
done

section "7.2 — tail latency: v2 với MOCK_SLOW_RATE = 0 / 0.03 / 0.1 (300 request, concurrency 20)"
for rate in 0 0.03 0.1; do
  stop_port 8002
  start_agent v2 8002 MOCK_SLOW_RATE="$rate"
  run "\"$PY\" load_test.py --url http://localhost:8002 --requests 300 --concurrency 20 --out reports/load_v2_slow_$rate.json"
done
stop_port 8002
start_agent v2 8002

# ── Exercise 7.3 — eval ────────────────────────────────────
section "7.3 — eval v1 (baseline)"
run "\"$PY\" eval/run_eval.py --url http://localhost:8001 --out reports/eval_v1.json"
section "7.3 — eval v2 so với v1 (KNOWLEDGE_BASE gốc)"
run "\"$PY\" eval/run_eval.py --url http://localhost:8002 --out reports/eval_v2.json --baseline reports/eval_v1.json"
say "# Các câu v2 trả lời sai và keyword bị thiếu:"
"$PY" - "$DEV/reports/eval_v2.json" <<'PYEOF' | tee -a "$LOG"
import json, sys
report = json.load(open(sys.argv[1], encoding="utf-8"))
for r in report["results"]:
    if not r["passed"]:
        print(f"  {r['id']}: thiếu {r.get('missing_keywords', r.get('error'))}")
PYEOF

section "7.3 — quality gate: eval v1 với --baseline eval_v2.json (mong đợi exit code 1)"
run "\"$PY\" eval/run_eval.py --url http://localhost:8001 --baseline reports/eval_v2.json"
say "Exit code: $?"

section "7.3 — sửa KNOWLEDGE_BASE (bản trong repo), restart v2, eval cuối"
restore_kb
say "Đã trả lại mock_llm.py đã sửa. Khác biệt so với bản gốc:"
git diff --no-color "$ORIG_REF" -- "$KB" | grep -E '^[+-] ' | tee -a "$LOG"
stop_port 8002
start_agent v2 8002
run "\"$PY\" eval/run_eval.py --url http://localhost:8002 --min-accuracy 1.0 --baseline reports/eval_v2.json --out reports/eval_v2_fixed.json"
say "Exit code: $?"

stop_port 8001
stop_port 8002

# ── Tổng hợp + copy ra gốc repo ────────────────────────────
section "Tổng hợp số liệu (đọc từ file JSON)"
"$PY" - "$DEV/reports" <<'PYEOF' | tee -a "$LOG"
import json, sys, pathlib
d = pathlib.Path(sys.argv[1])
def load(name):
    p = d / name
    return json.loads(p.read_text()) if p.exists() else None
print(f"{'file':<26}{'RPS':>8}{'avg':>9}{'p50':>9}{'p95':>9}{'p99':>9}{'err%':>8}  SLO")
for name in ["load_v2_c1.json", "load_v2_c10.json", "load_v2_c50.json", "load_v2_c100.json",
             "load_v2_slow_0.json", "load_v2_slow_0.03.json", "load_v2_slow_0.1.json"]:
    r = load(name)
    if not r:
        print(f"{name:<26} (không có)"); continue
    l = r["latency_ms"]
    print(f"{name:<26}{r['rps']:>8}{l['avg']:>9}{l['p50']:>9}{l['p95']:>9}{l['p99']:>9}"
          f"{r['error_rate']*100:>7.2f}%  {'PASS' if r.get('slo', {}).get('passed') else 'FAIL'}")
print()
print(f"{'file':<22}{'accuracy':>10}{'passed':>8}{'avg_tok':>9}{'cost_usd':>12}{'cost/đúng':>14}  gate")
for name in ["eval_v1.json", "eval_v2.json", "eval_v2_fixed.json"]:
    r = load(name)
    if not r:
        print(f"{name:<22} (không có)"); continue
    cpc = r["cost_per_correct_usd"]
    print(f"{name:<22}{r['accuracy']*100:>9.1f}%{r['passed']:>5}/{r['total']:<2}{r['avg_tokens']:>9}"
          f"{r['total_cost_usd']:>12.6f}{(f'{cpc:.8f}' if cpc else 'n/a'):>14}  "
          f"{'PASS' if r.get('quality_gate', {}).get('passed') else 'FAIL'}")
PYEOF
cp -r "$DEV/reports/." "$ROOT/reports/"
say ""
say "Xong. Report JSON: $DEV/reports/ (đã copy sang reports/). Log: evidence/part7-local.log"
say "Commit: git add reports evidence/part7-local.log && git commit -m 'Part 7: local benchmark reports' && git push"
