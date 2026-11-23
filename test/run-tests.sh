#!/usr/bin/env bash
# step-harness 시나리오 테스트 — 실제 hook stdin 과 실제 백그라운드 판정 프로세스로 전 경로를 검증한다.
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
export HOOK="$HERE/scripts/hook.cjs"; CLI="$HERE/scripts/harness.cjs"
pass=0; fail=0
ok()  { pass=$((pass+1)); [ "${VERBOSE:-}" ] && echo "  ok   $1"; return 0; }
bad() { fail=$((fail+1)); echo "  FAIL $1"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }
has() { if grep -qF -- "$3" <<<"$2"; then ok "$1"; else bad "$1 (missing '$3' in: ${2:0:300})"; fi; }
hasnt() { if grep -qF -- "$3" <<<"$2"; then bad "$1 (unexpected '$3')"; else ok "$1"; fi; }
hook() { printf '%s' "$1" | DEVIN_PROJECT_DIR="$W" node "$HOOK" 2>/dev/null; }
expect() { local code; printf '%s' "$3" | DEVIN_PROJECT_DIR="$W" node "$HOOK" >/dev/null 2>&1; code=$?; if [ "$code" = "$2" ]; then ok "$1"; else bad "$1 (exit=$code, want $2)"; fi; }
OKR='{"success":true,"output":"ok","error":null}'
pre()  { printf '{"hook_event_name":"PreToolUse","session_id":"%s","prompt_id":"%s","tool_name":"%s","tool_input":%s}' "$1" "$2" "$3" "$4"; }
post() { printf '{"hook_event_name":"PostToolUse","session_id":"%s","prompt_id":"%s","tool_name":"%s","tool_input":%s,"tool_response":%s}' "$1" "$2" "$3" "$4" "${5:-$OKR}"; }
ups()  { printf '{"hook_event_name":"UserPromptSubmit","session_id":"%s","prompt_id":"%s","prompt":"%s"}' "$1" "$2" "$3"; }
stopev() { printf '{"hook_event_name":"Stop","session_id":"%s","prompt_id":"%s","stop_hook_active":false}' "$1" "$2"; }
st() { node -e 'const s=JSON.parse(require("fs").readFileSync(process.argv[1]+"/.step-harness/state.json","utf8"));console.log(eval(process.argv[2]))' "$W" "$1"; }
jq_() { node -e 'const s=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));console.log(eval(process.argv[2]))' "$1" "$2"; }
SK='{"skill":"eats-write-unit-test","args":".step-harness/last-report.txt"}'
EDIT_IN='{"file_path":"lib/a.dart","old":"a","new":"b"}'
EDIT_OUT='{"file_path":"README.md","old":"a","new":"b"}'
chk() { printf '{"command":"node \\"%s\\" %s"}' "$CLI" "$1"; }

ws() {   # 새 작업 폴더: 가짜 게이트 + 라우터
  W="$(mktemp -d)"; cd "$W"; mkdir -p .step-harness lib test
  cat > gate.sh <<'G'
n=$(cat .gate_runs 2>/dev/null || echo 0); echo $((n+1)) > .gate_runs
[ -f .gate_sleep ] && sleep "$(cat .gate_sleep)"
if [ -f .gate_ok ]; then echo "all good"; exit 0; fi
echo "FAIL: 2 tests missing"
echo "HARNESS_ROUTE=$(cat .route 2>/dev/null || echo unit-test)"
exit 1
G
  node -e 'const fs=require("fs");const f=JSON.parse(fs.readFileSync(process.argv[1]+"/flows/code-complete.flow.json","utf8"));
    fs.writeFileSync("cc.flow.json",JSON.stringify({...f,max_blocks:60,max_idle_calls:60}));
    fs.writeFileSync("cc1.flow.json",JSON.stringify({...f,max_visits:1,max_blocks:60}));' "$HERE"
  cat > .step-harness/router.json <<J
{ "routes": [
  { "name": "cc", "when": "^코드 컴플리트 돌려", "flow": "cc.flow.json", "args": { "gate": "bash gate.sh" } },
  { "name": "cc1", "when": "^한번만 코드 컴플리트", "flow": "cc1.flow.json", "args": { "gate": "bash gate.sh" } },
  { "name": "cc-strict", "when": "^엄격", "flow": "$HERE/flows/code-complete.flow.yaml", "args": { "gate": "bash gate.sh" } },
  { "name": "delegate", "when": "^fix: (\\\\S+)", "flow": "$HERE/flows/delegate.flow.yaml", "args": { "target": "\$1", "verify": "bash gate.sh" } },
  { "name": "both-a", "when": "모호", "flow": "cc.flow.json", "args": { "gate": "true" } },
  { "name": "both-b", "when": "모호", "flow": "cc1.flow.json", "args": { "gate": "true" } }
] }
J
  echo '{"wait":{"prompt":4,"post":4,"stop":4}}' > .step-harness/config.json
}
cfg() { echo "$1" > .step-harness/config.json; }
exhaust() { for _ in $(seq 1 "$1"); do hook "$(pre s1 p1 skill "$SK")" >/dev/null; LAST=$(hook "$(post s1 p1 skill "$SK")"); done; }

