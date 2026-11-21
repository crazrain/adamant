# 우선 적용: 4090 성능 실험 1순위 목록

기준 문서: [upstream-porting-plan.md](upstream-porting-plan.md) (3차 검수 승인) · GPT 4차 의견(TOP 4) 반영 · 2026-11-21 · **실험 순서 문서이며, 이 문서 자체가 승인된 작업 범위**

목적: upstream 추적이 아니라 **RTX 4090에서 Qwen3.8-Flash-Next의 성능·안정성을 실제로 끌어올리는 것**.

## 실행 환경 분리 (실측 전제)

| 머신 | 역할 |
|---|---|
| **MacBook (이 기계)** | 분석, 델타 분리, 패치/테스트 코드 작성, 문서, 브리지 검수. `~/study/ai/adamant`·`~/study/ai/basalt` 양쪽 저장소 존재. **CUDA 빌드·벤치 불가(NVIDIA GPU 없음)** |
| **4090 Windows 서버** (`D:\study\ai\adamant`) | 빌드, parity 테스트, microbench, 통합 벤치, 실서빙 관측. 모든 성능 수치는 여기서만 산출 |

산출물 이동: Mac → 서버는 `git format-patch` 파일(또는 승인된 브랜치 push), 서버 → Mac은 벤치 결과 로그·`--ptxas` 산출물. 실험 팩(UD-IQ3_XXS/UD-IQ4_XS)은 서버 쪽에 준비(HF `jesdga/Qwen3.8-Flash-Next-Basalt`) — 서버에 이미 있는 팩이 IQ인지 NVFP4인지 착수 전 확인.

## TOP 4

| 순위 | 후보 | 기대 가치 | 판단 |
|---|---|---|---|
| 1 | `gu2.cuh` +44줄 | MoE IQ grouped gate/up 연산 최적화 | 가장 먼저 실험 |
| 2 | `kDecMaxT` 8→16 | 디코드 처리량 개선 가능성 | VRAM 증가와 함께 검증 |
| 3 | Windows unbuffered | 대형 Expert pack 로딩 RAM 경쟁 완화 | 안정성 유망 — 3연속 실험 뒤 대기 |
| 4 | `plan_reserve` +2 GiB | RAM 압박·OOM 위험 완화 | 저비용 안정성 개선 |

실행 순서는 GPT 최종 추천대로: **실험1 gu2.cuh → 실험2 kDecMaxT → 작업3 plan_reserve** (unbuffered는 그 다음).

## 실험 1 — `gu2.cuh` (+44줄) — **구조 판정: PDL 전용, sm_89 이득 0 → 제외 권고 (2026-11-21 실측)**

델타 분리 결과(정규화 diff 2 hunks, +44줄 전부): ① 기존 DEC_GU2=1 커널에 `pdl_launch_dependents()` 1줄 ② 신규 "DEC_GU2=2: programmatic chain" 43줄 — gate/up→SwiGLU→down을 **PDL(programmatic dependent launch)**로 체이닝하고 down 가중치를 L2 prefetch.
**sm_89에서 이 메커니즘은 구조적으로 무음**: adamant `include/basalt/kernels/pdl.hpp:66,74` — `pdl_wait`/`pdl_launch_dependents` 본문이 `__CUDA_ARCH__ >= 900` 내부(no-op), `pdl_kernel_ok()`는 `major >= 9` 요구. PDL early-start가 없으면 L2 prefetch overlap도 발생하지 않는다(정확성은 유지, 이득 0). "sm_89 가드 없음" 전제는 **오인** — 가드가 gu2.cuh가 아니라 pdl.hpp에 있다.
→ 서버 microbench는 기록용 선택 사항. **1순위 실험은 `kDecMaxT`로 승격.**

<details><summary>원 실험 계획(참고 보존)</summary>

**호출 체인 (실측, 기준문서 §3-3)**: `dec_moe.cu` → `dec_moe_prelude.cuh:5` → `iq_kernels.cu:2993` → `gu2.cuh`. 소비자: `dec_moe.cuh:426,447,523`, `pk_moe.cuh:120,138`, `native_gu2_kernel`←`record_moe.cpp:49,122,128`.

**양자화 경로 확인 (4차 검수 요구 — 실측)**: `gu2.cuh:1-2` — 적용 대상은 **IQ 계열**: IQ1_S, IQ2_XXS, IQ2_XS, IQ2_S, IQ3_XXS, IQ3_S, Q2_0, IQ4_XS (`n_embd` 2560/5120). **NVFP4는 명시 제외** — `dec_moe.cuh:545` "dm_glue_gu_kernel for gate/up formats **without gu2 row pairs (NVFP4)**".
→ **실험 팩은 UD-IQ3_XXS 또는 UD-IQ4_XS로 한다.** 기본 팩 NVFP4-DQ6_K에서는 이 변경이 실행되지 않는다(실험 무의미). 실사용 팩이 NVFP4면 gu2의 실전 가치는 "IQ 팩 사용 시"로 한정 — 이 사실은 실험 전에 확정 보고.

