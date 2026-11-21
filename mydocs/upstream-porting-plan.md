# Basalt upstream → Adamant 포팅 후보 분석 및 계획

상태: **1차 분석 문서 확정 (GPT 3차 검수 승인) · 4차 의견 반영** · 1차: `br-20261121-705c5f8ecc9d` · 작성: 2026-11-21 · 코드 수정 없음 · **실행 문서: [upstream-apply-first.md](upstream-apply-first.md)** (TOP 4, 첫 작업 `gu2.cuh`)

## 0. 실측된 저장소 상태 (분석 전제)

| 사실 | 값 | 근거 |
|---|---|---|
| 분기점(merge-base) | `d2480d1` (2026-11-08) = 지시된 비교 기준 커밋과 동일 | `git merge-base HEAD basalt/main` |
| upstream 진전 | 649커밋(머지 44 포함), 636파일 +68,577/−9,831 | `git rev-list --count`, `git diff --shortstat` |
| adamant 전용 | 83커밋 (머지 21 포함) | `git rev-list --count basalt/main..HEAD` |
| **adamant는 upstream 0.3.1/0.3.2 라인 내용을 이미 어댑트해 품고 있음** | 커밋 `267d6330`, `374c883e` ("merge: upstream basalt 0.3.x line, without deepseek41"). 패치 동일성은 아님(`git cherry` 605건 전부 '+') → **내용 비교가 유일한 판정 기준** | `git log --format="%h %p %s"` |
| 파일 분류 | ABSENT(upstream 전용) 282 · DIFF(양쪽 상이) 354 · SAME 0 | `/tmp/upclass2.txt` (blob 재분류) |
| **Qwen3.8-Flash-Next = qwen4exp 어댑터** | 식별 체인 실측: GGUF `general.architecture` → `src/model/registry.cpp:48-53` `find_adapter(arch->s)` → 등록은 `src/models/builtin.cpp:9` `register_adapter(qwen4exp::make_adapter())` (`adapter.cpp:20` `arch()`="qwen4exp") → `model_name()`="Qwen3.8-Flash-Next"(`adapter.cpp:40`). CLI 진입: `cli/startup.cpp:41`. upstream `qwen35`=Qwen3.8-27B, `deepseek41`/`hy4flash`는 별개 모델 | 위 파일:행 (2차 검수 ⑤ 반영) |

**원 프롬프트 전제 수정 2건 (GPT 검수 항목 J1/J2):**
1. "Qwen4Exp 전용 기능 제외"는 뒤집힌 전제다. `qwen4exp`가 곧 Qwen3.8-Flash-Next의 실행 경로이므로, qwen4exp 모델 전용 변경이 **최우선 분석 대상**이다. 제외 대상은 `deepseek41`/`hy4flash`/`qwen35`(27B) 전용이다.
2. adamant가 0.3.1/0.3.2를 이미 품었으므로 실질 비교 범위는 **0.3.2 이후 ~ main(v0.5.0 세대)** 다. 다만 어느 파일이 그 머지로 들어왔는지 그래프가 말하지 않아, 모든 판단은 양쪽 현재 코드를 읽어 했다.

## 1. 핵심 결론

**upstream main은 사실상 Blackwell 전용 빌드다** (`CMakeLists.txt:46-49` — sm_120 아니면 `FATAL_ERROR`; PDL은 `pdl.hpp:66-78` `__CUDA_ARCH__>=900` 내부; 신규 커널의 클러스터/DSM/FP4 경로 전부 sm_90+ 전제). 따라서 "최신 CUDA 최적화" 다수는 adamant(sm_89)에 물리적으로 들어올 수 없고, 진짜 포팅 가치는 **하드웨어 무관한 메모리 계획·진단·대기 정책**에 있다.

**GPT 검수 반영 (2026-11-21): P0 없음.** 원 지시의 P0 정의("성능 개선 가능성 높음")와 달리, 실측 장애/성능 근거가 없는 후보에 P0를 주지 않는다(검수 §1). 초기 포팅 후보는 `plan_reserve`(D-1), `exact_slots`(A-3), Windows unbuffered(D-2) 세 가지다. 다만 실제 실행 순서는 Phase별 사전 검증과 의존성을 기준으로 결정한다(§7 — DXGI가 Phase 1-3으로 unbuffered보다 앞). 성공/실패 판정 기준은 §12.

- **보류**: `core::ExpertTier`(~3,600줄, Qwen3.8 미연결), 단일 패스 로더(899줄 리팩터 — **장기 유지보수 부채로 관리**, §8), `kDecMaxT 8→16`(Phase 0 검증 후 판단).
- **제외**: peer GPU 전부(현 하드웨어에서 실질 이득 없음), `gpu_select` 재작성(sm_120 게이트 — **그대로 가져오면 4090가 메인에서 거부된다**; 단 파일 단위 아닌 기능 단위 제외, §8), dense 엔진, cgroup, deepseek41/hy4flash/qwen35 전용.

## 2. 영역 A — Expert Tier / Expert Cache (완료)

### A-1. `core::ExpertTier`/`tier_policy`는 Qwen3.8 미연결 — 포팅 대상 아님

- upstream에서 `ExpertTier`를 참조하는 파일: `hy4flash/*`, `deepseek41/*`, `program/{multi_gpu_plan,gpu_select}`, 테스트뿐. `src/models/qwen4exp/`·`include/basalt/models/qwen4exp/` 참조 **0건** (실측 grep). 기원 커밋 `49c3c75a`는 deepseek41에서 분리해낸 것.
- qwen4exp의 어댑티브 티어는 양쪽 `src/models/qwen4exp/serve/tiers.cpp`·`src/core/expert_cache.cpp`에 그대로 있고, upstream 이력은 merge-base 이후 CUDA 에러 체크 1커밋(`99896e8d`)뿐 — `expert_cache.cpp` diff **0줄**.
- 결론: "ExpertTier 포팅"은 포팅이 아니라 qwen3.8 티어를 갈아치우는 재작성(~3,600줄 신규). **보류**.