echo "[yaml] 내장 파서"
if node - "$HERE" <<'N'
const Y = require(process.argv[2] + '/scripts/yaml.cjs'); const assert = require('assert');
const eq = (y, v) => assert.deepStrictEqual(Y.parse(y), v);
eq('a: 1\nb: [x, "y z", 3]\nc:\n  - k: v\n    m: {p: q, "*": r}\n  - plain\nd: |\n  line1\n  line2\ne: >-\n  folded\n  text\nf: "q: # not comment"  # comment\ng: null\nh: true\n',
  { a: 1, b: ['x', 'y z', 3], c: [{ k: 'v', m: { p: 'q', '*': 'r' } }, 'plain'], d: 'line1\nline2\n', e: 'folded text', f: 'q: # not comment', g: null, h: true });
eq('- a\n- b: 1\n  c: 2\n-\n  d: 3\n', ['a', { b: 1, c: 2 }, { d: 3 }]);
eq('key:\n- x\n- y\nother: z\n', { key: ['x', 'y'], other: 'z' });
eq('m: {\n  a: 1,\n  b: [1, 2]\n}\nn: []\n', { m: { a: 1, b: [1, 2] }, n: [] });
eq("s: 'it''s'\nt: don't stop # c\nu: http://x.y/z\nv: test -n \"$(git status --porcelain -- . ':!x')\"\n", { s: "it's", t: "don't stop", u: 'http://x.y/z', v: 'test -n "$(git status --porcelain -- . \':!x\')"' });
eq('---\n# only comments\n\nx:\n  y:\n    z: -1.5\n', { x: { y: { z: -1.5 } } });
for (const bad of ['a:\n\tb: 1', 'a: &x 1', 'a: 1\n  b: 2', 'a: [1, 2', 'a: "x']) assert.throws(() => Y.parse(bad), /YAML \d+행/);
N
then ok "yaml 파서 단위 테스트"; else bad "yaml 파서 단위 테스트"; fi

echo "[lint]"
ws
cat > bad.flow.json <<'J'
{ "flow": "bad", "args": ["x"], "start": "nope", "passive": ["edit"], "typo": 1,
  "actions": {
    "a": { "tool": "foo", "params": {"p": "{y}"}, "deny": ["zzz"], "untl": "x", "on": { "fail": "ghost" } },
    "b": { "tool": "skill", "work": "do", "on": { "pass": "done" } },
    "c": { "on": { "pass": "a" } },
    "d": { "tool": "skill", "params": {"skill": "s"}, "rewrite": ["args"], "allow": ["edit"], "on": { "pass": "done", "fail": { "*": "nowhere" } } },
    "done": { "check": "true", "on": { "pass": "done" } } } }
J
out=$(node "$CLI" lint bad.flow.json); is "lint 실패 exit" "$?" 1
for pat in '"start" 가 actions 에 없음' 'passive: edit 는 passive 에 둘 수 없음' '알 수 없는 최상위 키 "typo"' '알 수 없는 도구 "foo"' 'deny: 알 수 없는 도구 zzz' \
  '알 수 없는 키 "untl"' 'on.pass 필요' 'tool 과 work 는 함께 쓸 수 없음' 'tool / work / check 중 하나 필요' 'rewrite: params 에 없는 키 "args"' \
  'allow 는 work 액션 전용' '없는 액션 "nowhere"' 'args 에 없는 인자 {y}' '"done" 는 예약어'; do has "lint: $pat" "$out" "$pat"; done
out=$(node "$CLI" start cc.flow.json); has "인자 누락" "$out" 'missing args: gate'

echo "[A] 라우터 → 게이트 자동 판정 → 수정 액션"
out=$(hook "$(ups s1 p1 '모호한 요청')"); has "규칙 2개 일치 → 되묻기" "$out" 'more than one flow'
[ ! -f .step-harness/state.json ] && ok "모호하면 시작하지 않음" || bad "모호한데 시작함"
out=$(hook "$(ups s1 p1 '아무 관련 없는 말')"); is "규칙 불일치 → 출력 없음" "$out" ""
expect "흐름 없을 때 edit 허용" 0 "$(pre s1 p1 edit "$EDIT_IN")"
expect "흐름 없어도 .step-harness 쓰기는 차단" 2 "$(pre s1 p1 write '{"file_path":".step-harness/router.json","content":"{}"}')"
out=$(hook "$(ups s1 p1 '코드 컴플리트 돌려줘')")
has "RESOLVED_ACTION" "$out" 'RESOLVED_ACTION: flow=code_complete'
has "hook 이 게이트를 직접 돌리고 수정 액션까지 진행" "$out" 'action=fix_tests (attempt 1/3)'
has "NEXT_ACTION = skill" "$out" 'tool: skill'
has "params 에 리포트 경로" "$out" '.step-harness/last-report.txt'
is "게이트 1회 실행" "$(cat .gate_runs)" 1
is "상태: fix_tests" "$(st s.action)" fix_tests
[ -s .step-harness/last-report.txt ] && ok "리포트 저장" || bad "리포트 없음"
out=$(hook "$(ups s1 p2 '다른 얘기')"); has "진행 중엔 매 프롬프트에 NEXT_ACTION 주입" "$out" 'tool: skill'

