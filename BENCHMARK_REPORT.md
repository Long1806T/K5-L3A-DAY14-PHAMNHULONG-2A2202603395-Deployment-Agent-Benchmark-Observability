# Benchmark & Observability Report — Day 14

> Mọi con số lấy từ report JSON (`reports/`), CSV Locust (`benchmark-results/`) và log thật
> (`evidence/part7-local.log`, `evidence/part7-stack.log`). Ô **⏳** = chờ số liệu từ lần chạy trên máy.

**Họ tên:** Pham Nhu Long — 2A2202603395
**Ngày chạy:** ⏳
**Môi trường:** ⏳ (máy, OS/WSL2, Docker Desktop CPU/RAM)

---

## 1. SLO của agent

| SLI | SLO | Lý do chọn ngưỡng này |
|---|---|---|
| p95 latency `/ask` | < 500 ms | Request bình thường của mock LLM mất khoảng 120–180 ms + 20 ms retrieval. 500 ms cho dư khoảng 2 lần khi có tải mà người dùng vẫn thấy nhanh. Đo p95 vì khoảng 3% request chậm thêm 1,5 s (`MOCK_SLOW_RATE`) làm trung bình sai lệch. Trùng với SLO mặc định của `load_test.py` |
| Error rate `/ask` | < 2 % | Upstream LLM mock lỗi ngẫu nhiên khoảng 1%, nên budget 2% đủ chứa nhiễu bình thường. Alert của Prometheus đặt lỏng hơn (5% trong 1 phút) để tránh báo động liên tục vì spike ngắn |
| Accuracy trên golden dataset | ≥ 85 % | Ngưỡng của quality gate trong CI (`.github/workflows/eval.yml`). Thấp hơn là chặn merge; v2 sau khi sửa knowledge base đạt 100% |

---

## 2. Benchmark hiệu năng (develop, `load_test.py`)

### 2.1 Concurrency vs latency (agent v2)

Nguồn: `reports/load_v2_c{1,10,50,100}.json` (300 request mỗi mức).

| Concurrency | RPS | p50 (ms) | p95 (ms) | p99 (ms) | Error rate | SLO |
|---|---|---|---|---|---|---|
| 1 | ⏳ | ⏳ | ⏳ | ⏳ | ⏳ | ⏳ |
| 10 | ⏳ | ⏳ | ⏳ | ⏳ | ⏳ | ⏳ |
| 50 | ⏳ | ⏳ | ⏳ | ⏳ | ⏳ | ⏳ |
| 100 | ⏳ | ⏳ | ⏳ | ⏳ | ⏳ | ⏳ |

**Nhận xét:** ⏳

### 2.2 Tail latency

Nguồn: `reports/load_v2_slow_{0,0.03,0.1}.json` (300 request, concurrency 20).

| `MOCK_SLOW_RATE` | avg (ms) | p95 (ms) | p99 (ms) |
|---|---|---|---|
| 0 | ⏳ | ⏳ | ⏳ |
| 0.03 (mặc định) | ⏳ | ⏳ | ⏳ |
| 0.1 | ⏳ | ⏳ | ⏳ |

**Nhận xét:** ⏳

---

## 3. Benchmark chất lượng (develop, `eval/run_eval.py`)

Nguồn: `reports/eval_v1.json`, `reports/eval_v2.json`, `reports/eval_v2_fixed.json`.

| Chỉ số | Agent v1 | Agent v2 | Agent v2 (sau khi sửa KB) |
|---|---|---|---|
| Accuracy | ⏳ | ⏳ | ⏳ |
| Avg tokens / câu | ⏳ | ⏳ | ⏳ |
| Tổng cost (USD) | ⏳ | ⏳ | ⏳ |
| Cost / câu đúng (USD) | ⏳ | ⏳ | ⏳ |
| Quality gate | ⏳ | ⏳ | ⏳ |

**Những câu v2 trả lời sai ban đầu và cách bạn sửa:**