### A-2. 교체 정책은 정반대 — P2 (검수: `usage`와 `looks_`는 측정 사건 자체가 달라 직접 비교 불가, 실측 전 알고리즘 변경 보류)

| | adamant (현재) | upstream (`tier_policy.hpp`) |
|---|---|---|
| victim 선정 | 감쇠 사용빈도: `usage` 최소, `*= adapt_decay`, `+1.5f` 마진, `adapt-swaps` 96 절단 (`serve/tiers.cpp`) | LRU 기본(`oldest_slot`), `victim_half_life`>0이면 LFU 하이브리드: `looks_`(히트 포함 lookup 수, `kLookCap=15`) 적은 것 우선·동률 시 stamp 오래된 것, 토큰이 half_life 배수 지날 때 테이블 `>>=1` (`expert_tier.cpp:784`) |
| 카운트 지점 | `decode/expert_dispatch.cpp:107-109` `usage += 1.0f` | `count_look` lookup마다 |
| eviction | 공통 `ExpertCache`는 "EVICTION IS STILL ABSENT" — eviction은 상위 층에만 | 동일 |

- adamant에 `looks_`/`victim_half_life` 심볼 0건. 훅 지점(`expert_dispatch.cpp:107-109`)에 adamant 로컬 변경 없음 → 충돌 표면 없음.
- **주의**: upstream 상수(`kVictimHalfLife=256`, `kAdmitUses=2`, `kClaimsPerRow=128`, `kLayerSlotWeights[41]`)는 전부 RTX 5090(sm_120)/5060 Ti 실측값. adamant 가드는 sm_89/sm_86 (`cuda_target.hpp`) — **상수 그대로 이식 금지**, 재튜닝 필요. 아키텍처 가드 자체는 관련 파일에 0건이라 sm_89에서 도는 것 자체는 문제없음.
- 검증: `tests/core/tier_policy_test.cpp`(509줄, CPU 전용) 그대로 추가 가능. 어댑티브 티어 동작은 `basalt-probe`의 `adapt-*` A/B + `adaptive.md` "Compare `tg`" (단, hit은 메인 카드 VRAM만 세므로 hit 상승=속도 상승 아님).

### A-3. P1 후보 (명시적 용량 보장 옵션일 경우) — exact expert cache 거부 (`exact_slots`)

조건(2차 검수 ②): `--expert-cache`가 "반드시 확보할 용량"이면 시작 거부가 맞고, "최대 허용량"이면 자동 축소가 정상 동작이다. Phase 0-5에서 CLI 의미를 확인하기 전까지 동작 변경을 확정하지 않는다. auto는 어떤 경우에도 축소 허용.

- upstream `include/basalt/core/exact_slots.hpp`(37줄) + `tests/core/exact_slots_test.cpp`(41줄) + `src/models/qwen4exp/load/cache_size.cpp`의 `blobs_within`/`exact_slots_refusal`(커밋 `08964c3b`, qwen4exp 전용): `--expert-cache`를 맞출 수 없을 때 **조용히 trim하지 않고 시작을 거부**.
- adamant 현재: `src/models/qwen4exp/load/cache_size.cpp:243` `if (used + b > cap) break;` — 조용한 trim. adamant 자신의 `expert_cache.hpp` 헤더 주석이 경고한 실패 모드와 같은 형태.
- 24GB 단일 카드 + 기본값 근처 설정에서 가장 자주 맞는 조건. CUDA-free, 충돌 표면 없음, ~90줄.

### A-4. lending/reclaim — 다른 알고리즘 (P2)

- adamant: elastic tail granule, 반납 전 이주 없음(caller가 evict), RAM은 시작 때 complement 고정.
- upstream: `keep_hottest()` hottest 유지 슬롯 이주 후 꼬리 segment unmap, `recall_`/`restore()` hottest 우선 복귀, RAM은 미스마다 LRU 강탈 캐시(`FileReads` 단일 스레드 O_DIRECT → pinned RAM → GPU 2단 전송; 파일→GPU 직접 전송 없음).
- adamant의 `AdviseWorker`는 madvise 힌트만 함. 차이는 실재하나 qwen3.8 연결 이식 지점이 넓음(P2).

### A-5. peer_experts — 제외

`scratch_*`/`fetch_`/`fplan`/`marks_`/`go_` 전부 upstream 전용 심볼이고 `peer_devices`가 비면 실행 경로 자체가 없음. `CAP = MAXT*10→16` 변경 커밋은 "Flash-Next plans unchanged" 명시. 단일 4090에서 가치 0, LoadPlan 결합으로 부분 포팅도 불가.

### A-6. Loader/LoadPlan (영역 D로 이관)

qwen4exp 시작 경로가 upstream에서 `context.reads`/`context.after`/`plan_cache_slots`로 바뀌었음(899줄 + `ram_load` 372줄 diff). 성능 근거 없음 — D에서 판단.

## 3. 영역 B — CUDA Kernel (완료)

현재 확인된 신규 CUDA 커널 중 sm_89에서 Qwen3.8 실행 경로에 연결하여 사용할 수 있는 확실한 성능 개선 후보는 제한적이다. 미결 파일(`sampler.cu`·`iq_kernels.cu`·`native_mmvq.cu`·`head_proxy.cuh`·`mid_chain.cu`)의 내용 비교와 microbenchmark 결과에 따라 추가 포팅 후보가 발생할 수 있다(2차 검수 ④).

