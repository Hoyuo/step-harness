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

#    (프로그램 모드는 2) 없이도 된다: Devin 에서 "프로그램: <할 일>" 이라고 치면 그 자리에서 .step-harness/ 를 만들고 시작)

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
- `write_scope` — 그 액션 동안 쓸 수 있는 경로 glob. 메인의 work 와 위임된 작업자 모두에 적용. `exec_allow` — 허용 명령 정규식. 명령의 처음부터 맞아야 하고, `; & | < > $( )` 와 줄바꿈이 있으면 거부한다.
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
- `args` 의 `$1` 은 캡처 그룹. 프롬프트에서 온 값은 `check` 명령에 들어갈 때 셸 따옴표 처리된다 (flow 에서 `'{x}'` 나 `"… {x} …"` 처럼 따옴표 안에 두어도 글자 그대로의 인자 하나가 된다).
- 사람용 명령: `harness stop` · `harness status` · handoff 에서는 `retry` / `proceed` / `stop` (또는 재시도 / 진행 / 중단) 한 단어로 답한다.

## 스킬은 서브에이전트로

인라인 스킬은 메인 컨텍스트에 텍스트로 들어갈 뿐이라 "부르기만 하고 안 따름"이 생긴다. 스킬 프런트매터에 `agent: <프로필>` 을 넣으면 그 프로필의 서브에이전트에서 실행된다.
도구 제한은 프로필의 `allowed-tools` 로 건다 (스킬의 `allowed-tools` 는 제한이 아니라 사전 승인).
→ `agents/fixer.md`, `templates/skills/eats-write-unit-test/SKILL.md`. 플러그인에 든 프로필 이름은 `step-harness:fixer`.

## CLI (`node scripts/harness.cjs …`)

| 누가 | 명령 |
|---|---|
| 모델 (hook 이 이것만 통과시킨다) | `next` · `check [--wait N]` · `status` · `search [q]` · `execute` (프로그램 모드) |
| 사람 | `start <flow> k=v.. [--force]` · `lint <flow>` · `resume [--proceed]` · `reset` |
| 사람 | `install [--fail-closed]` · `uninstall` · `probe on\|off` · `doctor [--apply]` |
| 사람 (실험) | `run <flow> k=v.. --worker "<명령>"` |

## 설정 (`.step-harness/config.json`, 전부 선택)

| 키 | 기본 | 뜻 |
|---|---|---|
| `subagent_hooks` | `same` (미설정 시) | 서브에이전트의 도구 호출이 hook 에 어떻게 보이는가. `doctor --apply` 가 정한다 (아래) |
| `wait` | `{prompt:5, post:8, stop:20}` | 각 hook 이 판정 완료를 기다리는 최대 초. hook 타임아웃(30/30/55초)보다 짧아야 한다 |
| `check_wait_sec` | 30 | `check` 한 번이 기다리는 시간. 넘으면 STILL RUNNING 을 찍고 끝난다 (다시 부르면 이어진다) |
| `auto_approve_cli` | false | 하네스 CLI 실행의 승인 프롬프트를 PermissionRequest hook 으로 생략 |
| `assume_done_on_stop` | false | 위임 도구에 PostToolUse 가 오지 않는 환경용. 메인이 멈추려는 시점에 "호출됨"으로 친다 |
| `gates` · `skills` · `agents` · `writable` · `worker` | — | 프로그램 모드의 등록부와 작업자 명령 (아래 "프로그램 모드"). `worker` 미설정 시 `devin -p …` 기본값 |
| `done_when` | 없음 | 프로그램 모드의 기본 완료 조건(게이트 이름 목록). 규칙의 `program.done_when` 이 우선 |
| `scope_check` | true | 작업자가 끝난 뒤 git 으로 실행 전과 비교해(미커밋 변경과 그사이의 커밋) 범위 밖 변경을 잡는다 (git 저장소일 때만) |
| `worker_sandbox` | false | (macOS, 실험적) 작업자와 게이트의 프로세스 트리 전체를 OS 샌드박스(`sandbox-exec`)에 넣는다. 하네스 상태 폴더·플러그인 폴더·git 의 hook 과 설정·프로젝트의 Devin/MCP 설정 파일(`.devin/hooks.v1.json` · `.devin/config*.json` · `.devin/mcp_config*.json` · `.mcp.json`)·`PATH` 폴더들의 `node`·셸 시작 파일(`~/.zshrc` 등)에 쓸 수 없다 (분리해 띄운 프로세스도 포함). 막는 것은 이 목록뿐이다 ("한계" 참고). 다른 OS 에서 켜면 그 단계가 실패한다. 자체 샌드박스를 쓰는 도구(Devin 의 `--sandbox`, SwiftPM 등)는 이 안에서 실패할 수 있다 |
| `worker_timeout_sec` | 3600 | 프로그램 모드 작업자 한 번의 시간 제한 |