echo "[B] 게이트: NEXT_ACTION 만 통과"
expect "edit → 차단" 2 "$(pre s1 p2 edit "$EDIT_IN")"
expect "Claude 별칭 Edit → 차단" 2 "$(pre s1 p2 Edit "$EDIT_IN")"
expect "exec → 차단" 2 "$(pre s1 p2 exec '{"command":"flutter test"}')"
expect "webfetch → 차단" 2 "$(pre s1 p2 webfetch '{"url":"https://x"}')"
expect "mcp 도구 → 차단" 2 "$(pre s1 p2 mcp__github__create_issue '{"title":"x"}')"
expect "read 허용" 0 "$(pre s1 p2 read '{"file_path":"lib/a.dart"}')"
expect "ask_user_question 허용" 0 "$(pre s1 p2 ask_user_question '{"question":"?"}')"
expect "다른 skill → 차단" 2 "$(pre s1 p2 skill '{"skill":"other","args":".step-harness/last-report.txt"}')"
expect "args 다른 skill → 차단" 2 "$(pre s1 p2 skill '{"skill":"eats-write-unit-test","args":"something else"}')"
expect ".step-harness/state.json 쓰기 → 차단" 2 "$(pre s1 p2 write '{"file_path":".step-harness/state.json","content":"{}"}')"
expect "harness check 허용" 0 "$(pre s1 p2 exec "$(chk check)")"
expect "harness check --wait 허용" 0 "$(pre s1 p2 exec "$(chk 'check --wait 20')")"
expect "harness reset(모델) → 차단" 2 "$(pre s1 p2 exec "$(chk reset)")"
expect "harness check; 체이닝 → 차단" 2 "$(pre s1 p2 exec "{\"command\":\"node \\\"$CLI\\\" check; rm -rf lib\"}")"
mkdir -p fake && echo 'console.log(1)' > fake/harness.cjs
expect "가짜 harness.cjs → 차단" 2 "$(pre s1 p2 exec '{"command":"node fake/harness.cjs check"}')"
out=$(node "$CLI" check); has "receipt 없이 check → NOT DONE" "$out" 'NOT DONE'; is "상태 그대로" "$(st s.action)" fix_tests
out=$(printf '%s' "$(pre s1 p2 edit "$EDIT_IN")" | DEVIN_PROJECT_DIR="$W" node "$HOOK" 2>&1 >/dev/null)
has "차단 사유가 stderr 로도 나감" "$out" 'BLOCKED edit'; has "차단 메시지에 NEXT_ACTION 재출력" "$out" 'tool: skill'
expect "키 이름이 달라도 값이 같으면 NEXT_ACTION" 0 "$(pre s1 p2 skill '{"name":"eats-write-unit-test","arguments":".step-harness/last-report.txt"}')"
is "실행 구간 시작" "$(st '!!s.inFlight')" true
expect "[실행 중] 범위 안 edit 허용" 0 "$(pre s1 p2 edit '{"file_path":"test/a_test.dart"}')"
expect "[실행 중] 범위 밖 edit → 차단" 2 "$(pre s1 p2 edit "$EDIT_OUT")"
expect "[실행 중] 절대경로 범위 안 허용" 0 "$(pre s1 p2 write "{\"file_path\":\"$W/lib/b.dart\",\"content\":\"x\"}")"
expect "[실행 중] 상위 경로 탈출 → 차단" 2 "$(pre s1 p2 write '{"file_path":"lib/../../etc/x","content":"x"}')"
expect "[실행 중] apply_patch 범위 밖 → 차단" 2 "$(pre s1 p2 apply_patch '{"patch":"*** Begin Patch\n*** Update File: pubspec.yaml\n@@\n-a\n+b\n*** End Patch"}')"
expect "[실행 중] apply_patch 범위 안 허용" 0 "$(pre s1 p2 apply_patch '{"patch":"*** Begin Patch\n*** Add File: lib/x.dart\n+a\n*** End Patch"}')"
expect "[실행 중] 경로를 알 수 없는 쓰기 → 차단" 2 "$(pre s1 p2 write '{"weird_key":"lib/a.dart","content":"x"}')"
expect "[실행 중] 리포트 cat 허용" 0 "$(pre s1 p2 exec '{"command":"cat .step-harness/last-report.txt"}')"
expect "[실행 중] .step-harness 덮어쓰기 → 차단" 2 "$(pre s1 p2 exec '{"command":"echo x > .step-harness/state.json"}')"
touch .gate_ok
out=$(hook "$(post s1 p2 skill "$SK")")
has "receipt 뒤 게이트 자동 재실행 → DONE" "$out" 'DONE: code complete gate passed'
is "status done" "$(st s.status)" done
is "게이트 2회" "$(cat .gate_runs)" 2
grep -q '"action":"fix_tests"' .step-harness/receipts.jsonl && ok "receipts.jsonl 은 hook 이 기록" || bad "receipt 파일 없음"
expect "done 뒤 edit 허용" 0 "$(pre s1 p2 edit "$EDIT_OUT")"
out=$(hook "$(stopev s1 p2)"); is "done 뒤 Stop 허용" "$out" ""
out=$(hook "$(ups s1 p3 '코드 컴플리트 돌려줘')"); has "게이트가 이미 통과면 바로 DONE" "$out" 'DONE:'; is "수정 액션 없이 끝" "$(st 'JSON.stringify(s.visits)')" '{}'