| ID | Keyword bị thiếu | Bạn đã sửa gì |
|---|---|---|
| `security-02` (JWT khác gì API key) | `token`, `hết hạn`, `chữ ký` | Thêm vào `KNOWLEDGE_BASE` tài liệu kích hoạt bởi `jwt` / `json web token`: JWT là token có thời điểm hết hạn và chữ ký số, server kiểm tra chữ ký mà không tra database; API key cố định, không tự hết hạn |
| `scaling-03` (Kubernetes HPA) | `cpu`, `memory`, `custom metrics` | Thêm tài liệu kích hoạt bởi `hpa` / `kubernetes` / `autoscal`: HPA scale số pod theo CPU, memory hoặc custom metrics (request/giây, độ dài hàng đợi) |

Hai entry mới được thêm vào **cuối** danh sách và dùng từ khoá không xuất hiện trong 21 câu còn lại. Retrieval chọn tài liệu có nhiều từ khoá trùng nhất (bằng nhau thì giữ thứ tự cũ), nên các câu đang đúng không bị đổi tài liệu, tức không có regression. Cùng thay đổi được chép sang `production/utils/mock_llm.py` cho stack Docker.

**Quality gate trong CI:** `run_eval.py` trả **exit code 1** khi accuracy < `--min-accuracy` hoặc có câu bị regression so với `--baseline`. Job `.github/workflows/eval.yml` bật agent v2 rồi chạy `python eval/run_eval.py --min-accuracy 0.85` cho mỗi Pull Request: exit code 1 → step fail → check của PR đỏ. Đặt check này là *required* trong Branch protection của `main` thì PR không merge được. Chạy v1 với `--baseline reports/eval_v2.json` cho exit code: ⏳ (mong đợi 1).

**Nhận xét về trade-off chất lượng / chi phí / latency giữa v1 và v2:** ⏳

---

## 4. Observability stack (production)

### 4.1 Screenshot

- [ ] Dashboard Grafana khi đang có tải (thấy rõ Golden Signals): `screenshots/grafana-dashboard.png` ⏳
- [ ] Một trace chậm trong Jaeger (thấy span nào chiếm thời gian): `screenshots/jaeger-slow-trace.png` ⏳
- [ ] Một trace lỗi trong Jaeger (có event `exception`): `screenshots/jaeger-error-trace.png` ⏳
- [ ] Trang Alerts của Prometheus với ít nhất 2 alert đang **firing**: `screenshots/prometheus-alert-firing.png` ⏳

### 4.2 Thí nghiệm "phá hệ thống"

Locust chạy nền 30 user, 3 instance agent. Thời gian đo bằng cách hỏi API `/api/v1/alerts` của Prometheus mỗi 5 giây (`evidence/part7-stack.log`).

| # | Thay đổi | Alert nào firing | Thời gian từ lúc đổi → firing | Panel nào phản ánh rõ nhất |
|---|---|---|---|---|
| A | `MOCK_ERROR_RATE=0.2` | ⏳ | ⏳ | ⏳ |
| B | `MOCK_SLOW_RATE=0.3` | ⏳ | ⏳ | ⏳ |
| C | `LLM_MODEL=mock-llm-large` | (không làm) | | |
| D | `docker pause` 1 instance | ⏳ | ⏳ | ⏳ |
| E | `AGENT_VERSION=v1` | (không làm) | | |

**Thí nghiệm E không làm alert nào firing. Bạn sẽ phát hiện loại sự cố này trong production bằng cách nào?**

Đổi sang v1 làm câu trả lời tệ đi, nhưng request vẫn nhanh và vẫn trả 200, nên các metric hạ tầng (latency, error rate, instance up) vẫn xanh. Loại sự cố chất lượng này chỉ bắt được bằng cách **đo chất lượng**:

1. **Chặn trước khi deploy:** quality gate eval trên golden dataset trong CI. Đã làm ở `.github/workflows/eval.yml`; v1 có accuracy rất thấp nên bị chặn.
2. **Theo dõi khi đang chạy:** chạy eval định kỳ (synthetic) vào môi trường production và alert khi accuracy giảm; theo dõi các metric gián tiếp như *retrieval hit ratio* (v1 = 0), tokens/câu, bảng "Phiên bản đang chạy" trên dashboard; thu feedback người dùng (👍/👎) và chấm một mẫu traffic thật bằng LLM-as-judge.
3. **Deploy an toàn:** canary hoặc blue/green, so sánh các chỉ số chất lượng giữa bản mới và bản cũ trước khi chuyển toàn bộ traffic.

### 4.3 Debug bằng trace