**분류 3종 (3차 검수 ① — `gu2.cuh`는 신규 .cu가 아니다):**
1. 신규 `.cu` 커널 20개 중 Qwen3.8 실행 경로에 연결된 것은 **5개**: `gdn_window`→`decode/verify/record_gdn.cpp`, `gdn_prompt`→`prefill/gdn.cpp:27`, `gdn_commit`→`decode/verify/commit`, `route_tail_skip`→`record_layer.cpp:303`, `logprobs`→`decode/verify/sampling.cpp`.
2. 미연결: gqa_attn·dense_ops·window_gemm·nvfp4_planes·router·mhc·q80_screen 등 — `src/dense/`는 **qwen35 전용 신규 엔진**(`dense::` 소비자 = `qwen35/adapter.cpp`뿐, `qwen4exp.cmake` 링크 없음).
3. **`gu2.cuh`는 기존 MoE 커널 경로의 헤더 변경(+44줄)** — 신규 커널이 아니라 위 5개와 별개 분류. 실행 경로 실측(3차 검수 요구): adamant `dec_moe.cu` → `dec_moe_prelude.cuh:5`(`../../../kernels/cuda/iq_kernels.cu` 전체 포함) → `iq_kernels.cu:2993`(`#include "gu2.cuh"`) → `namespace gu2`(gu2.cuh:15). 소비자: **VRAM 상주 디코드 MoE** `dec_moe.cuh:426,447,523`(`gu2::Fmt2/stage_grid/pair_gu`)·`pk_moe.cuh:120,138`(`gu2::stage_grid/pair`), **verify 창 grouped native** `native_gu2_kernel`←`native_expert_grouped`←`decode/verify/record_moe.cpp:49,122,128`. `pk_moe_bench`는 "the MoE half of one decode layer… as the engine launches it"(`pk_moe_bench.cpp:1-2`, `iq_kernels.hpp` 포함) — Qwen3.8 Expert 연산과 같은 커널 계열 측정 확인.
- sm_89 차단 근거: `gdn_window.hpp:10` "Needs thread-block clusters" + `gdn_window.cu:176-184` `__CUDA_ARCH__<900 → DM_REC_NO_CLUSTERS`, 호스트 경로가 cluster 커널을 무조건 참조 → **sm_89 실행 경로 없음** (adamant 등가: `dec_gdn_rec.cu:324` 512스레드 단일 블록). `window_gemm`/`prefill_fp4`는 `CUDA_ARCHITECTURES 120a-real` 고정(block-scaled mma).
- adamant 동등 존재: `route_tail_skip.cu` ↔ `verify_kernels.cu:1300-1347` 알고리즘·launch까지 동일(upstream은 헬퍼 추출 리팩터뿐). `gdn_commit.cu` ↔ adamant가 dyn/seg 변형으로 **슈퍼셋**.
- `logprobs.cu` — adamant에 심볼 0건. kernel 최적화가 아니라 **기능 결핍**(어휘×4B 왕복 감소 설계). 기능 포팅 결정 필요(J4).

| 항목 | 판정 | 근거 |
|---|---|---|
| `gu2.cuh` 델타 44줄 (MoE IQ grouped gate/up, `int2_at` funnel-shift, sm_89 가드 없음) | **P2** | 유일한 실질 kernel 후보. 델타 분리 확인 선행 |
| `gdn_prompt.cu` bf16 스위치 | P2 | qwen4exp는 fp32만 호출 |
| `logprobs.cu` | P2(기능) | 성능 아님, 기능 추가 |
| `kDecMaxT 8→16` | 보류 | sm_89에서 남는 유일한 이득이나 검증 비용 큼 |
| 아키텍처 제한 **확인** 커널(gdn_window·window_gemm·prefill_fp4·dense_ops 등) | 제외 | sm_90+/sm_120a 가드 코드 실측(위) |
| Qwen3.8 미연결 **확인** 커널(gqa_attn·router·mhc·q80_screen·mqa_chunk·silu·philox·row_norm) | 제외 | 소비자 grep 실측(위) |
| sm_89 실행 가능 여부 **미확인**(`mid_chain.cu`·`attn_chain_kernel.cuh`·`attn_chain_bound.cuh`) | **보류** (3차 검수 ② — 미확인 항목은 제외 확정 불가) | §9-6 검증 후 재분류 |

미결: `sampler.cu`(+64)/`iq_kernels.cu`(+10)/`native_mmvq.cu`(adamant가 오히려 +38) 델타 내용, `head_proxy.cuh` 위치 이동의 내용 동일성, `mid_chain.cu` 계열.

## 4. 영역 C — CPU / Offload / Pool (완료)

**최대 사실: pool 코어 알고리즘은 양쪽이 사실상 동일.** adamant는 이미 upstream `553e9290`(꼬리 파트 1/4)·`4e684126`(down prefetch)를 내용상 품고 있고, `pool.hpp/cpp` 차이는 3 hunks뿐. "pool 재작성"급 포팅은 존재하지 않음. `src/kernels/cpu`에서 내용 상이 파일 10개뿐이며 IQ/NVFP4 커널 다수는 바이트 동일.

Qwen3.8 연결: CPU offload는 native pack(UD-IQ*/NVFP4) 전용 — `expert_dispatch.cpp:291 run_split_multi_native`(verify 윈도우 한정, 단일 토큰 경로는 native 거부 `:70-72`), `prefill/cpu_experts.cpp:128`(GPU와 청크 오버랩), `verify/execution.cpp:302`(워밍). pool 생성 지점(`resident_plan.cpp:280`)은 양쪽 동일.

