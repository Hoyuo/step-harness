# step-harness

**전제: 모델은 지시를 안 따를 수 있다.** 그래서 "따르게 만들기"를 그만두고, 판단하는 지점을 전부 코드로 옮긴다.
모델이 해야 하는 일은 하나뿐이다 — 주어진 `NEXT_ACTION` 도구를 한 번 호출하는 것. 안 하면 막힌 채 멈추고, 사람에게 넘어간다. 틀린 결과로 끝나는 경로가 없다.

```
사람: "코드 컴플리트 돌려줘"
  └▶ UserPromptSubmit hook ─ 라우터(정규식 규칙) → flow 시작 → 게이트를 직접 실행 → NEXT_ACTION 1개 주입
모델: NEXT_ACTION 호출 (예: skill eats-write-unit-test)
  └▶ PreToolUse  ─ 도구·params 가 정확히 일치할 때만 통과. 그 외(직접 수정, 다른 스킬, 임의 명령)는 차단
  └▶ PostToolUse ─ receipt 를 hook 이 기록 → 게이트 재실행 → 통과면 DONE, 실패면 다음 NEXT_ACTION
모델: 멈추려 함
  └▶ Stop hook   ─ 흐름이 안 끝났으면 차단. 판정이 곧 끝나면 기다렸다가 직접 다음 단계로
한도 초과(재시도 3회·차단 5회·종료 시도 3회) └▶ handoff: 턴을 끝내고 사람에게 retry / proceed / stop 을 묻는다
```

| 모델이 이렇게 하면 | 일어나는 일 |
|---|---|
| "간단하니까" 직접 수정 | PreToolUse 차단 + 같은 NEXT_ACTION 재출력 |
| 스킬만 부르고 지침은 안 따름 | 스킬을 서브에이전트로 실행(`agent:`)하므로 메인은 지침을 해석할 기회가 없다. 결과는 게이트가 판정 |
| 안 하고 "다 했다"고 보고 | receipt 가 없어 진행 안 됨. Stop 차단 |
| 하긴 했는데 결과가 틀림 | 게이트 실패 → 같은 수정 액션 재시도 → 한도 넘으면 사람에게 |
| 막힌 호출만 반복 / 읽기만 반복 | 상한에서 handoff (토큰을 더 쓰지 않는다) |
| 하네스 상태 파일을 고치려 함 | `.step-harness/` 와 플러그인 폴더는 쓰기 차단 |

## 설치와 첫 확인

```bash
# 1) hook 설치 — 둘 중 하나만
devin plugins install --local ./step-harness          # 플러그인으로 (hooks.json 이 PLUGIN_ROOT 계열 변수를 쓴다)
node step-harness/scripts/harness.cjs install          # 또는 이 프로젝트에만: .devin/hooks.v1.json 에 절대경로로 등록

# 2) 프로젝트에서 켜기 — .step-harness/ 폴더가 있는 프로젝트에서만 동작한다
mkdir -p .step-harness && cp step-harness/router.example.json .step-harness/router.json   # 규칙 수정

# 3) Devin 세션에서 입력:  harness smoke        → "step-harness works in this environment" 가 나오면 hook 이 돈다
# 4) 이 환경의 실제 동작 확인 (아래 "확인이 필요한 것")
node step-harness/scripts/harness.cjs probe on         # 안내되는 프롬프트를 Devin 에서 실행
node step-harness/scripts/harness.cjs doctor --apply   # 분석 결과를 config.json 에 반영
node step-harness/scripts/harness.cjs probe off
```

권장: flow 를 돌리는 세션은 모델을 고정하고(`/model`), 서브에이전트의 수정 승인에서 멈추지 않게 `/accept-edits` 모드로.
기존 플러그인에 같은 역할의 hook(프롬프트 라우터, Stop 에서 도는 게이트, write boundary)이 있으면 한쪽만 켠다.

## flow 형식 (YAML 또는 JSON)

```yaml
flow: code_complete
args: [gate]
start: gate
max_visits: 3
actions:
  gate:                    # judge — check 만. 하네스가 명령을 돌려 exit code 로 판정
    check: "{gate}"
    on:
      pass: done
      fail: { unit-test: fix_tests, "*": fix_direct }   # 분기 = 게이트가 찍은 HARNESS_ROUTE (모델의 판단 아님)
  fix_tests:               # call — 이 도구를 이 params 로 정확히 1번
    tool: skill
    params: { skill: eats-write-unit-test, args: "{last_report}" }
    deny: [edit, write, apply_patch, notebook_edit, exec]
    write_scope: ["lib/**", "test/**"]
    on: { pass: gate }
  fix_direct:              # work — 메인이 직접 (범위 제한)
    work: Fix every failure listed in {last_report}.
    allow: [edit, write, apply_patch]
    write_scope: ["lib/**", "test/**"]
    on: { pass: gate }
done: code complete gate passed
```