Chọn 1 trace chậm nhất bạn tìm được:

- `trace_id`: ⏳
- Tổng thời gian: ⏳ ms
- Span chiếm nhiều thời gian nhất: ⏳
- Dòng log tương ứng (grep theo `trace_id`):

```json
⏳
```

---

## 5. Benchmark scaling (production, Locust headless, 100 users, 2 phút)

Nguồn: `benchmark-results/scale_1_stats.csv`, `benchmark-results/scale_3_stats.csv` (dòng `/ask`).

| Số instance | RPS | p50 (ms) | p95 (ms) | p99 (ms) | Failures |
|---|---|---|---|---|---|
| 1 | ⏳ | ⏳ | ⏳ | ⏳ | ⏳ |
| 3 | ⏳ | ⏳ | ⏳ | ⏳ | ⏳ |

**Giải thích kết quả:** ⏳

---

## 6. Kết luận

- 3 điều bạn học được về benchmark & observability:
  1. ⏳
  2. ⏳
  3. ⏳
- Nếu đưa agent này lên production thật, bạn sẽ thêm metric / alert nào nữa? ⏳

---

## Phụ lục — trả lời câu hỏi Exercise 7.1 và 7.4

**7.1.1 — Ví dụ mỗi loại metric trong `/metrics`** (output thật ở `evidence/part7-local.log`, mục 7.1):

- **Counter:** `http_requests_total{method="POST",route="/ask",status="200"}`, `llm_tokens_total{model="mock-llm-small",type="input"}`, `llm_cost_usd_total`: chỉ tăng, đọc bằng `rate()`.
- **Gauge:** `agent_in_flight_requests` (lên xuống theo số request đang xử lý), `agent_info{model="mock-llm-small",version="v2"} 1.0`.
- **Histogram:** `http_request_duration_seconds_bucket{le="0.2",...}` + `_sum` + `_count`; metric mới `agent_question_length_chars_bucket{le="50.0"}`. Từ các bucket, `histogram_quantile()` tính được p95/p99.
- Giá trị cụ thể: ⏳

**7.1.2 — Nếu label `route` dùng URL thật (`request.url.path`):** mỗi URL lạ mà bot quét (`/wp-admin`, `/.env`, `/a1b2c3`…) tạo một giá trị label mới, tức một bộ time series mới (counter + đủ các bucket của histogram). Số series tăng không giới hạn (cardinality explosion): Prometheus tốn RAM/disk, scrape và query chậm dần, có thể bị OOM. Kẻ tấn công còn có thể cố ý làm sập hệ thống giám sát. Dùng route template và gom URL không khớp route nào vào `unmatched` thì số series bị chặn ở số route thật của app.

**7.1 — Metric mới:** `agent_question_length_chars` là Histogram với bucket `20, 50, 100, 200, 500, 1000, 2000` ký tự, `observe(len(question))` trong `/ask`. Không dùng label `length=...` vì độ dài có vô số giá trị.

**7.4.1 — p95 và avg trên dashboard:** ⏳ (khoảng cách lớn giữa p95/p99 và avg là dấu hiệu của tail latency do một nhóm nhỏ request rất chậm)

**7.4.2 — Panel "Requests/s theo instance":** ⏳. Nginx dùng round-robin (`server agent:8000 resolve`, hỏi lại Docker DNS mỗi 10 giây), nên các instance nhận số request xấp xỉ nhau; chênh lệch nhỏ do keep-alive connection.

**7.4.3 — Vì sao input tokens/s lớn hơn output tokens/s:** với v2, prompt gửi LLM gồm system prompt + tài liệu retrieve được + câu hỏi, còn câu trả lời chỉ là một đoạn tài liệu. Input của mỗi request vì vậy dài hơn output (khoảng 80 so với 45 token theo cách ước lượng 4 ký tự/token), nên tốc độ token input cao hơn.

**7.4.4 — `curl http://localhost:8080/metrics`:** trả **404** vì Nginx chặn `location = /metrics { return 404; }`. Metrics là thông tin nội bộ (tên route, số request, chi phí…), không nên public và cũng không nên để người ngoài scrape tốn tài nguyên. Prometheus vẫn đọc được vì nó scrape thẳng từng container agent trong network nội bộ (`dns_sd_configs` → `agent:8000`), không đi qua Nginx.
