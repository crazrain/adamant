# 성능 벤치 (2026-11-21, IQ4_XS / IQ3_XXS 비교)

패치판 엔진(`bin\basalt.exe` ← plan_reserve+unbuffered, 원본 `basalt.exe.org`)으로 서빙 중인
모델 실측. 방법론은 프로젝트 공식 `docs/benchmarks/strata-comparison.md` 준수:
temp 0 / top_p 1 / seed 1 / **추론 off**(`reasoning_tokens: 0` 전 런 확인) / 512 토큰 캡 /
워밍업 1회 제외 / 케이스별 nonce로 캐시 무효화(`reused: 0` 확인) / 코퍼스는 repo 문서
(README+CONTRIBUTING+docs/**) 이어붙이기 / **판정은 서버 기록**(`/metrics` 요청 레코드의
`prompt_ms`, `decode_tok_s`) / 항목 3회 중앙값. 스크립트: `/tmp/perfbench2.py`(OpenAI
스트리밍 클라이언트 + `/metrics` 레코드 매칭 — id 변화와 prompt/output 크기로 대조).

## 결과

| 항목 | IQ4_XS (min–max) | IQ3_XXS (min–max) | Δ |
|---|---|---|---|
| prefill 4k (4,008t) | 2,449 t/s (2,429–2,456) | 2,913 t/s (2,523–2,920) | +19% |
| prefill 16k (15,843t) | 3,536 t/s (3,350–3,582) | 3,673 t/s (3,346–3,742) | +3.9% |
| prefill 32k (34,110t) | 3,577 t/s (3,565–3,640) | 3,736 t/s (3,727–3,775) | +4.4% |
| chat decode (39t→512t) | 139.4 t/s (135.3–146.9) | 177.6 t/s (159.0–179.4) | +27% |
| agent decode (34,105t→512t) | 146.7 t/s (140.5–147.4) | 172.1 t/s (171.6–172.6)¹ | +17% |

¹ IQ3_XXS agent decode는 유효 2런 — run1은 외부 요청 오염(r_0009: 48,814t, reused 48,351)으로 제외.
IQ3_XXS prefill 4k run1(2,523)은 서버 재시작 직후 콜드; 2·3런(2,913/2,920)이 안정값.

## 판독

- IQ3_XXS가 전 항목 우세 — 가중치가 작아 PCIe 트래픽 감소. **decode +17~27%**가 가장 큼
  (디코드는 대역폭 바운드). expert cache hit_rate도 상승(0.85–0.94 vs 0.78–0.86) —
  전문가가 VRAM에 더 많이 상주.
- 서버 측 지표 기준 편차 ±3%. 클라이언트 TTFT로 잰 이전 시도는 큐 대기(단일 슬롯 직렬)와
  추론 on이 섞여 콜드 outlier처럼 보였다 — wall 27.4s인데 `prefill_tps` 3,536인 런이 증거.
- 4k prefill이 16k/32k보다 느린 것(2,449~2,913 vs ~3,700)은 요청 고정 오버헤드 비중.
  큰 컨텍스트가 prefill 효율 좋음.
- agent decode(34k) ≥ chat decode: 긴 컨텍스트에서도 스톨 없음.
- 규모 참고: 공식 4090 문서(4K prefill 2,768–2,930, decode 146–165)와 같은 수준.

## 벤치 작성 규칙 (재현용)

1. 추론은 **off** (`reasoning_effort: "none"` → `enable_thinking: false`). 서버 기본은 688 예산이라 명시 필수.
2. 판정은 `/metrics` 서버 레코드. 클라이언트 시간은 wall 참고용. 레코드는 스트림 종료 후 0.5~수 초 뒤에 도착 — id+크기로 매칭하고 `reused: 0`, `finish: length`, `reasoning_tokens: 0`을 확인.
3. 매 케이스 `Benchmark case {nonce}.` 접두사 + 고정 코퍼스로 캐시 무효화. 코퍼스 길이가 타겟 토큰 수를 커버하는지 assert (`4.0 chars/token` 근사, 32k ≈ 117,400자).
4. 워밍업 요청 1회 후 측정. 동시 트래픽이 있으면(10만t급 에이전트 요청 관측됨) 서버 지표는 유지되지만 hit_rate가 흔들림 — 판정 전 `/metrics` 레코드 간격으로 간섭 확인. 레코드 매칭은 prompt_tokens 허용범위를 좁게(±20%) 잡아야 남의 요청을 집지 않는다.
