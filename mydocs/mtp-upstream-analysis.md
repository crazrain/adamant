# MTP upstream 분석 (2026-11-22)

질문: upstream(basalt/main)에 Qwen3.8 디코드 성능을 개선할 MTP 변경이 있는가.
기준: merge-base `d2480d12` → `basalt/main`, 경로 `src/models/qwen4exp/decode/mtp/`, `include/basalt/models/qwen4exp/decode/`, `src/spec/draft_policy.cpp`, `include/basalt/spec/draft_policy.hpp`, 메시지 grep(mtp/draft/speculat).

## 실측된 현재 상태 (adamant, IQ3_XXS 서빙)

- MTP 활성, 기본 pack drafter window 8. 프로브: `drafts_offered 1125 / accepted 802` = 수용률 71.3%, forward 패스당 ~3.1토큰.
- A/B 런 stdout: `speculation 110 rounds of 6, drafts accepted 148 of 203 (0.729), 2.35 tokens per round`, `window sizes T1:14 T2:31 T3:23 T4:42 (cumulative draft rule)` — 창 크기가 런 중에 계속 바뀜.
- `basalt::spec::DraftPolicy`(lookup-or-MTP와 창 크기 선택)는 **timed 모드**: 창 크기별 비용을 wall-clock 라운드 시간에서 학습. adamant은 merge-base와 diff 0(손대지 않음).

## upstream 변경 분류

| 변경 | 내용 | 판정 |
|---|---|---|
| `844be5cb` qwen4exp: the lookup-or-MTP window choice no longer reads round times | `DraftPolicy(max_t, margin, timed=false)` — 라운드 시간을 안 읽고 크기별 prior shape로 비용 계산. 선택이 결정적(같은 토큰 → 같은 창). 6파일 +12/−8, 호출부 5곳(decode.cpp, batch.cpp, tier_profile.cpp×2, verify.cpp) — adamant 전부 변경 전 상태와 일치, 클린 포팅 가능 | **포팅 후보 (성능+결정성)** |
| `6370f0ba` decode: the draft wait ... yield after 50 us (#246) | `mtp/draft.cpp`의 wait_step에 `SpinWait`(50µs 후 양보, 양보 중 stream query 주기 1023→63) | 이미 추적 중 — spin_wait(P2, Phase 3) 항목과 동일 변경 |
| `mtp/load.cpp` +73, `mtp.hpp`/`common.hpp`/`verify.hpp` hc8 시그니처 | 단일 패스 로더(`LoadPlan`) 어댑테이션 | 보류 — 단일 패스 로더 결정에 묶임 |
| `verify.hpp` `row_logprobs`, logprobs=K | API 기능 | 비성능 — 목록 하단 |
| qwen35/deepseek41 drafter 커밋들 | 타 모델 전용 | 범위 밖 |
| `be3708ab` community: RTX 5070 Ti IQ3_XXS "tuned MTP" | 코드 아님 — MTP 파라미터 튜닝 런 기록 | 데이터 포인트: 파라미터 튜닝 실익 존재 |

## 결론과 제안

1. **`844be5cb` 이식** — 6파일 +12/−8, 충돌 없음. 근거: 어댑티브 티어가 라운드 수를 세는 구조에서 창 크기 선택이 라운드 시간에 학습하면 티어 스왑 노이즈가 선택을 흔듦(커밋 메시지). 선택이 흔들리면 수용률·tokens/round가 함께 흔들린다. 검증: 이식 전후 `--spec 4` 고정 조건에서 tokens/round·수용률·decode tok/s 5회, 그레디 결정성(동일 프롬프트 런 간 토큰 동일) 확인.
2. **window 파라미터 실험** — 코딩 없음. 서빙 `--spec` 4 vs 8 vs 6, 같은 워크로드 tokens/round 비교. 커뮤니티 "tuned MTP"가 실익 방증.
3. 상한: 수용률 71→85%가 +13% 산수. 위 두 항목은 그중 선택 품질분 — 전부는 아니다. drafter 자체 품질 개선(더 좋은 MTP 가중치/tree speculation)은 upstream에 없음.
4. loader 어댑테이션분은 단일 패스 로더 채택 시 함께.
