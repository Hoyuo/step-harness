# step-harness

**계획 먼저.** 에이전트가 무언가를 바꾸기 전에 할 일을 프로그램(계획 파일)으로 내게 하고, 하네스가 그 프로그램을 검증한 뒤 한 걸음씩 강제한다.
다음에 무엇을 할지와 "끝났다"는 판정은 모델이 아니라 코드가 한다. 아이디어의 출처는 [Cloudflare — Code Mode](https://blog.cloudflare.com/code-mode-mcp/)다.

```
사용자: 아무 프롬프트
  └▶ 질문이면 그냥 읽고 답한다 (읽기는 막지 않는다)
에이전트: 무언가를 바꾸려 한다 (파일 수정 · 명령 실행 · 스킬 · 서브에이전트)
  └▶ PreToolUse hook ─ 막는다. "먼저 계획을 내라" + 계획 API
에이전트: 프로그램 하나를 제출한다   async (h) => { … }
  └▶ 하네스 ─ 문법 · 등록된 이름 · 쓰기 범위 · 끝맺음을 검증. 틀리면 이유와 함께 거부하고 아무것도 시작하지 않는다
하네스: 프로그램에서 다음 한 걸음을 꺼내 준다 (그 밖의 호출은 hook 이 막는다)
  ├ h.check(gate)          → 하네스가 등록된 명령을 직접 실행해 판정한다
  ├ h.work(task, {scope})  → 프롬프트를 받은 그 에이전트가 범위 안에서 직접 작업한다
  └ h.skill / h.agent      → 그 에이전트가 그 스킬·서브에이전트를 정확히 한 번 호출한다
걸음이 끝나면 결과를 기록하고, 프로그램이 정한 다음 걸음으로 간다
  └▶ return h.done(…)     → 완료 조건(done_when)의 게이트를 하네스가 직접 돌려 통과해야 끝난다
  └▶ return h.handoff(…) · 한도 초과 → 멈추고 사람에게 retry / proceed / stop 을 묻는다
```

| 에이전트가 이렇게 하면 | 일어나는 일 |
|---|---|
| 계획 없이 바로 고치려 함 | 차단되고, 계획 API 와 제출 방법이 안내된다 |
| 계획에 적은 범위 밖의 파일을 고치려 함 | 차단되고, 지금 걸음이 다시 안내된다 |
| 계획에 없는 스킬·도구를 호출 | 차단 |
| 셸 명령으로 범위 밖 파일을 바꿈 | 그 걸음이 끝날 때 git 비교로 잡혀 사람에게 넘어간다 |
| 안 하고 "다 했다"고 끝내려 함 | 걸음이 끝나지 않았으면 멈출 수 없다 |
| 하긴 했는데 결과가 틀림 | 게이트가 실패 → 프로그램이 정한 대로 다시 고치거나 사람에게 넘긴다 |
| `h.done()` 을 선언했지만 완료 조건이 실패 | 완료를 받아들이지 않고 새 프로그램을 요구한다 |
| 막힌 호출만 반복 / 읽기만 반복 | 상한에서 사람에게 넘긴다 (토큰을 더 쓰지 않는다) |
| 하네스 상태 파일을 고치려 함 | `.step-harness/` 와 플러그인 폴더는 쓰기 차단 |

## 프로그램 (계획 파일)

```ts
async (h) => {
  await h.work("로그인 화면에 비밀번호 표시 버튼을 추가한다", { scope: ["lib/login/**"] });
  for (const attempt of h.retries(3)) {
    const r = await h.check("unit-test");
    if (r.pass) return h.done("버튼 추가, 테스트 통과");
    await h.work(`테스트 실패를 고친다: ${r.report}`, { scope: ["lib/login/**", "test/login/**"] });
  }
  return h.handoff("3번 고쳐도 테스트가 실패합니다");
}
```

| 메서드 | 그 걸음에서 일어나는 일 | 결과 |
|---|---|---|
| `h.check(gate)` | 하네스가 `config.json` 에 등록된 그 게이트를 직접 실행한다. 에이전트는 기다리기만 한다 | `{ pass, route, report, exit }` — `report` 는 출력 파일 경로 |
| `h.work(task, { scope })` | 에이전트가 `task` 를 직접 한다. 파일 수정은 `scope` 안에서만 통과한다 | `{ ok }` |
| `h.skill(name, args, { scope })` | 에이전트가 그 스킬을 정확히 한 번 호출한다 (등록된 스킬만) | `{ ok }` |
| `h.agent(profile, task, { scope })` | 에이전트가 그 서브에이전트를 정확히 한 번 시작한다 (등록된 프로필만) | `{ ok }` |
| `h.retries(n)` | `for (const i of h.retries(n))` 로만 쓴다. n 은 1~10 | |
| `return h.done(msg)` · `return h.handoff(reason)` | 끝. 모든 경로가 둘 중 하나로 끝나야 한다 | |

모델에게는 자연어 지시 대신 이 API 의 타입 선언(등록된 이름이 리터럴 유니언으로 들어간다), 문법 규칙, 등록부로 만든 예시 하나, 제출 방법이 주어진다. 등록되지 않은 종류(게이트·스킬·서브에이전트)는 선언에 나오지 않는다.

**문법 (TypeScript 부분집합)** — `async (h) => { … }` 하나. `const` · `if/else` · `for (const i of h.retries(N))` · `break/continue` · `return` · `await h.<메서드>(…)` · 멤버 접근(`?.` 포함) · `=== !== && || !` · 문자열/템플릿/숫자/배열/객체 리터럴. 대입·`let`·`while`·함수·`import`·임의 호출·삼항·산술·`< >` 는 받지 않는다. 흔한 실수(삼항, `==`, `+`, 구조 분해, 일반 `for`, 화살표 함수)에는 대안을 적은 오류를 돌려준다. 타입 표기(`(h: H)`)와 앞뒤의 ```` ```ts ```` 울타리는 받고 무시한다.

**검증 규칙** — 모든 경로가 `return h.done(…)` 또는 `return h.handoff(…)` 로 끝난다 · 반복은 `h.retries(1..10)` 리터럴만, 겹친 반복의 곱은 1000 이하 · 게이트·스킬·서브에이전트 이름은 등록부에 있어야 한다 · 정의 안 된 이름·재정의·도달 불가 문장·`constructor` 등 위험한 속성 금지 · 걸음 수 상한 40 · 프로그램 길이 2만 자.
쓰기 걸음은 `scope` 가 필수다. `writable` 이 설정돼 있으면 그 목록에 있는 것만 쓸 수 있다. 없으면 프로그램이 고르되 **이름으로 시작하는 상대 경로**만 받는다 (`src/**` 는 되고 `**`, `*/**`, `**/*.ts`, `.git/**` 같은 전체·숨김 경로는 거부. `.step-harness` 는 어떤 경우에도 불가).

**실행** — 프로그램은 같은 결과를 받으면 같은 길로 간다. 그래서 하네스는 걸음이 끝날 때마다 결과를 기록하고(`state.json` 의 `trace`), 프로그램을 처음부터 되짚어 기록이 끝난 자리의 호출을 다음 걸음으로 삼는다. 별도의 실행 프로세스나 다른 에이전트 프로세스를 띄우지 않는다.

**제출** — 셸로 `node <plugin>/scripts/harness.cjs execute <<'EOF' … EOF` (경로는 절대 경로, 따옴표 친 heredoc 한 개. 앞뒤에 다른 명령을 붙이면 차단된다), 또는 MCP 도구 `execute`.

## 설치

```bash
# Devin
devin plugins install --local ./step-harness             # 플러그인으로 (루트의 hooks.json)
node step-harness/scripts/harness.cjs install             # 또는 이 프로젝트에만: .devin/hooks.v1.json 에 절대 경로로 등록 (--fail-closed 가능)

# Claude Code
claude --plugin-dir ./step-harness                        # 플러그인으로 (.claude-plugin/ 과 hooks/hooks.json)
```

**프로젝트에서 켜기** — `.step-harness/` 폴더가 있는 프로젝트에서 "계획 먼저"가 적용된다.

```bash
mkdir -p .step-harness && cat > .step-harness/config.json <<'EOF'
{ "gates": { "unit-test": { "cmd": "npm test", "about": "단위 테스트" } }, "done_when": ["unit-test"] }
EOF
```

- 폴더가 없는 프로젝트에서는 관여하지 않는다. 다만 프롬프트를 `프로그램: <할 일>` 로 시작하면 그 자리에서 폴더를 만들고 계획 단계를 시작하며, 그 뒤로는 그 프로젝트에도 "계획 먼저"가 적용된다.
- 에이전트가 셸로 `node <plugin>/scripts/harness.cjs …` 를 실행할 수 있어야 한다 (호스트의 권한 설정에서 허용). MCP 도구로 제출하게 하려면 그 도구도 허용한다.
- 설치 확인: 세션에서 `harness smoke` 라고 입력하면 판정 → 범위가 제한된 작업 → 재판정 → 종료까지 한 바퀴 돈다.
- `node step-harness/scripts/harness.cjs doctor` 는 지금 설정이 어떻게 해석되는지 보여준다.

기존에 같은 역할의 hook(프롬프트 라우터, 쓰기 범위 제한, Stop 에서 도는 게이트)이 있으면 한쪽만 켠다.

## 설정 (`.step-harness/config.json`, 전부 선택)

| 키 | 기본 | 뜻 |
|---|---|---|
| `plan` | `"always"` | `always`: 무엇이든 바꾸려면 먼저 프로그램을 내야 한다 (읽고 답하는 것은 자유). `prefix`: 규칙에 맞는 프롬프트(예: `프로그램: …`)에서만 |
| `gates` | 없음 | `h.check` 로 쓸 수 있는 판정 명령. `{ "이름": "명령" }` 또는 `{ "이름": { "cmd": "명령", "about": "설명" } }`. 모델에게는 이름과 설명만 보인다 |
| `done_when` | 없음 | 완료 조건. `h.done()` 뒤에 하네스가 직접 돌려 통과를 확인할 게이트 이름 목록 |
| `skills` · `agents` | 없음 | `h.skill` · `h.agent` 로 쓸 수 있는 스킬과 서브에이전트 프로필. `{ "이름": "설명" }`. 없으면 프로그램은 `h.work` 만 쓸 수 있다 |
| `writable` | 없음 | 걸음의 `scope` 로 쓸 수 있는 글로브 목록. 없으면 프로그램이 고른다 (전체·숨김 경로는 거부) |
| `work_shell` | true | 작업 걸음에서 셸 명령을 허용할지. 허용하면 걸음이 끝날 때 범위 밖 변경을 git 으로 확인한다 |
| `work_mcp` | true | 작업 걸음에서 MCP 도구 호출을 허용할지. 입력에 파일 경로가 보이면 `scope` 를 지키게 한다 |
| `exec_allow` | 없음 | 작업 걸음에서 허용할 셸 명령의 정규식 목록 (명령의 처음부터 맞아야 하고, `; & \| >` 가 있으면 거부) |
| `scope_check` | true | 파일을 바꿀 수 있는 걸음이 끝날 때 git 으로 걸음 전과 비교해 범위 밖 변경을 잡는다 (git 저장소일 때만) |
| `explore_tools` | `[]` | 계획 없이도 써도 되는 도구 이름. 기본으로는 읽기 도구만 계획 없이 통과한다 (예: 조사용 서브에이전트를 허용하려면 `["run_subagent"]`) |
| `passive_tools` | `[]` | 계획 전에도, 걸음 도중에도 언제든 써도 되는 읽기 전용 도구 이름 (예: 문서를 찾아 주는 MCP 도구 `mcp__docs__search`) |
| `subagent_hooks` | `same` | 서브에이전트의 도구 호출이 hook 에 어떻게 보이는가 (`same` · `foreign` · `none`). 아래 "호스트" 참고 |
| `wait` | `{prompt:5, post:8, stop:20}` | 각 hook 이 판정 완료를 기다리는 최대 초 |
| `check_wait_sec` | 30 | `check` 한 번이 기다리는 시간. 넘으면 STILL RUNNING 을 찍고 끝난다 (다시 부르면 이어진다) |
| `auto_approve_cli` | false | (Devin) 하네스 CLI 실행의 승인 프롬프트를 PermissionRequest hook 으로 생략 |
| `assume_done_on_stop` | false | 위임 도구의 결과 이벤트가 오지 않는 환경용. 멈추려는 시점에 "호출됨"으로 친다 |

### 게이트(판정 명령)의 계약

1. exit 0 = 통과, 그 외 = 실패.
2. 실패 시 stdout 에 `HARNESS_ROUTE=<종류>` 한 줄을 찍으면 프로그램이 `r.route` 로 받아 분기할 수 있다.

출력 전체는 `.step-harness/reports/<게이트>.txt` 에 저장되고, 프로그램은 그 경로를 `r.report` 로 받는다. 기존 검사를 감싸는 예: `templates/gate-wrapper.sh`.
판정은 hook·CLI 와 분리된 프로세스로 돈다. 그래서 몇 분이 걸려도 hook 시간 제한에 걸리지 않고, `check` 를 여러 번 불러도 한 번만 실행된다.

### 규칙 (`.step-harness/router.json`, 선택)

프롬프트의 모양에 따라 과제 문장이나 완료 조건을 정해 두고 싶을 때만 쓴다. 규칙에 맞으면 프롬프트를 받는 즉시 계획 단계가 시작되고, 프로그램을 낼 때까지 멈출 수 없다.

```json
{ "routes": [ { "name": "code complete", "when": "^/?cc\\b",
                "program": { "task": "코드 컴플리트 게이트를 통과시킨다", "done_when": ["code-complete"] } } ] }
```

`when` 은 프롬프트에 대한 정규식이다. `task` 의 `$1` 은 캡처 그룹이다. 두 규칙이 걸리면 시작하지 않고 되묻게 한다. 예시는 `router.example.json`.

### 스킬은 서브에이전트로

스킬을 본문에 펼치기만 하면 "부르기만 하고 안 따름"이 생긴다. 스킬이 별도 서브에이전트에서 실행되게 해 두면(Devin: 스킬 프런트매터의 `agent: <프로필>`) 프롬프트를 받은 에이전트는 지침을 해석할 기회가 없고, 결과는 게이트가 판정한다. 예: `agents/fixer.md`, `templates/skills/eats-write-unit-test/SKILL.md`.

## 사람에게 넘어왔을 때

하네스가 멈추고 질문을 전하면 한 단어로 답한다 (`harness stop` 은 언제든 흐름을 끝낸다. `harness status` 는 지금 상태를 보여준다).

| 넘어온 이유 | `retry` | `proceed` |
|---|---|---|
| 프로그램이 `h.handoff()` 로 넘김 · 프로그램 거부나 완료 조건 실패가 한도를 넘음 | 새 프로그램을 받는다 | 사람이 끝난 것으로 인정한다 |
| 걸음 도중에 막힘 (차단 반복 · 멈춤 시도 반복 · 범위 밖 변경) | 그 걸음을 다시 한다 (지금의 파일 상태가 새 기준) | 그 걸음을 통과로 치고 프로그램을 이어 간다 |

## CLI (`node scripts/harness.cjs …`)

| 누가 | 명령 |
|---|---|
| 에이전트 (hook 이 이것만 통과시킨다) | `plan` · `search [q]` · `execute` · `check [--wait N]` · `next` · `status` |
| 사람 | `resume [--proceed]` · `reset` · `install [--fail-closed]` · `uninstall` · `probe on\|off` · `doctor [--apply]` |

MCP 서버 `scripts/mcp.cjs` 는 같은 일을 도구(`plan` · `search` · `execute` · `check`)로 내놓는다. 플러그인 루트의 `.mcp.json` 으로 등록된다. 서버는 프로젝트 폴더를 환경변수 → 클라이언트가 알려준 작업 폴더(MCP roots) → 자신의 cwd 순으로 찾고, 확인하지 못하면 실행하지 않고 셸 명령을 안내한다.

## 호스트

hook 과 도구 이름만 쓰므로 특정 호스트에 묶이지 않는다. 도구 이름은 내부 이름으로 맞춰 본다 (`Write`→`write`, `Bash`→`exec`, `Agent`→`run_subagent` …). 대상 모델은 Opus 4.6 수준을 기준으로 했다.

| 호스트 | 상태 |
|---|---|
| Claude Code | 실제 세션에서 확인 (2026-11-25, `claude-opus-4-6`, `claude -p --plugin-dir`): 질문에는 계획 없이 답함 · 계획 없는 쓰기는 차단 후 프로그램 제출로 이어짐 · 프로그램 제출 → 작업 걸음 → 게이트 → 완료 |
| Devin | 실제 세션에서는 아직 확인하지 못했다. hook 입력 형식은 문서 기준으로 맞췄고 테스트로 흉내 낸다 |

Devin 에서 처음 쓸 때는 `harness.cjs probe on` → 안내되는 프롬프트 실행 → `doctor --apply` 로 다음을 확인한다.

1. **서브에이전트의 도구 호출이 hook 에 어떻게 보이는가** → `subagent_hooks`. `same`(메인과 같은 세션으로 보임, 기본값)이면 스킬·서브에이전트 걸음이 진행되는 동안에는 범위 안의 호출을 구분 없이 통과시킨다.
2. **스킬·서브에이전트 도구의 실제 입력 이름** → 하네스는 값이 같은지로 대조하므로 이름이 달라도 동작한다.
3. **위임 도구의 결과 이벤트가 서브에이전트 종료 뒤에 오는가** → 먼저 오면 걸음이 일찍 끝난 것으로 기록된다.
4. **플러그인 루트 변수** → 안 풀리면 `harness.cjs install` (절대 경로) 을 쓴다.

Devin 문서에 따르면 플러그인으로 설치한 hook 은 로드·실행에 실패해도 세션이 그대로 진행된다(fail-open). 강제가 중요하면 `harness.cjs install --fail-closed` 로 프로젝트 hook 을 쓴다.

## 한계

- **강제는 hook 이 걸려 있어야 성립한다.** hook 이 로드되지 않으면 아무것도 막지 않는다.
- **게이트가 없으면 결과를 코드로 확인할 수 없다.** 하네스는 순서와 범위를 강제하지만, 결과가 맞는지는 등록된 판정 명령이 있어야 안다. `done_when` 이 없으면 `h.done()` 을 그대로 받아들인다.
- **셸 명령이 바꾸는 파일은 hook 이 볼 수 없다.** 그래서 걸음이 끝날 때 git 으로 걸음 전과 비교한다 (커밋까지 한 변경, `assume-unchanged` 로 숨긴 변경, 자기 자신을 숨기는 `.gitignore` 도 잡는다). 이 검사는 git 저장소에서만 동작하고, git 이 무시하는 파일은 보지 못한다: 이미 `.gitignore` 에 올라 있는 경로(`node_modules/` 등)와 자기 자신을 무시하는 새 폴더(캐시 폴더와 같은 모양) 안. 프로젝트 안의 다른 git 저장소(하위 모듈)는 폴더 단위로만 본다. 걸음이 진행되는 동안 사람이 범위 밖 파일을 고치면 그 걸음에서 바뀐 것으로 본다.
- **계획 전에 허용되는 것은 목록 기반이다.** 도구는 읽기만 한다고 아는 것만 통과한다: MCP 도구와 모르는 도구는 무엇을 바꾸는지 알 수 없어 계획을 요구한다 (읽기 전용이면 `passive_tools` 에 등록한다). 셸은 `ls` · `cat` · `grep` · `git status` 같은 읽기 명령과 그것을 `|` 로 이은 것만 통과한다 (따옴표를 벗긴 뒤의 낱말로 판단하고, `find` · `git` 처럼 위험한 옵션이 있는 명령에는 따옴표 없는 와일드카드도 받지 않는다). 목록에 없는 명령은 읽기만 하더라도 계획을 요구한다.
- **하네스 파일 보호는 문자열 검사다.** 작정하고 경로를 돌려 쓰는 셸 명령까지 막지는 못한다. 대상은 악의가 아니라 지시를 따르지 않는 모델이다.
- **서브에이전트 구분은 호스트에 달려 있다.** 서브에이전트의 호출이 메인과 같은 세션으로 보이는 호스트에서는, 스킬·서브에이전트 걸음이 진행되는 동안 메인의 범위 안 호출도 통과한다.
- 걸음은 차례대로만 실행된다 (병렬 없음). 판정 명령은 호스트 프로세스의 환경변수로 돈다. macOS / Linux 전용.

## 파일

- `<project>/.step-harness/` — `config.json` `router.json` (커밋 대상) · `program.ts` `flow.json` `state.json` `judge.json` `receipts.jsonl` `log.jsonl` `reports/` (실행 상태. `.gitignore` 가 자동으로 만들어진다)
- 플러그인 — `scripts/` (hook · CLI · 실행기 · MCP 서버) · `hooks.json` (Devin) · `hooks/hooks.json` (Claude Code) · `.mcp.json` · `router.json` (기본 규칙: `harness smoke`, `프로그램: …`)
- 강제 엔진은 "액션"(판정 · 정확히 한 번의 도구 호출 · 범위가 제한된 작업)의 상태 기계다. 프로그램의 걸음은 이 액션으로 바뀌어 실행된다. 액션을 파일로 직접 주는 형식(`flows/smoke.flow.yaml`, `test/fixtures/`)은 설치 확인과 엔진 시험에만 쓴다.

## 테스트

```bash
bash test/run-tests.sh            # hook 입력 시뮬레이션(Devin · Claude Code 형식) + 실제 백그라운드 판정 프로세스
VERBOSE=1 bash test/run-tests.sh  # 케이스 이름 표시
```