| # | 항목 | 판정 | 근거 |
|---|---|---|---|
| C1 | park 대기 정책: upstream은 pause 상시 + 50µs에 1회 양보(`febc72de`: 연이은 시스템 콜이 전력/클럭을 빼앗음), adamant는 양보 진입 후 **매 체크** `yield()`(실측 비교: adamant `pool.cpp:141-150` vs upstream `:156-172`) | P2 | 벤치 근거는 DeepSeek/prose 개선, **Qwen3.8 NVFP4는 중립**(8.06→7.96) |
| C2 | `kTasksPerThreadAvx2=8` (upstream `pool.cpp:427` `cpu_avx512_ok() ? 12 : 8`, adamant 12 고정) | P2 (검수) | AVX2-only CPU 오프로드 사용 시. 수치 없음 (c) |
| C3 | `auto_pool_workers` 이동 | 제외 | adamant `program/auto_plan.cpp:21-35`에 동일 로직 |
| C4 | `core/spin_wait.hpp` + qwen3.8 디코드 spin 3곳 통합 | **P2** (검수 통일) | 신규 헤더(ABSENT), 수치 없음 (c). yield 자체가 짧은 GPU 대기에서 역효과 가능 — tok/s·context switch 동시 측정 |
| C5 | Linux hybrid PMU sizing | 제외 | Linux 전용 + hy4flash |
| C6 | `cpu_l3_groups` | P2 | 토폴로지 분할, 근거 약함 |
| C7 | IQ gather 커널 (`iq_avx2_rows.inc` 변경) | P2 | AMD 게더 손실 실측(`d6cf1f78` IQ2_S 9.59 vs 7.29 GB/s)은 **AMD 한정** — Intel이면 가치 ↓. MSVC 신규 intrinsic 2종뿐이라 요건 상승 없음 |
| C8 | NVFP4 swiglu_limit | 제외 | qwen4exp는 limit 0 |
| C9 | `prefill::cpu_take` | 보류 | `prefill/cpu_split.hpp` ABSENT, hy4flash prefill용 |
| C10 | `core::ExpertTier`의 `start_cpu/finish_cpu` 오버랩 | 보류 | A-1과 동일 판단 (qwen4exp 미사용, 양쪽 동일) |

주의: 빌더 간 greedy 토큰이 갈린다(`docs/platforms.md:107-113`, expert rows 78%) — CPU 커널 변경의 "bitwise equal" 주장은 동일 컴파일러 내 한정.

## 5. 영역 D — Loader / Memory / Runtime (완료)

방법: 브랜드 문자열 정규화 후 내용 diff. 상세 아티팩트 `/tmp/upstream-D.md`(§0~3.2) + 스카우트 전달분(§3.3~7).

### D-1. P1 — `plan_reserve()` (RAM 예약 + 엔진 사후 사용분 2 GiB) (검수: 2 GiB 상수의 환경 적합성·DXGI 예산과 중복 예약 여부 실측 전 P0 아님)

- upstream `ram_load.hpp`: `kPostPlanHostBytes = 2 GiB`, `plan_reserve(r)=r+2GiB` — RAM 티어 사이징 **후** 엔진이 잡는 호스트 메모리(CUDA 그래프 호스트분, 첫 요청 버퍼)를 예약 옆에 비워둠. 근거 #339("a 64 GB box started at or below its guard"). adamant grep 0건.
- adamant 호출 3곳(`cache_fill.cpp:88`, `resident_plan.cpp:241`, `resident_load.cpp:53`)을 `plan_reserve(...)`로 감싸는 ~4줄. `ram_tier_room` 자체는 양쪽 동일.
- 검증: `tests/core/file_expert_source_test.cpp::test_plan_reserve` 이식 + `RAM floor … GiB` 로그 2 GiB 이동 확인.

### D-2. P1 — Windows unbuffered 읽기

검수 경고: `FILE_FLAG_NO_BUFFERING`은 오프셋/길이/버퍼 정렬, 마지막 블록, OVERLAPPED 이벤트 수명, 동시 읽기, EOF 부분 읽기를 전부 보장해야 하는 작업 — `return -1` 제거로 끝나지 않는다. Cold/Warm 로딩 시간·Peak RAM·Windows commit·파일 캐시 영향을 분리 벤치.

- upstream `platform/file.cpp`: `open_unbuffered`가 `FILE_FLAG_NO_BUFFERING|OVERLAPPED` 실핸들 반환 + 읽기마다 이벤트/절대오프셋 overlapped(`77ec04e5`). adamant는 같은 함수가 **`return -1`**(주석: "reads the same bytes through its mapping") → Windows 로드가 전부 파일 캐시 경유, 70 GB급 pack에서 캐시와 RAM 티어가 RAM 경쟁.
- 소비자(`read_blobs`, `RamLoad`, adamant 전용 `DirectUpload`)는 이미 `-1` 폴백 구조 — 반환값만 살아나면 경로가 켜짐. 어댑터 변경 없음. 어댑트 시 `direct_upload.cpp`의 폴백 분기가 dead가 됨(동작은 정상).
- 비용 ~60줄(file.cpp +47−23, file.hpp, direct_file +6). Windows 실측 검증(냉장 캐시 2회 로드 시간).

### D-3. P2 — `core/spin_wait.hpp` (C4와 동일 항목, 우선순위 통일됨)

- upstream: spin 대기 공통 헤더(yield 도입). adamant 디코드 3곳은 raw `cpu_relax()` 루프(yield 없음, 예 `decode/mtp/draft.cpp:96-102`). 스레드 과점 시 GPU 대기 스레드가 코어를 잡아먹는 구조. 검증: `--spec` 디코드 tok/s 3회.

### D-4. P1(DXGI 예산) / P2(host VMM) — pin 예산 (Windows) — 검수 지시로 분리