echo "[C] 계속 실패 → 재시도 한도 → 사람에게"
ws
hook "$(ups s1 p1 '코드 컴플리트 돌려줘')" >/dev/null
for n in 1 2 3; do is "수정 ${n}회차" "$(st s.visits.fix_tests)" "$n"; exhaust 1; done
has "3회 실패 → PAUSED" "$LAST" 'PAUSED'
has "턴을 코드로 종료(stop 필드)" "$LAST" '"stop":"[code_complete]'
is "status handoff" "$(st s.status)" handoff
is "handoff 지점 = 게이트" "$(st s.handoff.from)" gate
is "게이트 4회(매 수정 뒤 재판정)" "$(cat .gate_runs)" 4
expect "같은 턴 edit → 차단" 2 "$(pre s1 p1 edit "$EDIT_IN")"
expect "같은 턴 skill → 차단" 2 "$(pre s1 p1 skill "$SK")"
expect "같은 턴 read 허용" 0 "$(pre s1 p1 read '{"file_path":"lib/a.dart"}')"
out=$(hook "$(stopev s1 p1)"); is "handoff 뒤 Stop 허용" "$out" ""
expect "다음 턴 edit 허용(사람이 주도)" 0 "$(pre s1 p2 edit "$EDIT_IN")"
out=$(hook "$(ups s1 p2 '진행 상황 알려줘')"); has "키워드가 아닌 말은 답으로 치지 않음" "$out" 'is paused'; is "handoff 유지" "$(st s.status)" handoff
out=$(hook "$(ups s1 p3 'retry')"); is "retry → 게이트 재판정 → 수정 1회차" "$(st s.action):$(st s.visits.fix_tests)" "fix_tests:1"
has "retry 뒤 NEXT_ACTION" "$out" 'tool: skill'
exhaust 3; is "다시 소진 → handoff" "$(st s.status)" handoff
out=$(hook "$(ups s9 p9 '진행')"); is "새 세션에서 온 '진행' → 통과 처리" "$(st s.status)" done
ws; hook "$(ups s1 p1 '한번만 코드 컴플리트')" >/dev/null; exhaust 1; is "max_visits=1 → 1회 뒤 handoff" "$(st s.status)" handoff
out=$(hook "$(ups s1 p2 '중단.')"); is "'중단' → stopped" "$(st s.status)" stopped
expect "stopped 뒤 edit 허용" 0 "$(pre s1 p2 edit "$EDIT_OUT")"

echo "[D] 느린 게이트: check 는 끊겼다 이어져도 판정은 한 번"
ws; cfg '{"wait":{"prompt":0,"post":0,"stop":0}}'; echo 2 > .gate_sleep
out=$(node "$CLI" start cc.flow.json gate='bash gate.sh'); has "judge 로 시작 → NEXT_ACTION 은 check" "$out" ' check"}'
out=$(node "$CLI" check --wait 1); has "아직 판정 중 → STILL RUNNING" "$out" 'STILL RUNNING'
node "$CLI" check --wait 1 >/dev/null & node "$CLI" check --wait 1 >/dev/null & wait
out=$(node "$CLI" check --wait 8); has "판정 결과 출력" "$out" 'FAILED: gate (route=unit-test)'; has "다음 액션 출력" "$out" 'tool: skill'
is "check 를 여러 번·동시에 불러도 게이트는 1회" "$(cat .gate_runs)" 1
hook "$(pre s1 p1 skill "$SK")" >/dev/null; out=$(hook "$(post s1 p1 skill "$SK")")
has "wait 0: hook 은 기다리지 않고 check 지시" "$out" 'check\"'
out=$(hook "$(stopev s1 p1)"); has "판정 중 Stop → 차단" "$out" 'verification is still running'; is "판정 중 차단은 횟수에 안 넣음" "$(st 's.stopBlocks||0')" 0
sleep 2.5; out=$(hook "$(ups s1 p2 '어떻게 됐어')"); has "끝난 판정은 다음 hook 이 반영" "$out" 'attempt 2/3'

echo "[E] Stop hook"
ws; hook "$(ups s1 p1 '코드 컴플리트 돌려줘')" >/dev/null
out=$(hook "$(stopev s1 p1)"); has "할 일 남음 → Stop 차단" "$out" '"decision":"block"'; has "차단 사유에 NEXT_ACTION" "$out" 'tool: skill'
cfg '{"wait":{"prompt":4,"post":0,"stop":4}}'; touch .gate_ok
hook "$(pre s1 p1 skill "$SK")" >/dev/null; hook "$(post s1 p1 skill "$SK")" >/dev/null
out=$(hook "$(stopev s1 p1)"); has "Stop hook 이 판정을 기다렸다 직접 done 처리 + 결과 보고 지시" "$out" 'DONE: code complete gate passed'; is "status done" "$(st s.status)" done
out=$(hook "$(stopev s1 p1)"); is "그 다음 Stop 은 통과" "$out" ""
ws; hook "$(ups s1 p1 '코드 컴플리트 돌려줘')" >/dev/null
for _ in 1 2 3; do hook "$(stopev s1 p1)" >/dev/null; sleep 0.9; done
out=$(hook "$(stopev s1 p1)"); has "Stop 4회째 → 종료 허용 + 사유 표시" "$out" '"stop":'; hasnt "더는 막지 않음" "$out" '"decision":"block"'
is "무한 루프 대신 handoff" "$(st s.status)" handoff