| 액션 | 정의 | 모델이 받는 것 | 끝났다는 증거 |
|---|---|---|---|
| judge | `check` 만 | "check 명령을 실행하라" (hook 이 먼저 돌려 두므로 대개 건너뛴다) | 명령의 exit code |
| call | `tool` + `params` | 그 도구 호출 1번 | PostToolUse 가 쓴 receipt (+ 선택 `check`) |
| work | `work` + `allow` | 지시문 + 허용 도구·경로 | 수정 1건 이상의 receipt (+ 선택 `check`) |

- `on.pass` 필수. `on.fail` 은 액션 id 또는 `{ route: 액션, "*": 기본 }`. 생략하면 judge 는 handoff, call/work 는 같은 액션 재시도.
- 예약 대상: `done`, `handoff`. 명령 키는 Devin 도구 이름 그대로 (`skill`, `run_subagent`, `exec`, `mcp__서버__도구` …).
- 내장 인자 `{last_report}` = 가장 최근 판정의 출력 파일 (`.step-harness/last-report.txt`).
- `rewrite: [키]` — 그 params 는 대조하지 않고 hook 이 flow 의 값으로 덮어쓴다 (모델이 긴 문장을 바꿔 써도 무관).
- `write_scope` — 그 액션 동안 쓸 수 있는 경로 glob. 메인의 work 와 위임된 작업자 모두에 적용. `exec_allow` — 허용 명령 정규식.
- 한도(기본값): `max_visits` 3 · `max_blocks` 5 · `max_idle_calls` 15 · `max_stop_blocks` 3 · `max_steps` 40 · `check_timeout_sec` 900.
- 검사: `node scripts/harness.cjs lint <flow>` (오타 키, 없는 액션, 모르는 도구, 정의 안 된 인자 등).
- YAML 은 내장 파서로 읽는다(앵커·태그·여러 줄 plain 스칼라 미지원). `yaml` 패키지가 설치돼 있으면 그것을 쓴다.

### 게이트(판정 명령)의 계약

1. exit 0 = 통과, 그 외 = 실패.
2. 실패 시 stdout 에 `HARNESS_ROUTE=<종류>` 한 줄을 찍으면 `on.fail` 맵에서 다음 액션이 정해진다.

출력 전체는 `.step-harness/reports/<액션>.txt` 와 `last-report.txt` 에 저장된다. 기존 게이트를 감싸는 예: `templates/gate-wrapper.sh`.
판정은 hook·CLI 와 분리된 프로세스로 돈다. 그래서 몇 분이 걸려도 hook 타임아웃(1분)에 걸리지 않고, `check` 를 여러 번 불러도 한 번만 실행된다.

## 라우터 (`.step-harness/router.json`)

```json
{ "routes": [ { "name": "code complete", "when": "코드\\s*컴플리트\\s*(돌려|실행|해줘)|^/?cc\\b",
                "flow": "flows/code-complete.flow.yaml", "args": { "gate": "bash scripts/gate.sh" } } ] }
```
- `when` 은 사용자 프롬프트에 대한 정규식. **좁게** 쓴다 ("코드 컴플리트가 뭐야?" 에 걸리지 않게). 두 규칙이 걸리면 시작하지 않고 되묻게 한다.
- `args` 의 `$1` 은 캡처 그룹. 프롬프트에서 온 값은 `check` 명령에 들어갈 때 셸 따옴표 처리된다.
- 사람용 명령: `harness stop` · `harness status` · handoff 에서는 `retry` / `proceed` / `stop` (또는 재시도 / 진행 / 중단) 한 단어로 답한다.

## 스킬은 서브에이전트로

인라인 스킬은 메인 컨텍스트에 텍스트로 들어갈 뿐이라 "부르기만 하고 안 따름"이 생긴다. 스킬 프런트매터에 `agent: <프로필>` 을 넣으면 그 프로필의 서브에이전트에서 실행된다.
도구 제한은 프로필의 `allowed-tools` 로 건다 (스킬의 `allowed-tools` 는 제한이 아니라 사전 승인).
→ `agents/fixer.md`, `templates/skills/eats-write-unit-test/SKILL.md`. 플러그인에 든 프로필 이름은 `step-harness:fixer`.

## CLI (`node scripts/harness.cjs …`)

| 누가 | 명령 |
|---|---|
| 모델 (hook 이 이것만 통과시킨다) | `next` · `check [--wait N]` · `status` |
| 사람 | `start <flow> k=v.. [--force]` · `lint <flow>` · `resume [--proceed]` · `reset` |
| 사람 | `install [--fail-closed]` · `uninstall` · `probe on\|off` · `doctor [--apply]` |
| 사람 (실험) | `run <flow> k=v.. --worker "<명령>"` |

## 설정 (`.step-harness/config.json`, 전부 선택)