검수 지시: 위험도가 달라 별도 항목·별도 커밋. DXGI 예산 조회는 휴리스틱 대체(P1), host VMM은 등록/매핑 구조 변경(P2). iGPU+4090 시스템에서 **LUID 선택이 핵심 검증점** — 잘못된 어댑터의 NON_LOCAL 예산 사용 시 역효과.

- upstream `pin_budget(..., luid, node_mask, shared_mapping)`: `IDXGIAdapter3::QueryVideoMemoryInfo(NON_LOCAL)`로 어댑터별 실제 예산 읽고 5% 또는 1 GiB 유보. adamant 휴리스틱은 `RAM/2 − 8 GiB` 고정 — 하이브리드 iGPU·타 프로세스 예약 시 틀림. host VMM(`vmm.cpp` +78줄, HOST_NUMA 2 GiB 조각)은 같은 페이지를 어댑터마다 등록하지 않아 WDDM 등록 한도 회피.
- 2단계 반영: (1) DXGI 예산, (2) host VMM + bounded registration. `dxgi.lib` 링크 추가.

### D-5. P1 후보 / 실사용 lend·reclaim 검증 후 확정 — `budget_lend_room` (3차 검수 ③ 통일)

- upstream `expert_source.cpp`: `budget_lend_room(budget, complement)` + `lend_cap` — 예산이 expert+자유 place(spares)와 비교, 회귀 #342/#366 방지. adamant는 expert와만 비교하고 순서도 다름. 함수 단위만 이식 가능(단일 패스와 부분 분리).

### D-6. P2 — Windows 크래시 핸들러 (진단) (검수: 처리량 개선 아님 — 단 복잡한 변경 전 진단 환경으로는 합리적, Phase 4)

3차 검수 ⑤: 포팅 대상은 `install_crash_handler()`뿐. `process_memory()`는 **adamant에 이미 존재**(`src/platform/system.cpp`, 소비자 `serve/protocol.cpp`·`serve/request_finish.cpp`) — 제목에서 제거, 이식 불필요.

- upstream `platform/process.cpp`: `install_crash_handler()`(SEH + set_terminate + alt-stack) → `basalt crash: <종류> (code) at <addr> in <progress().where>` + 백트레이스. 의존 `core::progress()`는 adamant에 동일 존재 → 클린 이식, 호출 1줄. Windows에서 죽는 엔진의 전제 조건.

### D-7. P2 / 보류 / 제외

- P2: checkpoint `HostPin`(현재 adamant pageable → 드라이버 스테이징), peer access 활성화 블록, cgroup 인식(Windows 데드코드).
  peer access 표현 통일(3차 검수 ④): **단일 GPU 환경에서는 실질적인 이점이 없을 것으로 예상한다. 다만 단일 GPU 경로에 미치는 초기화 및 실행 부작용은 별도로 확인한다** — 미확인 상태의 "무해" 단정 금지.
- **범위 밖 명시(3차 검수 ③)**: C6 `cpu_l3_groups`, C7 IQ gather 커널, checkpoint `HostPin`은 현재 Phase 0~4 실행 계획에서 제외한다. CPU offload 병목이 확인되면 별도 검증 대상으로 재등록한다.
- 보류: 단일 패스 로더 `core::LoadPlan`+`place_start`(899줄 + `LoadProgress` 전면 교체 + `adapter.hpp::start()` 재구성 — adamant이 같은 파일들에 `--ple-gguf`/`direct_upload`/오류문구 변경으로 전 파일 충돌. §D-2만 분리 이식하면 대부분 이득 선취), elastic KV tail RAM 유지(upstream이 결론을 뒤집은 항목 — adamant 문서 "no RAM copy until then"과 상반. 의도 확인 필요).
- 제외: `gpu_select` 재작성(sm_120 메인 게이트 — **4090 거부**, `cuda_target.hpp` 유지 필수), ExpertTier reclaim(`2ee5bb38` — 클래스 없음), RAM 워치독(양쪽 동일, adamant `BRD error:` 접두 유지), 런타임 설정 프로토콜(`VRAM`/`SLEEP`/`WAKE` 양쪽 문자 그대로 동일).

## 6. 제외 확정 목록 (원 프롬프트 §5 대비 실측 보정)

| 항목 | 판정 | 근거 |
|---|---|---|
| hy4flash 전용 (91커밋) | 제외 | qwen3.8 경로 참조 없음 (A-1 grep 방식 동일) |
| deepseek41 전용 (28커밋) | 제외 | adamant가 의도적으로 미수용(`without deepseek41` 머지 2건) |
| qwen35=Qwen3.8-27B | 저우선 | 현 사용 모델 아님 |
| 멀티 GPU/peer | 제외 | A-5 |
| **qwen4exp 전용** | **재분류: 최우선** | = Qwen3.8-Flash-Next (전제 수정 J1) |

## 7. 포팅 권장 순서 (GPT 검수 반영 — Phase 0~4)

원칙(검수): 측정 결과가 없는 항목은 포팅 우선순위로 올리지 않는다. 각 항목 독립 커밋·독립 검증. DXGI와 host VMM을 하나의 커밋으로 묶지 않는다.

**Phase 0 — 포팅 전 검증 (코드 변경 없음)**

| 순 | 항목 | 확인할 것 |
|---|---|---|
| 0-1 | `gu2.cuh` +44 | 4090 microbench(`pk_moe_bench`)으로 이득 유무 |
| 0-2 | `kDecMaxT 8→16` | 디코드 성능·VRAM 영향 |
| 0-3 | `logprobs` | OpenAI 호환 API에서 요구되는 기능인지(요구 시 P1 승격) |
| 0-4 | `sampler.cu`+64 / `iq_kernels.cu`+10 / `native_mmvq.cu` / `head_proxy.cuh` / `mid_chain` | 미결 diff 분류 완료 |
| 0-5 | `exact_slots` | `--expert-cache`의 CLI 의미(정확 지정 vs 최대치)와 auto 기본 동작 |