## 프로그램 모드 (Code Mode)

아이디어 출처: [Cloudflare — Code Mode MCP](https://blog.cloudflare.com/code-mode-mcp/). 도구를 하나씩 부르게 하는 대신, 모델이 **좁은 API 에 대한 프로그램**을 내고 하네스가 **실행 전에 검증**한 뒤 결정적으로 실행한다.
flow 의 "한 걸음씩 NEXT_ACTION" 과 달리 순서·분기·반복을 모델이 짜지만, 짤 수 있는 것은 문법과 검증기가 허용하는 것뿐이고, **끝났는지는 여전히 코드가 판정한다** (`done_when`).

```ts
async (h) => {
  for (const attempt of h.retries(3)) {
    const r = await h.check("code-complete");
    if (r.pass) return h.done("code complete");
    if (r.route === "unit-test") await h.skill("eats-write-unit-test", r.report, { scope: ["lib/**", "test/**"] });
    else await h.agent("fixer", `Fix every failure in ${r.report}`, { scope: ["lib/**"] });
  }
  return h.handoff("3회 시도 후에도 실패");
}
```

| 단계 | 하는 것 |
|---|---|
| 프롬프트 | 자연어 지시 대신 `declare const h: {…}` 타입 선언(등록된 이름이 리터럴 유니언으로 들어감) + 문법 규칙 + 등록부로 만든 예시 하나 + 제출 형식 |
| `search` | 등록된 게이트·스킬·에이전트와 설명 (게이트의 실제 명령은 보여주지 않는다) |
| `execute` | 파싱 → 정적 검증 → 통과하면 분리된 프로세스에서 실행. 거부되면 아무것도 돌지 않고 오류 목록만 돌아온다. 확인과 시작은 한 락 안에서 하므로 프로그램은 한 번에 하나만 돈다 |
| 실행 | `h.check` = 등록된 게이트 실행 · `h.skill` / `h.agent` = 작업자 명령(`worker`)을 그 `scope` 로 실행. 모델에게는 단계별 한 줄과 최종 결과만 간다 (`check` 는 아직 안 보여준 단계만 출력) |
| 완료 | `h.done()` 은 프로그램의 주장일 뿐이다. `done_when` 에 적힌 게이트를 **하네스가 직접 돌려** 통과해야 끝난다 (마지막 작업 뒤에 프로그램이 이미 돌려 통과한 게이트는 다시 돌리지 않는다). 실패하면 사유와 함께 새 프로그램을 요구하고(시도 +1), `max_visits`(3)를 넘으면 사람에게 넘긴다 |

**문법 (TS 부분집합)** — `async (h) => { … }` 하나. `const` · `if/else` · `for (const i of h.retries(N))` · `break/continue` · `return` · `await h.<메서드>(…)` · 멤버 접근(`?.` 포함) · `=== !== && || !` · 문자열/템플릿/숫자/배열/객체 리터럴. 대입·`let`·`while`·함수·`import`·임의 호출·삼항·산술·`< >` 는 받지 않는다. 흔한 실수(삼항, `==`, `+`, 구조 분해, 일반 `for`, 화살표 함수)에는 대안을 적은 오류를 돌려준다. 앞뒤의 ```` ```ts ```` 울타리는 떼고 읽는다.

**검증 규칙** — 모든 경로가 `return h.done(…)` 또는 `return h.handoff(…)` 로 끝난다 · 반복은 `h.retries(1..10)` 리터럴만, 겹친 반복의 곱은 1000 이하 · 게이트·스킬·에이전트 이름은 등록부에 있어야 한다 · 정의 안 된 이름·재정의·도달 불가 문장·`constructor` 등 위험한 속성 금지 · 실행 중 호출 수 상한 `max_steps`(40), 문장·반복 수 상한 10만 · 프로그램 길이 2만 자.
쓰기 작업은 `scope` 필수다. `writable` 이 있으면 그 목록에 있는 것만. 없으면 프로그램이 고르되 **이름으로 시작하는 상대 경로**만 받는다 (`src/**` 는 되고 `**`, `*/**`, `**/*.ts`, `.git/**`, `.devin/**` 같은 전체·숨김 경로는 거부. `.step-harness` 는 어떤 경우에도 불가).

**강제**
- 메인 세션: 읽기 도구와 하네스 명령(`search` · `execute` · `check`)만 쓸 수 있다. 실행 중에 낸 새 프로그램은 거부되고, 멈추려 하면 Stop hook 이 붙잡는다 (결과를 사용자에게 전하게 하려고. 횟수는 세지 않는다).
- 작업자: 환경변수 `STEP_HARNESS_WORKER=<run>:<seq>` 로 구분한다. **그 실행이 아직 돌고 있을 때만** 그 단계의 `scope` 안에서 파일 도구로 쓸 수 있다. 실행이 끝났거나 멈춘 뒤에 남은 작업자(이 변수를 물려받은 프로세스)는 읽기만 된다. 작업자의 Stop·프롬프트 이벤트는 흐름에 끼어들지 않는다.
- 범위 밖 변경 감지: 작업자가 끝날 때마다 git 으로 실행 전과 비교한다. hook 을 거치지 않은 변경(셸 명령 등)이라도 범위 밖 파일이 바뀌었으면 그 자리에서 멈추고 사람에게 넘긴다. 작업자가 커밋까지 한 변경도 본다 (실행 전후의 커밋을 비교한다). 실행 전부터 있던 미커밋 변경은 그대로 두면 문제 삼지 않고(작업자가 그것을 같이 커밋해도 마찬가지), 되돌리거나 고치면 잡는다. git 이 보지 않게 표시한 파일(`assume-unchanged` · `skip-worktree`)이나 커밋 바꿔치기(`git replace`)로 숨긴 변경도 잡고, 작업자가 돈 뒤에 git 이 답하지 못하면(색인 손상 등) 통과로 치지 않고 멈춘다. git 이 관리하는 파일이 있는 폴더에 새로 만든 `.gitignore` 는 자기 자신까지 무시하게 적혀 있어도 찾아낸다 (그런 파일로 범위 밖의 새 파일을 가릴 수 없게). 프로젝트 안에 따로 있는 git 저장소(하위 모듈 등)는 폴더 한 덩어리로 본다: 그 안의 무엇이 바뀌든 그 폴더가 바뀐 것이므로, 그 안에서 작업시키려면 범위가 폴더 전체를 덮어야 한다 (예: `vendor/lib/**`). git 저장소가 아니면 생략된다. `"scope_check": false` 로 끈다. 하네스가 돌리는 git 은 처음에 정한 절대 경로의 것만 쓰고(PATH 에 심은 `git` 은 실행하지 않는다), 사용자·시스템 설정을 읽지 않으며, 설정에 적힌 명령(`core.fsmonitor` 등)을 실행하지 않는다.
- 보호 대상 파일 변경 감지: 작업자가 도는 동안 설정·규칙·흐름·프로그램 파일, hook 등록 파일(`.devin/hooks.v1.json`), 플러그인 코드, git 의 hook·설정과 git 이 설정·필터·무시 목록을 읽는 파일(`.git/hooks/*` · `.git/config` · `.git/commondir` · `.git/info/exclude` 등)이 바뀌면 방법이 무엇이든 멈추고 사람에게 넘긴다 (git 저장소가 아니어도 동작). 실행 프로세스가 끝맺기 전에 상태 파일이 "완료"나 "중단"으로 바뀌어 있으면(사람이 멈춘 경우는 멈춘 쪽이 실행 프로세스를 정리하므로 구분된다) 받아들이지 않고 사람에게 넘긴다. `check` 도 실행 프로세스가 살아 있는 동안에는 그런 완료를 알리지 않는다.
- 작업자가 끝나면 그 작업자가 백그라운드로 남긴 프로세스(같은 프로세스 그룹, Linux 에서는 표식 환경변수를 물려받은 것까지)를 정리한다. 작업자 안에서 실행한 하네스의 `reset` · `resume` · `execute` · `check` 는 거부된다.
- `"worker_sandbox": true` (macOS, 실험적): 위 검사들에 더해, 작업자와 게이트의 프로세스 트리 전체가 OS 수준에서 다음에 쓰지 못한다 — 하네스 상태 폴더, 플러그인 폴더, hook 등록과 프로젝트의 Devin/MCP 설정, git 의 hook·설정, 그리고 하네스의 hook·CLI 가 시작될 때 쓰이는 것(`PATH` 폴더들의 `node`, 지금의 `node` 실행 파일, `~/.zshrc` 같은 셸 시작 파일). 작업자가 분리해 띄운 프로세스가 **나중에** 상태 파일을 직접 고치는 것은 이 옵션이 있어야 막힌다. 켜져 있으면 하네스가 실행 뒤 검사에 쓰는 git 도 같은 샌드박스 안에서 돈다. 막는 것은 이 목록뿐이다 (아래 "한계" 참고).
- 흐름이 사람에게 넘어가거나(막힌 호출 반복 등) 중단되면, 돌고 있던 실행 프로세스와 작업자를 정리한다. 실행 구간은 시간이 아니라 실행 프로세스의 생사로 판단한다.
- 거부가 `max_visits`(3)를 넘거나, 프로그램이 `h.handoff` 로 끝나거나, 실행 중 오류가 나면 사람에게 넘긴다 (`retry` = 새 프로그램, `proceed` = 통과로 처리).

```jsonc
// .step-harness/config.json
{
  "gates":  { "code-complete": { "cmd": "bash scripts/gate.sh", "about": "unit tests + analyzer" } },
  "skills": { "eats-write-unit-test": "게이트 리포트로 누락된 테스트 작성" },
  "agents": { "fixer": "범용 수정" },
  "writable": ["lib/**", "test/**"],
  "done_when": ["code-complete"],       // 규칙에 done_when 이 없을 때의 기본 완료 조건
  "worker": "devin -p --prompt-file {prompt_file} --permission-mode accept-edits --respect-workspace-trust false"   // {agent} = 에이전트 이름
}
// .step-harness/router.json 의 규칙:
//   { "name": "cc", "when": "^코드\\s*컴플리트", "program": { "task": "코드 컴플리트 게이트를 통과시킨다", "done_when": ["code-complete"] } }
```

**바로 쓰기** — 플러그인을 설치하면 기본 규칙 `프로그램: <할 일>` (또는 `program: …`) 이 켜진다. `.step-harness/` 가 없는 프로젝트에서도 그 자리에서 만들고 시작한다. 프로젝트 `router.json` 에 맞는 규칙이 있으면 그쪽이 먼저다.
`config.json` 이 없으면 게이트 없음 · 스킬/에이전트 이름 제한 없음 · `worker` 는 위 `devin -p …` 기본값(`"worker": null` 로 끔)이다. 이 상태에서는 `h.check` 를 쓸 수 없고 완료 조건도 없으므로, **`h.done()` 을 검증할 수단이 없다** (작업자가 0 으로 끝났다는 것뿐). 제대로 쓰려면 게이트와 `done_when` 을 등록한다. 설정 상태는 `harness.cjs doctor` 가 알려준다.

제출 경로는 둘이다.
1. `exec` 로 `node <plugin>/scripts/harness.cjs execute <<'EOF' … EOF`. 경로는 절대 경로, 따옴표 친 heredoc 한 개만 통과한다. 앞뒤에 다른 명령을 붙이거나(줄바꿈 포함) 종료 줄 뒤에 내용이 있으면 차단된다.
2. MCP 서버 `scripts/mcp.cjs` (도구 `search` / `execute` / `check`, Devin 에서의 이름은 `mcp__step-harness__execute` 등). 플러그인 루트의 `.mcp.json` 으로 등록된다. `/mcp` 에 보이지 않으면 `devin mcp add step-harness -- node <plugin>/scripts/mcp.cjs`.
   서버는 프로젝트 폴더를 환경변수(`STEP_HARNESS_ROOT` · `DEVIN_PROJECT_DIR` · `CLAUDE_PROJECT_DIR`) → 클라이언트가 알려준 작업 폴더(MCP roots, 답을 받을 때까지 도구 호출을 미룬다) → 자신의 cwd 순으로 찾는다. cwd 는 프로젝트로 보일 때만(위쪽에 `.step-harness` 나 `.git` 이 있고, 플러그인·홈 폴더가 아님) 쓰고, 아니면 실행하지 않고 1번 경로를 안내한다.

실행 대상 모델은 Opus 4.6 을 기준으로 했다: 타입 선언과 예시를 보고 프로그램을 쓰고, 거부 메시지를 받으면 고쳐 다시 낸다. 습관적으로 쓰는 `?.`·`(h: H)`·괄호로 감싼 함수는 받는다.

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
5. **(프로그램 모드) 작업자의 hook 에 환경변수가 전달되는가** → 작업자(`devin -p`)가 실행한 hook 에 `STEP_HARNESS_WORKER` 가 보여야 한다. 안 보이면 작업자의 쓰기가 전부 막혀 그 단계가 실패하고 사람에게 넘어간다 (조용히 풀리지는 않는다).
6. **(프로그램 모드) 플러그인 MCP 서버가 어느 폴더에서 뜨는가** → 문서에 없다. 그래서 서버가 프로젝트 폴더를 확인하지 못하면 실행을 거부한다 (위 "제출 경로").

문서로 확인한 것: 기본 작업자 명령의 옵션(`-p` · `--prompt-file` · `--permission-mode` · `--respect-workspace-trust`), 플러그인 루트 `.mcp.json` 의 `mcpServers` 형식, hook 에 보이는 MCP 도구 이름(`mcp__<서버>__<도구>`), `updatedInput` 은 기존 입력에 병합된다는 것.

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
- 프로그램 모드: 작업자에게 셸 명령을 허용하면(권한 모드에 따라) 그 프로세스는 사용자와 같은 권한으로 돈다. 범위 밖 변경·보호 대상 파일 변경·상태 파일 위조는 실행 프로세스가 살아 있는 동안 결과로 잡아내지만, 작업자가 일부러 분리해 띄운 프로세스가 실행이 끝난 뒤에 상태 파일을 고치는 것, 실행 프로세스를 죽이고 상태를 꾸미는 것은 그것만으로는 막을 수 없다 (같은 사용자의 프로세스끼리는 믿을 기준점이 없다). `PATH` 앞쪽 폴더에 가짜 `node` 를 심어 다음 hook 호출이 그것을 실행하게 하는 것도 마찬가지다. 이것까지 막으려면 `worker_sandbox` 를 켜거나(macOS), 작업자에게 셸을 주지 않는 권한 모드를 쓴다. `worker_sandbox` 안에서는 샌드박스를 또 만드는 도구(Devin 의 `--sandbox`, SwiftPM 등)가 실패하고(샌드박스는 중첩되지 않는다), 실제 Devin 작업자와의 조합은 아직 확인하지 못했다. 그래서 기본값은 꺼짐이다.
- `worker_sandbox` 는 정해 둔 목록에 쓰지 못하게 하는 장치이지, 악의적인 작업자를 가두는 장치가 아니다. 목록 밖에는 여전히 쓸 수 있다. 예: 사용자 단위 Devin 설정(작업자인 Devin 자신이 거기에 써야 할 수 있어 막지 않는다), 다른 도구의 설정과 실행 파일(`PATH` 앞쪽 폴더에 가짜 `npm` 을 심으면 게이트가 그것을 실행한다). 목록은 알려진 경로일 뿐이고, 독립 검토를 돌릴 때마다 새 경로가 하나씩 더 나왔다. 믿을 수 없는 작업자를 돌려야 한다면 `worker` 명령이 컨테이너나 가상 머신 안에서 작업자를 실행하도록 바꾼다.
- 프로그램 모드: `done_when` 이 없으면 `h.done()` 을 그대로 받아들인다. 범위 밖 변경 감지는 git 이 보는 파일만 본다. 무시되는 파일은 보이지 않는다: 이미 `.gitignore` 에 올라 있는 경로(`node_modules/` 등)와, 자기 자신을 무시하는 새 폴더(도구가 만드는 캐시 폴더와 같은 모양) 안은 작업자가 바꿔도 잡지 못한다. 프로젝트 안의 다른 git 저장소(하위 모듈)는 폴더 단위로만 본다. 작업자가 도는 동안 사람이 범위 밖 파일을 고치거나 커밋하면 작업자가 한 것으로 본다. 작업자가 무엇을 할 수 있는지(셸 명령 등)는 `worker` 명령의 권한 모드가 정한다.
- Devin 문서에 따르면 플러그인으로 설치한 hook 은 로드·실행에 실패해도 세션이 그대로 진행된다(fail-open). 강제가 중요하면 `harness.cjs install --fail-closed` 로 프로젝트 hook 을 쓴다.
- 판정 명령은 Devin 프로세스의 환경변수로 돈다. 셸 프로필이 필요하면 `check: zsh -lc '…'`.
- macOS / Linux 전용 (bash). 대상은 Devin 이다 (hook 이 한 벌만 등록되도록 Claude Code 용 레이아웃은 넣지 않았다. 도구 이름 별칭은 코드에 남아 있다).

## 파일

`<project>/.step-harness/` — `router.json` `config.json` (커밋 대상) · `flow.json` `state.json` `judge.json` `receipts.jsonl` `log.jsonl` `reports/` `program.ts` `prompt-N.txt` (실행 상태, `.gitignore` 자동 생성)

## 테스트

```bash
bash test/run-tests.sh            # 442 케이스: hook 입력 시뮬레이션 + 실제 백그라운드 판정 프로세스
VERBOSE=1 bash test/run-tests.sh  # 케이스 이름 표시
```