| 키 | 기본 | 뜻 |
|---|---|---|
| `subagent_hooks` | `same` | 서브에이전트의 도구 호출이 hook 에 어떻게 보이는가. `doctor --apply` 가 정한다 (아래) |
| `wait` | `{prompt:5, post:8, stop:20}` | 각 hook 이 판정 완료를 기다리는 최대 초. hook 타임아웃(30/30/55초)보다 짧아야 한다 |
| `check_wait_sec` | 30 | `check` 한 번이 기다리는 시간. 넘으면 STILL RUNNING 을 찍고 끝난다 (다시 부르면 이어진다) |
| `auto_approve_cli` | false | 하네스 CLI 실행의 승인 프롬프트를 PermissionRequest hook 으로 생략 |
| `assume_done_on_stop` | false | 위임 도구에 PostToolUse 가 오지 않는 환경용. 메인이 멈추려는 시점에 "호출됨"으로 친다 |

## 러너 모드 (실험, Devin 에서 미검증)

세션 안의 모델에게 순서를 맡기지 않고, 스크립트가 루프를 돌며 작업마다 작업자 명령을 실행한다.

```bash
node scripts/harness.cjs run flows/code-complete.flow.yaml gate='bash scripts/gate.sh' \
  --worker 'devin -p --prompt-file {prompt_file} --permission-mode accept-edits --respect-workspace-trust false'
```
작업자 프롬프트는 스크립트가 만들고(`.step-harness/prompt.txt`), 작업자 안에서도 `write_scope` 는 hook 이 지킨다. 종료 코드: 0 = done, 2 = handoff.

## 확인이 필요한 것 (Devin 문서에 없어서 probe 로 확인)

1. **서브에이전트의 도구 호출이 hook 에 어떻게 보이는가** → `subagent_hooks`
   - `foreign` (다른 session_id) / `none` (hook 이 안 돎): NEXT_ACTION 실행 중에도 메인의 직접 수정을 막는다.
   - `same` (메인과 같은 id, 기본값): 구분할 수 없어 실행 구간 동안은 메인의 호출도 통과한다. 서브에이전트를 foreground 로만 쓰면 그동안 메인은 멈춰 있으므로 실질적 구멍은 "같은 응답 안의 병렬 호출"뿐이다.
2. **`skill` / `run_subagent` 의 실제 입력 키·값** → flow 의 `params` 를 그것과 같게 (doctor 의 [4]).
3. **위임 도구의 PostToolUse 가 서브에이전트 종료 뒤에 오는가** → 먼저 오면(background) receipt 가 일찍 찍힌다.
4. **플러그인 루트 변수** → 안 풀리면 `harness.cjs install` (절대경로) 사용.

## 쓰는 Devin 기능 (changelog 기준 도입 버전)

| 기능 | 쓰는 곳 | 도입 |
|---|---|---|
| hook payload 의 `session_id` / `prompt_id` | 세션 구분, "같은 턴" 판정 | v3000.2.17 |
| 차단 사유가 모델에게 전달됨 | PreToolUse 차단 메시지 | v3000.6.2 |
| `CLAUDE_PLUGIN_ROOT` / `DEVIN_PLUGIN_ROOT`, `PLUGIN_ROOT` | 플러그인 hooks.json 경로 | v3000.5.20, v3000.11.92 |
| hook 출력 `stop` (턴 종료) | handoff | v3000.11.205 (없어도 동작: 모델에게 "사용자에게 전하고 멈춰라"를 지시) |
| hook 설정 `fail_closed` | `install --fail-closed` | v3000.11.205 |
| PreToolUse `updatedInput` | `rewrite` | 문서 기재 |

## 한계

- `exec` 로 하는 파일 변경은 경로를 볼 수 없다. 수정 액션에서는 `exec` 를 deny 하거나 `exec_allow` 로 좁힌다.
- 하네스 파일 보호는 문자열 검사다. 작정하고 돌려 쓰는 명령까지 막지는 못한다 (대상은 악의가 아니라 게으름이다).
- 판정 명령은 Devin 프로세스의 환경변수로 돈다. 셸 프로필이 필요하면 `check: zsh -lc '…'`.
- macOS / Linux 전용 (bash). 대상은 Devin 이다 (hook 이 한 벌만 등록되도록 Claude Code 용 레이아웃은 넣지 않았다. 도구 이름 별칭은 코드에 남아 있다).

## 파일

`<project>/.step-harness/` — `router.json` `config.json` (커밋 대상) · `flow.json` `state.json` `judge.json` `receipts.jsonl` `log.jsonl` `reports/` (실행 상태, `.gitignore` 자동 생성)

## 테스트

```bash
bash test/run-tests.sh            # 209 케이스: hook 입력 시뮬레이션 + 실제 백그라운드 판정 프로세스
VERBOSE=1 bash test/run-tests.sh  # 케이스 이름 표시
```