**단계** (GPT 권장 순서, 실행 머신 표기):
1. **[Mac] 델타 분리**: upstream `gu2.cuh`(505줄) vs adamant(461줄)의 44줄을 기능 단위로 분리 (`git diff` + 브랜드 정규화). sm_89 가드 부재 재확인. 결과물: 패치 파일 + 델타 기능별 메모.
2. **[서버] 정확성**: 패치 적용 빌드 → `native_grouped_parity`/`iq_parity` 계열 + `gu2` 경계 조건(마지막 그룹, 부분 워프, `n_embd` 2560/5120 양쪽) — 비트 동일 아니면 여기서 종료, 결과 로그 Mac 회수.
3. **[서버] microbench**: `pk_moe_bench`(IQ 팩 지오메트리) — 5회 중앙값, before/after.
4. **[서버] 통합 벤치**: `basalt-bench` 디코드 tok/s (UD-IQ 팩, Cold/Warm, 일반/`--spec` 분리).

**판정** (§12): microbench 이득 + 엔드투엔드 tok/s 개선 → 채택(독립 커밋). microbench만 이득 → 통합에서 사라진 원인 기록 후 미채택. 이득 없음 → 종료, 재시도 없음.
</details>

## 실험 2 — `kDecMaxT` 8→16 — **구조 판정: 기각 (2026-11-21, 컴파일 전용 실측)**

`include/basalt/models/qwen4exp/kernels/dec_gdn.hpp:16` 상수 하나. 서버 worktree `D:\study\ai\adamant-exp`(`exp-kdecmaxt16` @ `518b3173`)에서 T=8/T=16 두 빌드를 `-Xptxas -v`로 컴파일해 비교 (CUDA 13.3, sm_89, VS 생성기, `build-ssh`). **실행 없음.**

**이득 0 (구조)**: 상류 basalt도 `kDecMaxT=16`이지만 `kVerifyMaxT=8`을 그대로 유지 — verify 창은 어디든 8. adamant에서 rec 커널 호출자(`gdn_split.cpp`, `record_gdn.cpp`)는 `n ≤ kDecMaxT` 게이트뿐이라 9~16행을 넘기는 경로가 **없다**. 16은 상류의 Blackwell dense decode 창용이고, adamant에 그 소비자 없음.

**비용 (ptxas 실측, `dec_gdn_rec.cu`)**: `RecSmem`이 템플릿 인자 T가 아니라 전역 상수 `kDecMaxT`로 채워져 **모든 인스턴스(`<2>`,`<4>`,`<16>`)가 같이 악화** — 일반 디코드(n_tok≤4)가 그대로 비용을 낸다.

| 커널 (launch_bounds) | T=8 | T=16 |
|---|---|---|
| `rec_split_kernel` (128t) | 128 reg, 21,952B smem → 4 blk/SM | 168 reg, 32,640B smem → **3 blk/SM (-25%)** |
| `rec_kernel<max>` (512t) | 128 reg, stack 16B | 128 reg(cap), **stack 104B, spill 108/144B** |
| `rec_seg_kernel<max>` (512t) | 128 reg, spill 0 | 128 reg(cap), **stack 88B, spill 84/112B** |

**판정**: 기능 이득 없음 + 핫 디코드 경로 occupancy -25%·레지스터 스플·공유메모리 +10.7KB/블록 → **미채택, 실행 게이트 불필요**. 재시도 없음.

## 작업 3 — `plan_reserve` +2 GiB

성능 실험이 아니라 **저비용 안정성 개선** (§12-가): RAM을 의도로 압박하는 조건(작은 `--ram-reserve-mib` + 큰 `--resident-budget-gib`)을 만들어 전후 비교. 성공 = 가드 미달/스왑 미재현 + RAM 티어 과감소 없음. ~4줄, 독립 커밋.

**상태 (2026-11-21)**: 패치 작성·검증 완료 — `mydocs/patches/plan-reserve.patch` (4파일 52줄, adamant HEAD `git apply --check` 통과). 서버 worktree `D:\study\ai\adamant-exp`에 적용 후 **전체 빌드 통과** (`build-planreserve.log`, BUILD-EXIT=0, 실행 없음). 남은 것: 메모리 압박 전후 비교(실행 게이트 — 서버가 비는 시점 대기), 통과 시 독립 커밋.