echo "[F] 차단·읽기 반복 상한"
ws; hook "$(ups s1 p1 '엄격 코드 컴플리트')" >/dev/null; is "YAML flow 로 시작" "$(st s.action)" fix_tests
for i in 1 2 3 4 5; do expect "차단 $i" 2 "$(pre s1 p1 edit "{\"file_path\":\"lib/$i.dart\"}")"; done
out=$(hook "$(pre s1 p1 edit '{"file_path":"lib/6.dart"}')"); has "6번째 차단 → PAUSED" "$out" 'PAUSED'; is "handoff" "$(st s.status)" handoff
has "차단 응답에도 턴 종료 요청" "$out" '"stop":'
out=$(hook "$(pre s1 p1 read '{"file_path":"lib/a.dart"}')"); has "같은 턴의 다음 호출에서도 턴 종료" "$out" '"stop":'
out=$(hook "$(pre s1 p2 read '{"file_path":"lib/a.dart"}')"); is "다음 턴에는 턴 종료를 요청하지 않음" "$out" ""
ws; hook "$(ups s1 p1 '엄격 코드 컴플리트')" >/dev/null
for i in $(seq 1 15); do hook "$(pre s1 p1 read "{\"file_path\":\"lib/$i.dart\"}")" >/dev/null; done
expect "읽기만 16번째 → 차단" 2 "$(pre s1 p1 read '{"file_path":"lib/16.dart"}')"
hook "$(pre s1 p1 edit "$EDIT_IN")" >/dev/null; printf '%s' "$(pre s1 p1 edit "$EDIT_IN")" | STEP_HARNESS_HOOK=1 DEVIN_PROJECT_DIR="$W" node "$HOOK" >/dev/null 2>&1
is "hook 중복 설치(다른 설치본이 같은 이벤트를 또 받음): 막되 한 번만 셈" "$?:$(st s.blocks)" "2:2"
hook "$(pre s1 p1 edit "$EDIT_IN")" >/dev/null; is "같은 설치본이 받은 반복 호출은 매번 셈" "$(st s.blocks)" 3

echo "[H] 세션 구분"
ws; hook "$(ups s1 p1 '코드 컴플리트 돌려줘')" >/dev/null; hook "$(pre s1 p1 skill "$SK")" >/dev/null
expect "[same] 실행 중 메인 edit 은 구분 불가 → 통과" 0 "$(pre s1 p1 edit "$EDIT_IN")"
expect "다른 session_id 의 범위 안 edit 허용" 0 "$(pre s2 q1 edit "$EDIT_IN")"
is "다른 세션 관측은 기록만 (자동으로 모드를 바꾸지 않음)" "$(jq_ .step-harness/caps.json '!!s.foreign_seen')" true
expect "[same 유지] 실행 중 메인 edit 여전히 통과" 0 "$(pre s1 p1 edit "$EDIT_IN")"
is "서브에이전트 이벤트는 턴 기록을 바꾸지 않음" "$(st s.lastPromptId)" p1
cfg '{"subagent_hooks":"foreign","wait":{"prompt":4,"post":4,"stop":4}}'
expect "[foreign 설정] 실행 중 메인 edit → 차단" 2 "$(pre s1 p1 edit "$EDIT_IN")"
expect "[foreign 설정] 작업자(다른 세션) 범위 안 edit 허용" 0 "$(pre s2 q1 edit "$EDIT_IN")"
expect "[foreign] 작업자 범위 밖 → 차단" 2 "$(pre s2 q1 edit "$EDIT_OUT")"
out=$(hook "$(ups s2 q1 '서브에이전트 프롬프트')"); is "실행 중 다른 세션 프롬프트에는 주입 안 함" "$out" ""
out=$(hook "$(stopev s2 q1)"); is "서브에이전트의 Stop 은 막지 않음" "$out" ""
hook "$(post s2 q1 skill "$SK")" >/dev/null; is "다른 세션의 PostToolUse 는 receipt 가 아님" "$(st '!!s.receipt')" false
hook "$(post s1 p1 skill "$SK")" >/dev/null; is "메인의 PostToolUse → 재판정 → 2회차" "$(st s.visits.fix_tests)" 2
expect "실행 구간 밖 다른 세션 edit → 차단" 2 "$(pre s2 q1 edit "$EDIT_IN")"
expect "실행 구간 밖 다른 세션 read 허용" 0 "$(pre s2 q1 read '{"file_path":"lib/a.dart"}')"
out=$(hook "$(ups s3 r1 '새 세션에서 이어서')"); has "새 세션의 프롬프트 → 그 세션이 메인" "$out" 'tool: skill'; is "메인 재지정" "$(st s.mainSession)" s3
ws; cfg '{"subagent_hooks":"none","wait":{"prompt":4,"post":4,"stop":4}}'
hook "$(ups s1 p1 '코드 컴플리트 돌려줘')" >/dev/null; hook "$(pre s1 p1 skill "$SK")" >/dev/null
expect "[none] 실행 중 hook 에 보이는 edit 은 전부 메인 → 차단" 2 "$(pre s1 p1 edit "$EDIT_IN")"