**Phase 1 — 낮은 위험도 메모리/동작 개선**

| 순 | 항목 | 우선 | 변경 파일 | 검증 |
|---|---|---|---|---|
| 1 | `plan_reserve` (D-1) | P1 | `ram_load.hpp` + 호출 3래핑 | Peak RAM·Commit·OOM·RAM 티어 크기, `test_plan_reserve` 이식 |
| 2 | `exact_slots` (A-3) | P1 후보 — Phase 0-5 통과 시 확정 | `exact_slots.hpp`(신규), `cache_size.cpp`, 테스트 | 요청/확보 슬롯, 시작 성공·실패 — auto는 축소 허용 |
| 3 | DXGI pin 예산 (D-4a) | P1 | `platform/memory.*` | 실제 GPU LUID·예산·pin 성공률 (iGPU 혼재 시 LUID 선택) |

**Phase 2 — Windows 로딩/메모리 구조**

| 순 | 항목 | 우선 | 검증 |
|---|---|---|---|
| 4 | Windows unbuffered (D-2) | P1 | Cold/Warm 로딩·Peak RAM·Windows commit·파일 캐시·읽기 정확성(정렬/EOF/동시) |
| 5 | `budget_lend_room` (D-5) | P1/P2 | resident hit·reclaim·reload bytes — 실제 lend/reclaim 상황 확인 |
| 6 | host VMM + bounded registration (D-4b) | P2 | `--resident-pin` 시작 로그, 등록 실패 경로 |

**Phase 3 — CPU/디코드 (전부 실측 후 승격)**: 7 `spin_wait`(P2) · 8 `kTasksPerThreadAvx2`(P2) · 9 tier_policy victim(P2, 훅 `expert_dispatch.cpp:107-109`, 상수 재튜닝 필수) · 10 pool park 정책(P2). 지표: tok/s·CPU 사용률·context switch·P95, 일반/`--spec` 분리.

**Phase 4 — 진단/기능**: 11 Windows 크래시 핸들러(P2, `process.cpp`+`cli/startup.cpp` 1줄, 의존 없음) · 12 `logprobs`(요구 시 P1) · 13 단일 패스 로더(별도 구조 개선 프로젝트, §8).

## 8. 포팅하지 말아야 할 변경

| 항목 | 이유 | 검수 보정 |
|---|---|---|
| `gpu_select` 재작성 | 메인 게이트가 sm_120 — 그대로면 **4090가 "no sm_120 GPU visible"로 거부**. `cuda_target.hpp` 유지 | **파일 단위 아닌 기능 단위 제외**: 아키텍처 게이트·4090 선택은 adamant 유지, 아키텍처 무관 버그 수정은 별도 검토 |
| `core::ExpertTier` 런타임 클래스/`elastic_array`/`expert_map` | Qwen3.8 미연결(참조: hy4flash/deepseek41뿐). 포팅이 아니라 qwen3.8 티어 재작성 | 구분: ExpertTier 전체 구현=제외, `tier_policy` 자료구조 전체=제외, **victim 선정 알고리즘만**은 독립 적용 가능 여부 별도 평가(A-2, P2) |
| 단일 패스 로더(`core::Loader`/`LoadPlan`/`LoadProgress` 교체) | 899줄+ 전면 재구성, 전 파일 충돌, 현재 결함 없음. D-2로 이득 선취 | **완전 제외 아님 — 장기 유지보수 부채로 관리.** 재검토 트리거: ①upstream 로더 기능을 두 번 이상 별도 어댑트 ②동일 로딩 오류가 양쪽에서 반복 수정 ③`direct_upload` vs `context.reads` 성능차 확대 ④로딩 메모리/재현성에서 명확한 차이. 구조 차이 문서는 유지 |
| 신규 CUDA kernel (gqa_attn·dense_ops·window_gemm·nvfp4_planes·router·mhc·q80_screen·gdn_window 등) | sm_90+/sm_120a 전용 가드 실측(§3) 또는 qwen35/hy4flash/ds41 전용 | **조건부 제외, 4분류**: ①sm_120 전용 컴파일 ②sm_90+ 필요 ③sm_89 실행 가능·미연결 ④sm_89 실행 가능·연결(`gu2.cuh` 델타가 여기 — Blackwell 분류로 뭉뚱그려 제외 금지). 검증 순서: 컴파일→경로 연결→결과 정확→성능 |
| peer GPU/멀티카드 전부(`peer_experts`, peer access, `tiers_holding`) | 단일 4090에서 실행 경로 자체가 없음 | 표현 보정: "무의미"가 아니라 "현 하드웨어 구성에서 실질 이득 없음". peer access의 단일 GPU 경로 부작용 여부만 확인 |
| cgroup `available_memory()` | Linux 전용 — Windows 타깃에서 데드코드 | 조건부: 컨테이너 배포 준비 시 P2 |
| `serve/` 83커밋(Python) | 엔진 성능 범위 밖 (J2) | **완전 제외 아님 — 별도 관리**: HTTP/OpenAI API 호환성·스트리밍·batching·스케줄링·설정 전달은 별도 분석 라운드(서버 처리량과 엔진 처리량은 별개가 아님). Python 내부 정리·개발도구만 제외 |
| deepseek41/hy4flash/qwen35 모델 코드 | 현 사용 모델 아님 + adamant 미수용 원칙 | 향후 모델 확장 시 재평가 |