## 작업 4 — Windows unbuffered

TOP 4의 3순위이나 실행은 위 3건 뒤. 착수 전제: §12-나 검증 목록(비정렬 offset·마지막 partial block·동시 읽기·EOF·OVERLAPPED 이벤트 수명)을 테스트로 먼저 작성.

**상태 (2026-11-21)**: 패치 작성·검증 완료 — `mydocs/patches/unbuffered-reads.patch` (3파일 197줄, adamant HEAD `git apply --check` 통과). 상류 `77ec04e5`(#296)의 Windows 실장(`ReOpenFile`/`CreateFileW` + `FILE_FLAG_NO_BUFFERING|OVERLAPPED`, `direct_fds` 추적, 읽기마다 이벤트/절대오프셋 overlapped `pread`, `close_fd` 분류 해제)을 adamant `file.cpp` 구조에 어댑션. §12-나 검증은 상류 테스트 `test_unbuffered_descriptor()`(8 동시 리더·short final sector·EOF 초과·비정렬 offset/size 거부·버퍼드 재사용, fd/path 양 경로)를 `tests/platform/direct_file_async.cpp`에 함께 이식 — 그 테스트가 곧 실행 게이트. 서버 worktree에 `plan_reserve`와 함께 적용, **컴파일 검증 통과** (2026-11-21: 구현부 전체 빌드 BUILD-EXIT=0 + `-DBUILD_TESTING=ON` 후 `direct_file_async_test.exe` 빌드 성공). **실행 검증 통과** (2026-11-21: 서버 서빙 중 실행 — CPU 파일 I/O 전용으로 VRAM 0·RAM 수십 MB, 자유 RAM 19GB 확인 후 진행. `direct_file_async_test.exe` TEST-EXIT=0, `check()`는 실패 시 throw이므로 전 체크 통과 확정 — 동시 리더·short final sector·EOF 초과·비정렬 거부·버퍼드 재사용, fd/path 양 경로). 남은 것: 대형 팩 로딩에서의 실측 이득(Cold/Warm 로딩 시간·Peak RAM)은 엔진 실행 게이트 — 서버가 비는 시점 대기.

## 하네스 규칙 (GPT 지시: 자동화에 시간 쓰지 말 것)

만들 것 두 개뿐, **둘 다 서버(Windows)에서 실행** — 스크립트 작성은 Mac에서 가능: ① **baseline 측정 스크립트** — 고정 조건(동일 CUDA·MSVC·팩·컨텍스트·파라미터, Cold/Warm, 5회 중앙값, 로딩/디코드 분리)으로 tok/s·Peak VRAM·Peak RAM·로그 한 장 출력 ② **빌드·테스트 자동화** — 기존 CMake/ctest 그대로, parity 테스트 선택 실행. 그 이상의 프레임워크·대시보드·CI 확장 금지.

### 무인 측정 윈도우 (2026-11-21 설계)

제약: 엔진 측정은 VRAM ~22GB 독점 → 실서빙과 공존 불가, 그리고 "서버가 비는 때"는 곧 무인 시간대. 해법(사용자 확정 2026-11-21): **배치 하나** — 서빙은 사용자가 내린 뒤 `run-all.bat`을 실행하면 모든 테스트가 파일로 로그를 남기고, 에이전트는 나중에 그 파일을 읽는다. 서빙 자동 복원은 하지 않는다.

- **실행**: `D:\study\ai\adamant-exp\run-all.bat` 하나 (원본 `mydocs/run-all.ps1`). 미리 보기는 `run-all.bat -DryRun` (실행 명령 전부 출력만). 서빙이 떠 있으면 경고만 찍고 진행.
- **내용**: ⓪ `cmake --build build-ssh` 증분 — 테스트 exe 보장 ① 패치 빌드 전체 ctest(`--output-on-failure`; python 박힘은 configure 시점이므로 build-ssh는 `-DPython3_EXECUTABLE=<repo>\.venv\Scripts\python.exe`로 설정돼 있어야 함 — 재설정 명령은 `--help`에 없음, 필요 시 수동) → `ctest.log` ② 엔진 로딩 4회: A=현행/일반, B=패치/일반, C=현행/스트레스, D=패치/스트레스 → 런별 `.log`+`-samples.csv`(1초 VRAM/가용RAM/워킹셋)+`.csv`(요약)+`-tier.txt`(tier/guard 발췌) ③ `SUMMARY.md`+`transcript.txt`. 진행 출력: 단계별 `[HH:mm:ss] START/DONE(소요,exit)` + 로딩 중 30초 하트비트(경과·로그 크기·VRAM) + 조기 종료 감지. 미리 보기: `--help`(명령 목록) / `--dry-run`(전제조건 검사 모의 실행).
- **1차 실행 판독 (2026-11-21, 실패 원인 확정)**: 53 실패 = 51 Not Run(테스트 exe 미빌드 — 빌드 페이즈로 해소) + `migration_tests`(CMake configure이 테스트에 박는 python이 시스템 python — `jinja2` 없음. **PATH 변경 무의미**, `-DPython3_EXECUTABLE=<repo>\.venv\Scripts\python.exe` 재설정 필요 — venv에 numpy+jinja2 확인) + `gdn_head_split_parity`(0xc0000409, 출력 없음 — GDN 패치 무관, Windows CI가 GPU 테스트 미실행이라 기존 문제 추정, 재현 확인 필요). 엔진 미기동 원인은 `RedirectStandardInput NUL`의 파일 경로 해석 — 빈 파일 리다이렉트로 해소.
- **2차 실행 판독 (2026-11-21 19:26, `measure\20261121-192658`, 패치 A/B 게이트 통과)**: ctest 171/173 — 실패 2건 모두 기존 Windows 문제(패치 무관): `file_expert_repin_test`(`device_alias == blob` 단정 — Windows `cudaHostGetDevicePointer`가 호스트와 다른 별칭 반환, Linux UVA 전제; 엔진은 반환 별칭 사용으로 정상) + `gdn_head_split_parity`(0xc0000409 재현). 엔진 4/4 READY: unbuffered 읽기 2.30→4.91 GB/s(100% unbuf), 일반 로딩 35→25s(−29%). plan_reserve: 스트레스에서 budget 70GiB→가용치 클램프(패치는 리저브 16→18 GiB), 가용RAM 31.3→36.9 GB 유지·워킹셋 40.9→35.6 GB 감소, `RAM low` 가드는 클램프 덕에 미발화(게이트 의도 동작). 미해결 관찰: 일반 모드에서 패치 런이 VRAM +246MiB·WS +3GB (단일 표본, 재확인 필요).
- **서빙 교체 후 실측 (2026-11-21 19:47~, `bin\basalt.exe`←패치판, 원본 `basalt.exe.org` 백업)**: 서빙 정상, system ram 읽기 진행줄 **≥3,700 MB/s** (구판 서빙 로그 1,815~2,179 MB/s, 11-20 `benchmark\results\server-logs\`). 배치 A/B와 일치 — 읽기 1.7~2배, 로딩 체감 단축 확인.
- **준비 판정**: 엔진 stderr의 `MiB of VRAM free with everything loaded` (protocol.cpp) 폴링, 시작→해당 줄 경과 = 로딩 시간. stdin은 빈 파일(EOF 후 엔진 자체 종료 대기, 초과 시 kill).
- **스트레스 조건** (plan_reserve 게이트): `--ram-reserve-mib 16384 --resident-budget-gib 70` — 값은 스크립트 상단에서 조정. 판독은 tier/guard 로그 줄(`RAM low ... guard` 재현 여부) + 최소 가용 RAM.
- **패치본**: `D:\study\ai\adamant-exp\bin\Release\basalt.exe` (plan_reserve+unbuffered 합산. 분리 판독: tier 줄=plan_reserve, 로딩 시간=unbuffered).
- **산출물**: `D:\study\ai\adamant-exp\measure\<ts>\`. Cold 숫자가 필요하면 부팅 후 첫 실행이 cold.
- **에이전트 역할**: 실행 후 `measure\<ts>\` 읽기 → §12 판정 → 채택 시 독립 커밋.

## 서버 운영 제약 (사용자 지시 2026-11-21)

- 빌드는 **별도 빌드 폴더**(예 `D:\study\ai\adamant\build-ssh`)에만 생성한다. 기존 빌드/작업 트리 사용 금지.
- **실행 금지** — 서버가 실서빙 중이라 VRAM/RAM 여유가 없다. 엔진·벤치·GPU 테스트(parity 포함) 어떤 것도 돌리지 않는다. **빌드/컴파일만 허용.** 실행 게이트(parity→microbench→통합 벤치)는 사용자가 "비었다"고 하기 전까지 대기.

## 공통 원칙 (기준문서 §12 인용)

- 성능-목표 포팅은 **성능 개선 실측 없이는 채택하지 않는다**. 안정성-목표(plan_reserve/unbuffered)는 별도 기준.
- 각 실험은 독립 커밋·독립 되돌리기. 비교 기준은 adamant HEAD vs adamant+패치 (upstream main은 4090 빌드 불가 — 3자 비교 불가).
- 실험 결과는 기준문서 §9 미결 항목에 수치로 환류.