echo "[I] work 액션 (메인이 직접, 범위 제한)"
ws; echo lint > .route
out=$(hook "$(ups s1 p1 '코드 컴플리트 돌려줘')"); has "route=lint → fix_direct" "$out" 'action=fix_direct'; has "WORK 지시" "$out" 'WORK — do this yourself'
expect "범위 안 edit 허용" 0 "$(pre s1 p1 edit "$EDIT_IN")"
expect "범위 밖 edit → 차단" 2 "$(pre s1 p1 edit "$EDIT_OUT")"
expect "allow 에 없는 exec → 차단" 2 "$(pre s1 p1 exec '{"command":"dart format ."}')"
expect "skill → 차단" 2 "$(pre s1 p1 skill "$SK")"
out=$(node "$CLI" check); has "수정 없이 check → NOT DONE" "$out" 'nothing has been changed'
hook "$(post s1 p1 edit "$EDIT_IN")" >/dev/null; is "수정 receipt" "$(st s.receipt.mutations)" 1
touch .gate_ok; out=$(node "$CLI" check --wait 8); has "check → 게이트 → DONE" "$out" 'DONE:'
ws; echo lint > .route; hook "$(ups s1 p1 '코드 컴플리트 돌려줘')" >/dev/null
out=$(hook "$(stopev s1 p1)"); has "수정 없이 멈추려 함 → 차단" "$out" 'WORK — do this yourself'
hook "$(pre s1 p1 edit "$EDIT_IN")" >/dev/null; hook "$(post s1 p1 edit "$EDIT_IN")" >/dev/null; touch .gate_ok
out=$(hook "$(stopev s1 p1)"); has "수정 뒤 멈추면 hook 이 게이트를 돌려 done" "$out" 'DONE:'; is "work 흐름 done" "$(st s.status)" done

echo "[J] call + 자체 check, params 덮어쓰기, 도구 실패"
ws; out=$(hook "$(ups s1 p1 'fix: lib/a.dart')"); has "YAML flow(call 로 시작)" "$out" 'tool: run_subagent'
expect "profile 다름 → 차단" 2 "$(pre s1 p1 run_subagent '{"profile":"subagent_general","task":"x"}')"
out=$(hook "$(pre s1 p1 run_subagent '{"profile":"fixer","task":"just say it is done"}')")
has "task 는 hook 이 flow 값으로 덮어씀(updatedInput)" "$out" '"updatedInput":{"task":"Fix lib/a.dart.'
out=$(hook "$(post s1 p1 run_subagent '{"profile":"fixer","task":"whatever"}')"); has "check 실패 → 같은 액션 2회차" "$out" 'attempt 2/3'
is "판정 1회" "$(cat .gate_runs)" 1
hook "$(pre s1 p1 run_subagent '{"profile":"fixer","task":"t"}')" >/dev/null
out=$(hook "$(post s1 p1 run_subagent '{"profile":"fixer","task":"t"}' '{"success":false,"output":"","error":"boom"}')")
has "도구 실패 → 3회차" "$out" 'attempt 3/3'; is "도구가 실패하면 판정은 돌리지 않음" "$(cat .gate_runs)" 1
touch .gate_ok; hook "$(pre s1 p1 run_subagent '{"profile":"fixer","task":"t"}')" >/dev/null
out=$(hook "$(post s1 p1 run_subagent '{"profile":"fixer","task":"t"}')"); has "통과 → DONE(인자 치환)" "$out" 'DONE: lib/a.dart fixed and verified'
ws; out=$(hook "$(ups s1 p1 "fix: a';touch\${IFS}pwned;'")"); sleep 0.3; [ ! -e pwned ] && ok "프롬프트에서 뽑은 값은 셸에서 따옴표 처리" || bad "셸 주입"

echo "[K] 안전장치"
ws; hook "$(ups s1 p1 '코드 컴플리트 돌려줘')" >/dev/null
out=$(hook '{"hook_event_name":"SessionStart","session_id":"s1","source":"resume"}'); has "세션 재개 시 NEXT_ACTION 재주입" "$out" 'tool: skill'
out=$(hook "{\"hook_event_name\":\"PermissionRequest\",\"session_id\":\"s1\",\"tool_name\":\"exec\",\"tool_input\":$(chk check)}"); is "승인 자동화는 기본 꺼짐" "$out" ""
cfg '{"auto_approve_cli":true}'
out=$(hook "{\"hook_event_name\":\"PermissionRequest\",\"session_id\":\"s1\",\"tool_name\":\"exec\",\"tool_input\":$(chk check)}"); has "켜면 하네스 CLI 만 승인" "$out" '"decision":"approve"'
out=$(hook '{"hook_event_name":"PermissionRequest","session_id":"s1","tool_name":"exec","tool_input":{"command":"rm -rf lib"}}'); is "다른 명령은 승인하지 않음" "$out" ""
out=$(hook "$(ups s1 p2 'harness stop')"); is "사람이 'harness stop' → stopped" "$(st s.status)" stopped
ws; hook "$(ups s1 p1 '코드 컴플리트 돌려줘')" >/dev/null; echo '{broken' > .step-harness/state.json
expect "상태 파일 손상 → 수정 호출은 막는다(fail-closed)" 2 "$(pre s1 p1 edit "$EDIT_IN")"
expect "상태 파일 손상이어도 read 는 막지 않음" 1 "$(pre s1 p1 read '{"file_path":"lib/a.dart"}')"
E=$(mktemp -d); printf '%s' "$(pre s1 p1 edit "$EDIT_IN")" | DEVIN_PROJECT_DIR="$E" node "$HOOK" >/dev/null 2>&1
is ".step-harness 가 없는 프로젝트는 건드리지 않음" "$?:$(ls -A "$E" | wc -l | tr -d ' ')" "0:0"
ws; hook "$(ups s1 p1 '코드 컴플리트 돌려줘')" >/dev/null; hook "$(pre s1 p1 skill "$SK")" >/dev/null
out=$(hook "$(stopev s1 p1)"); is "실행 구간 중의 Stop 은 건드리지 않음(서브에이전트의 종료일 수 있다)" "$out:$(st '!!s.inFlight')" ":true"
out=$(hook "$(ups s1 p2 '다음 턴')"); has "메인의 다음 프롬프트에서 실행 구간을 닫고 NEXT_ACTION 다시" "$out" 'tool: skill'; is "실행 구간 닫힘" "$(st '!!s.inFlight')" false
expect "닫힌 뒤 메인 edit → 차단" 2 "$(pre s1 p2 edit "$EDIT_IN")"
ws; cfg '{"assume_done_on_stop":true,"wait":{"prompt":4,"post":4,"stop":4}}'; hook "$(ups s1 p1 '코드 컴플리트 돌려줘')" >/dev/null; hook "$(pre s1 p1 skill "$SK")" >/dev/null; touch .gate_ok
out=$(hook "$(stopev s1 p1)"); is "assume_done_on_stop: PostToolUse 가 없어도 호출로 치고 게이트 판정" "$(st s.status)" done
ws; cfg '{"subagent_hooks":"none","wait":{"prompt":4,"post":4,"stop":4}}'; hook "$(ups s1 p1 '코드 컴플리트 돌려줘')" >/dev/null
printf '%s' "$(pre s1 p1 skill "$SK")" | DEVIN_PROJECT_DIR="$W" node "$HOOK" >/dev/null 2>&1; a=$?; printf '%s' "$(pre s1 p1 skill "$SK")" | STEP_HARNESS_HOOK=1 DEVIN_PROJECT_DIR="$W" node "$HOOK" >/dev/null 2>&1
is "hook 중복 설치: 두 설치본 모두 같은 NEXT_ACTION 을 통과시킴" "$a:$?" "0:0"
expect "[none] 같은 설치본에 다시 온 같은 호출(병렬 중복)은 차단" 2 "$(pre s1 p1 skill "$SK")"