## 9. 추가 확인이 필요한 사항 (코드만으로 결론 불가)

1. `gu2.cuh` +44줄 델타가 sm_89 빌드에서 이득인지 — 델타 분리 후 microbench(`pk_moe_bench`).
2. `sampler.cu`(+64)·`iq_kernels.cu`(+10)·`native_mmvq.cu`(adamant +38 우위)·`head_proxy.cuh` 위치 이동의 내용 동일성.
3. elastic KV tail RAM 유지(D-7 보류): upstream이 "no RAM copy until then" 결론을 뒤집은 의도 — 실사용 `--max-context > 32768` 워크로드 재현 테스트.
4. 항목별 검증 구분(2차 검수 ③ — 기능과 성능 혼용 금지): `spin_wait` = 처리량 및 CPU 점유 실측 · `kTasksPerThreadAvx2` = CPU offload 처리량 실측 · `logprobs` = **API 요구사항 및 기능 호환성 검증**(성능 아님, 기능 결핍 분류).
5. `exact_slots`의 거부 기본값: 자동(`auto`) 사용자가 대부분이면 체감 효과 ↓ — 실사용 플래그 통계 확인.
6. `mid_chain.cu`/`attn_chain_*`(adamant 없음, `gdn_window` 짝) — sm_90+ 전제 여부 미확인.

**검증 방법론 (GPT 검수 §8 — 3자 비교 불가)**: upstream main은 CMake 아키텍처 게이트(sm_120) 때문에 4090에서 동일 조건 빌드가 불가능 → "세 저장소 성능 대결"은 성립하지 않는다. 구성: adamant HEAD = 기준 성능, adamant+개별 패치 = 실측 대상, basalt main·d2480d1 = 소스/테스트 참조. 공통 조건 고정: 동일 CUDA·MSVC·모델·양자화·컨텍스트 길이·생성 파라미터, Cold/Warm 분리, 5회 반복 중앙값, 로딩 테스트와 디코드 테스트 분리(로딩 개선이 디코드에 무영향이거나, 메모리 배치가 바뀌어 디코드에 영향 줄 수 있음).

## 10. GPT 검수 질문

- J1(전제): `qwen4exp` = Qwen3.8-Flash-Next(양쪽 `adapter.cpp` 실측). 원 지시의 "Qwen4Exp 전용 제외"를 "qwen4exp 전용 포함(오히려 최우선)"으로 뒤집었다. 동의하는가.
- J2(범위): `serve/`(83커밋, Python 서버)는 엔진 성능 범위 밖으로 제외. 동의하는가.
- J3(판정): ExpertTier 보류(미연결) · `exact_slots` P0 vs P1(스카우트 두 명 판정 갈림: A는 P0, D는 P1) · `tier_policy` victim 정책 P1(단 upstream 상수는 sm_120 실측값이라 재튜닝 필수) — 각각 동의/수정 제안.
- J4(우선순위): §7 순서 1~8의 순서와 누락(예: `logprobs` 기능 포팅을 P0/P1로 승격할 가치) 판단.
- J5(위험): §8 제외 목록에 누락된 위험 항목이 있는가 — 특히 단일 패스 로더 보류가 6개월 뒤 유지보수에 미룰 비용.

## 11. 검수 결과 기록 (라운드 1, 2026-11-21, 답 51.4KB 전문: `~/.chatgpt-bridge/projects/p-2a492908fc76/transcripts/porting-plan-review.md`)

GPT 검수 판정 요약 — **전체 방향 타당, P0 전부 강등, 구조 3건 변경**:

| 질문 | 판정 | 반영 |
|---|---|---|
| J1 qwen4exp | 동의 (단 `model_name()` alone 아닌 호출 경로 기준 — 이미 충족) | §0 유지 |
| J2 serve | 조건부 동의 — 전체 제외 금지, API/배칭/스케줄링 별도 분석 | §8 반영 |
| J3 ExpertTier | 동의(보류) — 문서상 "tier_policy 전체 제외"와 "victim 정책 이식" 혼동 금지 | §8 구분 반영 |
| J3 exact_slots | **P1** (auto vs 명시 지정 구분) | §A-3/§7 반영 |
| J3 tier_policy | **P2** (usage/looks_ 통계 정의 상이, 상수 sm_120 튜닝) | §A-2/§7 반영 |
| J4 순서 | P0 없음 — Phase 0(검증 전용)~4 재편, DXGI/host VMM 분리 | §7 전면 교체 |
| J5 로더 | 보류 동의 + 유지보수 부채 관리(재검토 트리거 4건) | §8 반영 |

검수가 지적한 문서 결함(반영 완료): spin_wait 우선순위 3곳 불일치(P0/P1/P0→P2 통일), 신규 kernel 제외 범위 과대(4분류), "peer 무의미" 표현.
검수가 직접 저장소를 재검증한 것은 아님(제출 근거 기반 논리 검수) — 자체 선언대로이며, 그래서 §9의 실측 목록이 유효.

## 12. 포팅 성공/실패 판정 기준 (2차 검수 추가 항목)

원칙: **성능이 개선되지 않은 성능-목표 포팅은 기본적으로 채택하지 않는다.** 단, 정확성·메모리 안정성-목표 항목(아래 표의 "안정성" 열)은 성능이 소폭 감소해도 별도 판단한다 — 최적화와 안정성 개선은 평가 기준이 다르다.

