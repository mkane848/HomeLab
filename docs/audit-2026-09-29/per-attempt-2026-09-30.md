# Per-attempt table, N>1 protocol cells (2026-09-30, recomputed from tests/results at origin/main 20c3417)

Same-config = current prompt sha, the seat's designed numCtx (64k for qwen3.6/qwen3.5, 32k for qwen3:14b), Ollama 0.34.3. Timeouts and infra crashes count as attempts; human-aborted runs do not. `oc` = opencode version stamped in the run JSON.

| cell | # | when (UTC-4) | oc | writes | sec | s/su/foo | owner acc. | outcome |
|---|---|---|---|---|---|---|---|---|
| lfc-03 / qwen3.6 | 1 | 09-27T11:56 | 1.18.32 | 3 | 222.6 | P/P/P | PASS | PASS |
| lfc-03 / qwen3.6 | 2 | 09-29T22:39 | 1.18.33 | 8 | 532.3 | P/P/P | PASS | PASS |
| lfc-03 / qwen3.6 | 3 | 09-29T22:46 | 1.18.33 | 4 | 394.1 | P/P/P | PASS | PASS |
| lfc-03 / qwen3.5 | 1 | 09-27T11:52 | ? | - | - | - | - | INFRA (context/template crash) |
| lfc-03 / qwen3.5 | 2 | 09-29T18:26 | 1.18.33 | 5 | 310 | P/F/P | FAIL | FAIL suite (build/test file broken) |
| lfc-03 / qwen3.5 | 3 | 09-29T18:36 | 1.18.33 | 16 | 554.4 | P/P/F | PASS | FAIL failsOnOld (test green on broken code) |
| lfc-03 / qwen3 | 1 | 09-26T19:15 | 1.18.32 | 9 | 957.4 | P/F/P | FAIL | FAIL suite (build/test file broken) |
| lfc-03 / qwen3 | 2 | 09-29T17:51 | 1.18.33 | 6 | 1174.9 | P/P/F | FAIL | FAIL failsOnOld (test green on broken code) |
| lfc-03 / qwen3 | 3 | 09-29T18:21 | ? | - | - | - | - | TIMEOUT (1800 s cap) |
| kane-02 / qwen3.6 | 1 | 09-27T13:47 | 1.18.32 | 2 | 368.9 | P/P/P | SKIP | PASS |
| kane-02 / qwen3.6 | 2 | 09-29T22:00 | 1.18.33 | 4 | 1269 | P/P/P | SKIP | PASS |
| kane-02 / qwen3.6 | 3 | 09-29T22:08 | 1.18.33 | 3 | 475.7 | P/P/P | SKIP | PASS |
| kane-02 / qwen3.5 | 1 | 09-27T13:05 | 1.18.32 | 12 | 543.5 | P/P/P | SKIP | PASS |
| kane-02 / qwen3.5 | 2 | 09-29T20:03 | 1.18.33 | 3 | 209.5 | P/P/P | SKIP | PASS |
| kane-02 / qwen3.5 | 3 | 09-29T20:06 | 1.18.33 | 4 | 190.1 | P/P/P | SKIP | PASS |
| kane-02 / qwen3 | 1 | 09-26T23:20 | 1.18.32 | 2 | 926.9 | F/P/F | SKIP | FAIL scope (edited outside allowFiles) |
| asohav-02 / qwen3.6 | 1 | 09-27T15:51 | 1.18.32 | 6 | 538 | P/F/P | SKIP | FAIL suite (build/test file broken) |
| asohav-02 / qwen3.6 | 2 | 09-29T22:18 | 1.18.33 | 2 | 597.5 | P/P/P | SKIP | PASS |
| asohav-02 / qwen3.6 | 3 | 09-29T22:30 | 1.18.33 | 3 | 714.3 | P/P/P | SKIP | PASS |
| asohav-02 / qwen3.5 | 1 | 09-27T15:41 | 1.18.32 | 13 | 637.4 | P/P/P | SKIP | PASS |
| asohav-02 / qwen3.5 | 2 | 09-29T20:43 | 1.18.33 | 22 | 950.8 | P/F/P | SKIP | FAIL suite (build/test file broken) |
| asohav-02 / qwen3.5 | 3 | 09-29T20:55 | 1.18.33 | 11 | 706.3 | P/P/F | SKIP | FAIL failsOnOld (test green on broken code) |
| asohav-02 / qwen3 | 1 | 09-27T10:07 | 1.18.32 | 10 | 774.9 | P/F/P | SKIP | FAIL suite (build/test file broken) |
| asohav-02 / qwen3 | 2 | 09-29T20:21 | 1.18.33 | 4 | 378.9 | F/F/F | SKIP | FAIL scope (edited outside allowFiles) |
| asohav-02 / qwen3 | 3 | 09-29T20:27 | 1.18.33 | 7 | 392.7 | F/F/F | SKIP | FAIL scope (edited outside allowFiles) |
| kane-04 / qwen3.5 | 1 | 09-27T17:17 | 1.18.32 | 14 | 444.2 | P/P/P | SKIP | PASS |
| kane-04 / qwen3.5 | 2 | 09-29T16:37 | 1.18.33 | 17 | 503.9 | P/P/P | SKIP | PASS |
| kane-04 / qwen3.5 | 3 | 09-29T16:39 | 1.18.33 | 7 | 150.1 | P/P/P | SKIP | PASS |
| lfc-02 / qwen3.5 | 1 | 09-28T17:33 | 1.18.32 | 30 | 1140.4 | F/F/P | SKIP | FAIL scope (edited outside allowFiles) |
| lfc-02 / qwen3.5 | 2 | 09-29T16:52 | 1.18.33 | 18 | 721.1 | P/P/P | SKIP | PASS |
| lfc-02 / qwen3.5 | 3 | 09-29T16:54 | 1.18.33 | 4 | 116.7 | P/P/P | SKIP | PASS |
| asohav-01 / qwen3.5 | 1 | 09-28T21:49 | 1.18.32 | 9 | 377.5 | P/P/P | SKIP | PASS |
| asohav-01 / qwen3.5 | 2 | 09-29T16:58 | 1.18.33 | 4 | 211.9 | P/P/F | SKIP | FAIL failsOnOld (test green on broken code) |
| asohav-01 / qwen3.5 | 3 | 09-29T17:07 | 1.18.33 | 14 | 585.6 | P/F/P | SKIP | FAIL suite (build/test file broken) |

**Cell tallies (same-config attempts):** lfc-03 qwen3.6: 3/3; lfc-03 qwen3.5: 0/3; lfc-03 qwen3: 0/3; kane-02 qwen3.6: 3/3; kane-02 qwen3.5: 3/3; kane-02 qwen3: 0/1; asohav-02 qwen3.6: 2/3; asohav-02 qwen3.5: 1/3; asohav-02 qwen3: 0/3; kane-04 qwen3.5: 3/3; lfc-02 qwen3.5: 2/3; asohav-01 qwen3.5: 1/3