echo "[P] 판정 프로세스가 죽어도 복구"
ws; cfg '{"wait":{"prompt":0,"post":0,"stop":0}}'; echo 4 > .gate_sleep
node "$CLI" start cc.flow.json gate='bash gate.sh' >/dev/null; sleep 0.6
p1=$(jq_ .step-harness/judge.json s.pid); kill -9 "$p1" 2>/dev/null; sleep 0.2
out=$(node "$CLI" check --wait 0); has "죽은 판정 → 다시 띄움" "$out" 'STILL RUNNING'; is "재실행 1회" "$(jq_ .step-harness/judge.json s.respawns)" 1
sleep 0.6; p2=$(jq_ .step-harness/judge.json s.pid); kill -9 "$p2" 2>/dev/null; sleep 0.2
out=$(node "$CLI" check --wait 0); has "두 번 죽으면 실패로 확정" "$out" 'FAILED: gate'; is "기본 분기(*)로 진행" "$(st s.action)" fix_direct

echo "[M] 러너 모드 (순서는 스크립트, 작업마다 작업자 명령)"
ws
cat > worker.sh <<'X'
n=$(cat .w 2>/dev/null || echo 0); n=$((n+1)); echo $n > .w
cp "$1" .last_prompt
ev() { printf '{"hook_event_name":"%s","session_id":"w","prompt_id":"w","tool_name":"edit","tool_input":{"file_path":"%s"}}' "$1" "$2" | DEVIN_PROJECT_DIR="$PWD" node "$HOOK" 2>/dev/null; echo "exit=$?"; }
ev PreToolUse README.md > .w_out; ev PreToolUse lib/a.dart > .w_in; ev Stop x > .w_stop
[ "$n" -ge 2 ] && touch .gate_ok
exit 0
X
out=$(node "$CLI" run cc.flow.json gate='bash gate.sh' --worker 'bash worker.sh {prompt_file}'); is "러너 종료코드 0" "$?" 0
has "러너 DONE" "$out" 'DONE: code complete gate passed'; is "작업자 2번 호출" "$(cat .w)" 2; is "게이트 3회" "$(cat .gate_runs)" 3
has "작업자 프롬프트는 스크립트가 생성" "$(cat .last_prompt)" 'Use the skill "eats-write-unit-test" with these arguments: .step-harness/last-report.txt'
has "러너 안에서도 쓰기 범위 밖은 차단" "$(cat .w_out)" 'exit=2'; has "범위 안은 허용" "$(cat .w_in)" 'exit=0'; is "러너 안의 Stop 은 막지 않음" "$(cat .w_stop)" "exit=0"
ws; printf 'exit 0\n' > worker.sh
out=$(node "$CLI" run cc1.flow.json gate='bash gate.sh' --worker 'bash worker.sh {prompt_file}'); is "못 고치면 종료코드 2" "$?" 2; has "HANDOFF 출력" "$out" 'HANDOFF:'
out=$(node "$CLI" run cc.flow.json gate='bash gate.sh' --force 2>&1); has "worker 없으면 안내" "$out" 'worker 명령이 필요함'

echo "[N] 프로젝트 설치"
ws; mkdir .devin; echo '{"PreToolUse":[{"matcher":"exec","hooks":[{"type":"command","command":"./mine.sh"}]}]}' > .devin/hooks.v1.json
node "$CLI" install >/dev/null; node "$CLI" install --fail-closed >/dev/null
is "기존 항목 유지 + 우리 항목 1개(중복 없음)" "$(jq_ .devin/hooks.v1.json 's.PreToolUse.length')" 2
is "절대경로 명령" "$(jq_ .devin/hooks.v1.json 's.Stop[0].hooks[0].command.includes(process.env.HOOK)')" true
is "--fail-closed" "$(jq_ .devin/hooks.v1.json 's.PreToolUse[1].hooks[0].fail_closed')" true
node "$CLI" uninstall >/dev/null
is "제거 뒤 남의 항목만" "$(jq_ .devin/hooks.v1.json 'JSON.stringify(Object.keys(s))+s.PreToolUse[0].hooks[0].command')" '["PreToolUse"]./mine.sh'