| 항목 | 목표 | 성공 판정 | 실패 판정 | 반드시 측정(3차 검수 §3) |
|---|---|---|---|---|
| `plan_reserve` | 안정성 | 메모리 안정성 개선 + 기존 실행 정상 | RAM 티어가 과도하게 감소해 expert hit/속도 저하 | 변경 전후 RAM 티어 크기 + **의도로 만든 메모리 압박 조건 재현**(§12-가) |
| `exact_slots` | 예측 가능성 | 명시적 설정의 정확한 용량 보장 | auto 설정의 불필요한 시작 거부 | 요청 슬롯 수 = 실제 확보 슬롯 수 일치 |
| Windows unbuffered | 안정성+로딩 | 읽기 정확성 + 메모리 경쟁 감소 | 정렬 오류, 데이터 손상, 로딩 회귀 | **비정렬 offset·마지막 partial block·동시 읽기·EOF**(§12-나) |
| DXGI pin 예산 | 안정성 | 올바른 GPU 예산 반영 | 잘못된 LUID 선택(iGPU 예산 사용) | **CUDA Device↔DXGI Adapter LUID 일치 + 조회 실패 시 fallback**(§12-다) |
| `spin_wait` | 성능 | CPU 점유 감소 + 디코드 성능 유지 | tok/s 또는 P95 악화 | 일반 디코드와 speculative decode **분리 측정** |
| `tier_policy` victim | 성능 | reload 감소 + 실제 처리량(tok/s) 개선 | 캐시 hit만 증가하고 tok/s 개선 없음 | **동일 Expert 요청 trace 재생** 후 비교 |
| `gu2.cuh` | 성능 | microbench + 엔드투엔드 tok/s 개선 | 이득 없음 | **커널 결과 정확성(비트 동일 parity) + 경계 조건** |
| `kDecMaxT 8→16` | 성능 | tok/s 개선 | VRAM/성능 회귀 | **VRAM 증가량, 레지스터 사용량, tok/s, P95** |

**세 가지 강조 (3차 검수):**
- (가) `plan_reserve`: 기존 코드에서 guard 문제가 재현되지 않으면 "문제 없음"만으로는 효과 입증 불가 — RAM을 의도로 압박하는 조건(작은 `--ram-reserve-mib` + 큰 `--resident-budget-gib`)을 만들어 전후 비교.
- (나) unbuffered: 일반 파일 읽기 테스트로는 부족. 버퍼 주소·파일 offset·읽기 길이 정렬, 마지막 블록, **비동기 읽기 완료 시점의 버퍼 및 OVERLAPPED 이벤트 수명**을 명시적으로 검증.
- (다) DXGI: 대상 시스템은 iGPU+4090 혼재 — LUID가 실제 CUDA 장치와 일치하는지 반드시 검증. 잘못된 어댑터의 NON_LOCAL 예산은 기존 휴리스틱보다 나쁠 수 있다.

측정 규율(1차 검수 §8 유지): adamant HEAD vs adamant+패치, 조건 고정(CUDA·MSVC·모델·양자화·컨텍스트·파라미터), Cold/Warm 분리, 5회 중앙값, 로딩/디코드 테스트 분리.

## 13. 2차 검수 기록 (2026-11-21, 사용자 전달)

판정: **라운드 1 기준 문서로 확정** (방법론 9, 실행경로 9, 아키텍처 9, 선별 9, 위험 9, 우선순위 일관성 8, 실측 계획 8, 유지보수 9). "문서 자체를 반복 검토할 필요 없음, 실제 소스 적용 단계 아님, **Phase 0부터 시작**" — 특히 `gu2.cuh`·`kDecMaxT 8→16`을 4090 실측 1순위(유일한 디코드 성능 직접 후보).
반영 6건: ①§1 표현(1순위 3종 ≠ 실행 순서) ②A-3 조건부 P1 ③§9-4 기능/성능 분리 ④§3 결론 범위 제한 ⑤§0 어댑터 식별 체인(registry.cpp:48-53→builtin.cpp:9) ⑥§12 성공 판정 기준.

## 14. 3차 검수 기록 (2026-11-21, 사용자 전달)

판정: **승인** (실행경로 9.5, 위험 9.5, 우선순위 일관성 9, 실측 계획 9, 유지보수 9.5). "문서 방향 변경·후보 재검토 불필요, **이제 문서 검토보다 Phase 0 실험이 중요**, 첫 작업 `gu2.cuh` 권장(격리 측정 가능+변경 범위 작음+디코드 성능 직접 후보) — 진행 순서: 델타 분리 → 정확성 테스트 → microbench → Qwen3.8 통합 벤치."
반영 5건+§12 보강: ①§3 분류 3종화 + gu2 실행 경로 실측(prelude→iq_kernels→gu2.cuh, 소비자 dec_moe/pk_moe/record_moe) ②미확인 커널(mid_chain 계열) 제외→보류 ③D-5 라벨 통일 + C6/C7/HostPin 범위 밖 명시 ④peer access 표현 통일 ⑤D-6에서 process_memory 제거(adamant 기재실측).

## 15. 4차 의견과 후속 문서 (2026-11-21)

GPT TOP 4: 1 `gu2.cuh`+44 / 2 `kDecMaxT` 8→16 / 3 Windows unbuffered / 4 `plan_reserve`. 실행 순서: gu2 → kDecMaxT → plan_reserve (unbuffered 대기). 하네스는 baseline 측정 + 빌드·테스트 자동화만 만들고 바로 gu2 실험.
gu2 전제 조건("양자화 경로 확인") 실측 완료: `gu2.cuh:1-2` 적용 대상 = IQ 계열(IQ1_S~IQ4_S, Q2_0, IQ4_XS, `n_embd` 2560/5120), **NVFP4는 `dec_moe.cuh:545` 주석대로 gu2 row pair 없음** → 실험 팩은 UD-IQ3_XXS/UD-IQ4_XS.
→ 실행 문서: **[upstream-apply-first.md](upstream-apply-first.md)** (우선 적용 — 실험 절차·판정·하네스 규칙).