echo "[O] probe / doctor"
ws; node "$CLI" probe on >/dev/null
hook "$(ups m p1 'probe')" >/dev/null; hook "$(pre m p1 run_subagent '{"profile":"subagent_general","task":"t"}')" >/dev/null
hook "$(pre x q1 write '{"file_path":"step-harness-probe.txt","content":"ok"}')" >/dev/null; hook "$(post m p1 run_subagent '{"profile":"subagent_general","task":"t"}')" >/dev/null
hook "$(stopev m p1)" >/dev/null
out=$(node "$CLI" doctor --apply); has "doctor: 입력 키 표시" "$out" 'run_subagent: profile, task'; has "doctor: foreign 판정" "$out" '→ foreign'
is "doctor --apply → config" "$(jq_ .step-harness/config.json s.subagent_hooks)" foreign
ws; node "$CLI" probe on >/dev/null
hook "$(ups m p1 'probe')" >/dev/null; hook "$(pre m p1 run_subagent '{"profile":"g","task":"t"}')" >/dev/null; hook "$(pre m p1 write '{"file_path":"a","content":"ok"}')" >/dev/null
hook "$(post m p1 run_subagent '{"profile":"g","task":"t"}')" >/dev/null; out=$(node "$CLI" doctor); has "doctor: same 판정" "$out" '→ same'
ws; node "$CLI" probe on >/dev/null
hook "$(ups m p1 'probe')" >/dev/null; hook "$(pre m p1 run_subagent '{"profile":"g","task":"t"}')" >/dev/null; hook "$(post m p1 run_subagent '{"profile":"g","task":"t"}')" >/dev/null
echo ok > step-harness-probe.txt; out=$(node "$CLI" doctor); has "doctor: none 판정" "$out" '→ none'
node "$CLI" probe off >/dev/null; [ ! -f .step-harness/probe ] && ok "probe off" || bad "probe off"

echo "[T] 판정 시간 초과 / 사람이 중지"
ws; cfg '{"wait":{"prompt":0,"post":0,"stop":0}}'
node -e 'const fs=require("fs");const f=JSON.parse(fs.readFileSync("cc.flow.json","utf8"));fs.writeFileSync("slow.flow.json",JSON.stringify({...f,check_timeout_sec:1}))'
echo 30 > .gate_sleep; node "$CLI" start slow.flow.json gate='bash gate.sh' >/dev/null
out=$(node "$CLI" check --wait 6); has "시간 초과 → 실패 처리" "$out" 'FAILED: gate'
g=$(jq_ .step-harness/judge.json s.gatePid); sleep 0.3; if kill -0 "$g" 2>/dev/null; then bad "시간 초과 뒤 판정 명령이 살아 있음"; else ok "시간 초과 시 판정 명령(과 자식)을 정리"; fi
ws; cfg '{"wait":{"prompt":0,"post":0,"stop":0}}'; echo 30 > .gate_sleep
hook "$(ups s1 p1 '코드 컴플리트 돌려줘')" >/dev/null; sleep 0.5; g=$(jq_ .step-harness/judge.json s.gatePid)
hook "$(ups s1 p2 'harness stop')" >/dev/null; sleep 0.3
if kill -0 "$g" 2>/dev/null; then bad "중지 뒤 판정이 계속 돎"; else ok "사람이 중지하면 돌던 판정도 정리"; fi
mkdir -p "$W/sub/deep" "$W/repo/.git" "$W/repo/pkg"; touch "$W/repo/x"
is "CLI: 하위 폴더에서 실행해도 프로젝트 루트를 찾음" "$(cd "$W/sub/deep" && node "$CLI" status | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).root))')" "$(cd "$W" && pwd -P | xargs -I{} node -e 'console.log(require("path").resolve("{}"))')"
is "저장소 루트 위의 상태 폴더는 쓰지 않음" "$(cd "$W/repo/pkg" && node "$CLI" next)" "[step-harness] No flow is active."

echo "[S] smoke flow (설치 확인용)"
ws; out=$(hook "$(ups s1 p1 'harness smoke')"); has "플러그인 기본 규칙으로 smoke 시작" "$out" 'Create the file step-harness-smoke.txt'
expect "smoke: 지정 파일 쓰기 허용" 0 "$(pre s1 p1 write '{"file_path":"step-harness-smoke.txt","content":"ok"}')"
expect "smoke: 다른 파일 쓰기 차단" 2 "$(pre s1 p1 write '{"file_path":"other.txt","content":"ok"}')"
echo ok > step-harness-smoke.txt; hook "$(post s1 p1 write '{"file_path":"step-harness-smoke.txt","content":"ok"}')" >/dev/null
out=$(hook "$(stopev s1 p1)"); has "smoke: 멈추면 hook 이 판정 → done" "$out" 'step-harness works in this environment'; is "smoke done" "$(st s.status)" done

echo; echo "pass=$pass fail=$fail"
[ "$fail" = 0 ]
