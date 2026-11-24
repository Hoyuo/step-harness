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

echo "[X] 프로그램 모드 (Code Mode: 모델이 프로그램을 내고 하네스가 검증·실행)"
if node - "$HERE" <<'N'
const P = require(process.argv[2] + '/scripts/program.cjs'); const assert = require('assert');
const reg = { gates: { cc: 'x' }, skills: { s1: '' }, agents: { fixer: '' }, writable: ['lib/**', 'test/**'], worker: 'w' };
const ok = (c) => assert.deepStrictEqual(P.compile(c, reg).errors, [], c);
const no = (c, frag) => { const e = P.compile(c, reg).errors.join('\n'); assert(e.includes(frag), `${c}\n→ ${e || '(accepted)'}\n  want: ${frag}`); };
ok('async (h) => { const r = await h.check("cc"); if (r.pass) return h.done("ok"); return h.handoff(`failed ${r.report}`); }');
ok('(async (h: H) => { for (const i of h.retries(2)) { const r = await h.check("cc"); if (r?.pass) break; await h.agent("fixer", "fix", { scope: ["lib/**"] }); } return h.done(); });');
no('async (h) => { while (true) {} }', '(use for (const i of h.retries(N)))');
no('async (h) => { let r = 1; return h.done(); }', '(use const)');
no('async (h) => { const r = await h.check("cc"); }', 'every path must end');
no('async (h) => { const r = await h.check("nope"); return h.done(); }', 'unknown gate "nope"');
no('async (h) => { await h.skill("s1", "a", { scope: ["**"] }); return h.done(); }', 'not in the writable list');
no('async (h) => { await h.skill("s1", "a", { scope: ["src/**"] }); return h.done(); }', 'not in the writable list');
no('async (h) => { await h.skill("s1", "a", { scope: [".step-harness/x"] }); return h.done(); }', 'harness files');
no('async (h) => { await h.skill("s1", "a"); return h.done(); }', '{ scope:');
no('async (h) => { await h.skill("zz", "a", { scope: ["lib/**"] }); return h.done(); }', 'unknown skill "zz"');
no('async (h) => { require("fs"); return h.done(); }', '"require" is not allowed');
no('async (h) => { const r = await h.check("cc"); return h.done(r.constructor); }', 'property "constructor"');
no('async (h) => { h.done(); }', 'must be used as "return h.done');
no('async (h) => { await h.exec("rm -rf /"); return h.done(); }', 'h.exec does not exist');
no('async (h) => { for (const i of h.retries(99)) { await h.check("cc"); } return h.done(); }', 'N must be an integer literal 1..10');
no('async (h) => { return h.done(); await h.check("cc"); }', 'unreachable');
no('async (h) => { break; }', 'outside a loop');
no('async (h) => { const x = foo; await h.check("cc"); return h.done(); }', '"foo" is not defined');
no('async (h) => { return h.done(); }', 'never calls');
// 실행: 분기·반복·템플릿
const c = P.compile('async (h) => { for (const i of h.retries(3)) { const r = await h.check("cc"); if (r.pass) return h.done(`ok after ${i}`); if (r.route === "a") await h.skill("s1", r.report, { scope: ["lib/**"] }); else await h.agent("fixer", `fix ${r.report}`, { scope: ["test/**"] }); } return h.handoff("gave up"); }', reg);
let n = 0; const calls = [];
const host = { maxSteps: 40, check: () => (++n === 3 ? { pass: true } : { pass: false, route: n === 1 ? 'a' : 'b', report: `r${n}` }),
  skill: (x, a, s) => (calls.push(`skill ${a} ${s}`), { ok: true }), agent: (x, t, s) => (calls.push(`agent ${t} ${s}`), { ok: true }) };
assert.deepStrictEqual(P.run(c.ast, host).message, 'ok after 3');
assert.deepStrictEqual(calls, ['skill r1 lib/**', 'agent fix r2 test/**']);
assert.strictEqual(P.run(c.ast, { ...host, check: () => ({ pass: false, route: 'a', report: 'r' }) }).status, 'handoff');
assert.throws(() => P.run(c.ast, { ...host, maxSteps: 2, check: () => ({ pass: false, route: 'a' }) }), /step budget/);
// 쓰기 범위 (writable 목록이 없을 때): 이름으로 시작해야 하고, 숨김 경로·자리표시는 안 된다
const free = { gates: { cc: 'x', nocmd: { about: 'x' } }, worker: 'w' };
const sc = (g) => P.compile(`async (h) => { await h.agent("a", "t", { scope: [${JSON.stringify(g)}] }); return h.done(); }`, free).errors.join('\n');
for (const g of ['src/**', 'README.md', './lib/a/*.dart', 'docs/']) assert.strictEqual(sc(g), '', g);
for (const [g, frag] of [['**', 'too broad'], ['*/**', 'too broad'], ['?*/**', 'too broad'], ['**/*.ts', 'too broad'], ['.devin/**', 'hidden paths'], ['.git/hooks/*', 'hidden paths'],
  ['./.github/workflows/x.yml', 'hidden paths'], ['<dir>/**', 'placeholder'], ['/etc/passwd', 'only relative'], ['a/../../b', 'only relative'], ['x/.step-harness/y', 'harness files'], ['', 'empty']]) {
  assert(sc(g).includes(frag), `${g} → ${sc(g) || '(accepted)'}`);
}
const noF = (c2, frag) => { const e = P.compile(c2, free).errors.join('\n'); assert(e.includes(frag), `${c2}\n→ ${e || '(accepted)'}\n  want: ${frag}`); };
noF('async (h) => { await h.check("nocmd"); return h.done(); }', 'has no command');
noF('async (h) => { for (const h of h.retries(2)) { await h.check("cc"); } return h.done(); }', 'cannot redeclare h');
noF('async (h) => { const r = await h.check("cc"); for (const r of h.retries(2)) { await h.check("cc"); } return h.done(); }', '"r" is already defined');
// 반복: 겹친 횟수의 곱 상한(정적) + 연산 횟수 상한(동적)
const nest = (d) => { let b = 'await h.check("cc");'; for (let i = 0; i < d; i++) b = `for (const i${i} of h.retries(10)) { ${b} }`; return `async (h) => { ${b} return h.done(); }`; };
assert.deepStrictEqual(P.compile(nest(3), free).errors, []);
noF(nest(4), 'multiply to more than 1000');
assert.throws(() => P.run(P.compile(nest(3), free).ast, { maxSteps: 1e9, maxOps: 200, check: () => ({ pass: false }) }), /operation budget/);
// 흔한 실수에는 대안을 알려준다 (Opus 가 한두 번 안에 고쳐 내도록)
for (const [body, frag] of [['const x = r ? 1 : 2;', 'no ternary'], ['if (r.exit == 0) {}', 'use ==='], ['const s = "a" + "b";', 'template literal'], ['if (i < 3) {}', 'only === and !=='],
  ['const { pass } = await h.check("cc");', 'destructuring is not supported'], ['for (let i = 0; i < 3; i++) {}', 'the only loop is'], ['for (const k in r) {}', 'the only loop is'],
  ['const f = () => 1;', '"function" is not allowed'], ['const f = (x) => x;', '"function" is not allowed'], ['r.list.map(x => x);', '"function" is not allowed'], ['try { } catch (e) { }', '"try" is not allowed']]) {
  noF(`async (h) => { ${body} return h.done(); }`, frag);
}
// 입력 정리: 코드 울타리 · 빈 입력 · 길이 · 깊은 중첩 (예외로 죽지 않고 거부 사유로 돌아온다)
assert.deepStrictEqual(P.compile('```ts\nasync (h) => { await h.check("cc"); return h.done(); }\n```\n', free).errors, []);
assert(P.compile('', free).errors[0].includes('empty'));
assert(P.compile('async (h) => { await h.check("cc"); return h.done("' + 'x'.repeat(21000) + '"); }', free).errors[0].includes('too long'));
assert(P.compile('async (h) => { const x = ' + '('.repeat(9000) + '1' + ')'.repeat(9000) + '; return h.done(); }', free).errors[0].includes('nested too deeply'));
assert.deepStrictEqual(P.compile('async (h) => { await h.check("cc"); return h.done(`${"}"} ok`); }', free).errors, []);
// 같은 키를 두 번 쓰면 검증기와 실행기가 서로 다른 값을 보게 된다 → 문법 단계에서 거부
noF('async (h) => { await h.agent("a", "t", { scope: ["src/**"], scope: ["**"] }); return h.done(); }', 'duplicate key "scope"');
noF('async (h) => { await h.agent("a", "t", { scope: ["src/**"], "scope": [".git/**"] }); return h.done(); }', 'duplicate key "scope"');
no('async (h) => { await h.skill("s1", "a", { scope: ["lib/**"], scope: ["src/**"] }); return h.done(); }', 'duplicate key "scope"');
// 타입 표기는 받고 무시한다
for (const head of ['async (h: Harness<X>): Promise<void> =>', 'async (h): Promise<never> =>', '(async (h: H) =>']) {
  assert.deepStrictEqual(P.compile(`${head} { const r: Verdict = await h.check("cc"); const o: { pass: boolean } = r; if (o.pass) return h.done(); return h.handoff(); }${head.startsWith('(') ? ')' : ''}`, free).errors, [], head);
}
// 프롬프트에 넣는 예시는 그 등록부에서 그대로 검증을 통과해야 한다 (쓰기 범위가 정해져 있을 때)
assert.deepStrictEqual(P.compile(P.example(reg, ['cc']), reg).errors, []);
assert.deepStrictEqual(P.compile(P.example({ gates: { cc: 'x' }, worker: null }, []), { gates: { cc: 'x' }, worker: null }).errors, []);
assert(P.declaration(reg, ['cc']).includes('accepted only if "cc" passes'));
N
then ok "파서·검증기·인터프리터 (거부 규칙 포함)"; else bad "파서·검증기·인터프리터"; fi
if node - "$HERE" <<'N'
const L = require(process.argv[2] + '/scripts/lib.cjs'); const assert = require('assert');
const C = L.HARNESS_CLI, root = process.cwd();
const t = (cmd, sub) => assert.strictEqual(L.harnessCmd(root, cmd), sub, JSON.stringify(cmd));
t(`node "${C}" check`, 'check'); t(`node "${C}" check --wait 50`, 'check'); t(`node '${C}' search`, 'search'); t(`node "${C}" search 'unit test'`, 'search'); t(`node "${C}" search unit`, 'search');
t(`node "${C}" execute <<'EOF'\nasync (h) => {}\nEOF`, 'execute'); t(`node "${C}" execute <<'EOF'\nx\nEOF\n`, 'execute'); t(`node "${C}" execute 'async (h) => {\n}'`, 'execute');
// 셸에서는 줄바꿈 뒤가 별개의 명령이다 → 낱말 사이의 줄바꿈은 받지 않는다. heredoc 은 따옴표 친 종료어 하나로 끝나야 한다
for (const bad of [`node "${C}" search\nmake`, `node "${C}"\ncheck`, `node "${C}" check\n--wait 5`, `node "${C}" check --wait\n5`, `node "${C}" execute\n'make'`, `node "${C}" execute\n<<'EOF'\nx\nEOF`,
  `node\n"${C}" check`, `node "${C}" search; make`, `node "${C}" search $(make)`, `node "${C}" search \`make\``, `node "${C}" execute <<EOF\nx\nEOF`, `node "${C}" execute <<-'EOF'\nx\nEOF`,
  `node "${C}" execute <<'EOF'\nx\nEOF\nmake`, `node "${C}" execute <<'EOF' | sh\nx\nEOF`, `node "${C}" execute <<'EOF'\nx\nEOF\ny\nEOF`, `node "/tmp/other/harness.cjs" check`,
  `node "${C}" check && make`, `node "${C}" reset`, `node "${C}" _exec a:1`,
  `node "${C}" execute <<'EOF'\nx\nEOF `, `node "${C}" execute <<'EOF'\nx\nEOF\t`, `\r node "${C}" check`, `\u00a0node "${C}" check`, `node "${C}" check\f`]) t(bad, null);
t(`\n  node "${C}" check\n\n`, 'check');
// 상대 경로는 받지 않는다 (hook 은 프로젝트 루트 기준, 셸은 그때의 작업 폴더 기준으로 푼다 → 다른 파일이 실행될 수 있다)
assert.strictEqual(L.harnessCmd(L.PLUGIN_DIR, 'node scripts/harness.cjs check'), null);
assert.strictEqual(L.harnessCmd(L.PLUGIN_DIR, 'node ./scripts/harness.cjs check'), null);
assert.strictEqual(L.harnessCmd(L.PLUGIN_DIR, `node "${C}" check`), 'check');
for (const [name, yes] of [['mcp__step-harness__execute', true], ['mcp__step_harness__check', true], ['mcp__plugin_step-harness_step-harness__search', true],
  ['mcp__step-harness-evil__execute', false], ['mcp__other__execute', false], ['mcp__step-harness__reset', false]]) assert.strictEqual(L.isHarnessMcp(name), yes, name);
N
then ok "허용 명령 형태 (줄바꿈·heredoc 으로 명령 끼워넣기 거부)"; else bad "허용 명령 형태"; fi
if node - "$HERE" <<'N'
const L = require(process.argv[2] + '/scripts/lib.cjs'), F = require(process.argv[2] + '/scripts/flow.cjs');
const assert = require('assert'), cp = require('child_process'), fs = require('fs'), os = require('os'), path = require('path');
// 프롬프트에서 뽑은 값이 판정 명령에 들어갈 때: flow 작성자가 따옴표 안에 두었든 밖에 두었든 한 개의 글자 그대로의 인자가 된다
const d = fs.mkdtempSync(path.join(os.tmpdir(), 'shq-'));
const f = { flow: 't', args: ['target', 'gate'], start: 'g', actions: { g: { on: { pass: 'done' },
  check: `{gate} '{target}' && {gate} "{target}" && {gate} "pre {target} post" && {gate} {target} && {gate} 'a {target}'` } } };
for (const val of ['a; touch PWNED', '$(touch PWNED)', '`touch PWNED`', "it's; touch PWNED", '"; touch PWNED; "', "'; touch PWNED; '", 'a\nb']) {
  const cmd = F.compile(f, { target: val, gate: 'printf [%s]\\\\n' }, new Set(['target'])).actions.g.check;
  const r = cp.spawnSync('bash', ['-c', cmd], { cwd: d, encoding: 'utf8' });
  assert.strictEqual(r.status, 0, `${val}: ${r.stderr}`);
  assert.strictEqual(r.stdout, `[${val}]\n[${val}]\n[pre ${val} post]\n[${val}]\n[a ${val}]\n`, val);
  assert.deepStrictEqual(fs.readdirSync(d).filter((x) => x.includes('PWNED')), [], `명령이 실행됨: ${val}`);
}
// 대소문자를 구분하지 않는 파일 시스템(macOS 기본): 대문자로 쓴 경로도 같은 파일이다 → 보호·범위 검사가 실제 파일 기준으로 동작해야 한다
fs.mkdirSync(path.join(d, '.step-harness')); fs.mkdirSync(path.join(d, 'lib'));
fs.writeFileSync(path.join(d, '.step-harness', 'state.json'), '{}');
if (fs.existsSync(path.join(d, '.STEP-HARNESS', 'state.json'))) {
  assert.strictEqual(L.touchesHarness(d, 'edit', { file_path: '.STEP-HARNESS/state.json' }, false), true);
  assert.strictEqual(L.touchesHarness(d, 'write', { file_path: path.join(d, '.Step-Harness', 'new.json') }, false), true);
  assert.strictEqual(L.inScope(d, ['lib/**'], 'LIB/a.dart'), true);
}
assert.strictEqual(L.touchesHarness(d, 'exec', { command: 'echo x > .STEP-HARNESS/state.json' }, false), true);
assert.strictEqual(L.touchesHarness(d, 'exec', { command: 'cat .STEP-HARNESS/state.json' }, false), false);   // 읽기 전용 명령은 허용
assert.strictEqual(L.touchesHarness(d, 'edit', { file_path: 'lib/a.dart' }, false), false);
assert.strictEqual(L.inScope(d, ['lib/**'], '.step-harness/state.json'), false);
// 환경변수 표식으로 프로세스 찾기 (Linux 의 /proc 형식. 가짜 폴더로 확인)
const J = require(process.argv[2] + '/scripts/judge.cjs');
const proc = fs.mkdtempSync(path.join(os.tmpdir(), 'proc-'));
for (const [pid, env] of [['101', 'A=1\0STEP_HARNESS_WORKER=r1:5\0B=2\0'], ['102', 'STEP_HARNESS_WORKER=r1:55\0'], ['103', 'X=STEP_HARNESS_WORKER=r1:5\0'], ['self', 'STEP_HARNESS_WORKER=r1:5\0']]) {
  fs.mkdirSync(path.join(proc, pid)); fs.writeFileSync(path.join(proc, pid, 'environ'), env);
}
fs.mkdirSync(path.join(proc, '104'));   // environ 을 읽을 수 없는 프로세스
assert.deepStrictEqual(J.markedPids('STEP_HARNESS_WORKER=r1:5', proc), [101]);
assert.deepStrictEqual(J.markedPids('STEP_HARNESS_WORKER=r1:5', path.join(proc, 'none')), []);
// 믿는 값(router.json 에 적힌 것)은 그대로 들어간다
assert.strictEqual(F.compile(f, { target: 'x', gate: 'bash gate.sh' }, new Set()).actions.g.check.startsWith("bash gate.sh 'x'"), true);
// exec_allow 는 명령의 처음부터 맞아야 한다
const a = { exec_allow: ['flutter test', '^dart format'] };
const allowed = (c) => !L.scopeViolation(d, a, 'exec', { command: c });
for (const c of ['flutter test', 'flutter test --coverage', 'dart format lib', '  flutter test  ']) assert.strictEqual(allowed(c), true, c);
for (const c of ['rm -rf lib #flutter test', 'echo flutter test', 'flutter test; rm -rf lib', 'flutter test > x', 'flutter test $(id)', 'flutter test\nrm -rf lib', 'X=1 flutter test']) assert.strictEqual(allowed(c), false, c);
// 락: 죽은 프로세스의 락은 넘겨받고, 끝나면 지운다. 빼앗긴(내 것이 아닌) 락은 지우지 않는다
const lock = path.join(d, '.step-harness', 'lock');
fs.writeFileSync(lock, '999999999');
const t0 = Date.now(); let ran = false;
L.withLock(d, () => { ran = true; assert(fs.readFileSync(lock, 'utf8').startsWith(process.pid + ':')); });
assert(ran && Date.now() - t0 < 1500 && !fs.existsSync(lock));
L.withLock(d, () => { fs.writeFileSync(lock, 'someone-else'); });
assert.strictEqual(fs.readFileSync(lock, 'utf8'), 'someone-else');
assert.deepStrictEqual(fs.readdirSync(path.join(d, '.step-harness')).filter((x) => x.includes('.stale')), []);
N
then ok "따옴표 처리 · exec_allow · 락 (기존 flow 경로의 보강)"; else bad "따옴표 처리 · exec_allow · 락"; fi

pws() {   # 프로그램 모드 작업 폴더: 등록부 + 가짜 작업자
  ws
  cat > worker.sh <<'X'
n=$(cat .w 2>/dev/null || echo 0); n=$((n+1)); echo $n > .w
cp "$1" .last_prompt
ev() { printf '{"hook_event_name":"%s","session_id":"w","prompt_id":"w","tool_name":"edit","tool_input":{"file_path":"%s"}}' "$1" "$2" | DEVIN_PROJECT_DIR="$PWD" node "$HOOK" 2>/dev/null; echo "exit=$?"; }
ev PreToolUse README.md > .w_out; ev PreToolUse lib/a.dart > .w_in; ev Stop x > .w_stop
[ -f .w_sleep ] && sleep "$(cat .w_sleep)"
[ "$n" -ge "$(cat .w_need 2>/dev/null || echo 2)" ] && touch .gate_ok
exit 0
X
  cat > .step-harness/config.json <<'J'
{ "wait": {"prompt":4,"post":4,"stop":4}, "check_wait_sec": 20,
  "gates": { "cc": { "cmd": "bash gate.sh", "about": "code complete gate" } },
  "skills": { "eats-write-unit-test": "writes unit tests" }, "agents": { "fixer": "fixer" },
  "writable": ["lib/**", "test/**"], "worker": "bash worker.sh {prompt_file}" }
J
  node -e 'const fs=require("fs");const f=".step-harness/router.json";const r=JSON.parse(fs.readFileSync(f,"utf8"));
    r.routes.push({name:"prog",when:"^프로그램: (.+)",program:{task:"$1"}});fs.writeFileSync(f,JSON.stringify(r));'
}
PROG='async (h) => {
  for (const attempt of h.retries(3)) {
    const r = await h.check("cc");
    if (r.pass) return h.done("code complete");
    if (r.route === "unit-test") await h.skill("eats-write-unit-test", r.report, { scope: ["lib/**", "test/**"] });
    else await h.agent("fixer", `Fix ${r.report}`, { scope: ["lib/**"] });
  }
  return h.handoff("3회 시도 후에도 실패");
}'
execdoc() { node -e 'const c=process.argv[1],p=process.argv[2];console.log(JSON.stringify({command:`node "${c}" execute <<'"'"'EOF'"'"'\n${p}\nEOF`}))' "$CLI" "$1"; }

pws; out=$(node "$CLI" search); has "search: 타입 선언에 등록 이름이 리터럴로" "$out" 'check(gate: "cc"): Promise<Verdict>'
has "search: 쓰기 범위 타입" "$out" '("lib/**" | "test/**")[]'; hasnt "search: 게이트 명령은 노출 안 함" "$out" 'bash gate.sh'
out=$(node "$CLI" search unit); has "search 필터" "$out" 'eats-write-unit-test'; hasnt "search 필터 제외" "$out" 'agent fixer'

out=$(hook "$(ups s1 p1 '프로그램: 코드 컴플리트 통과시키기')"); has "라우터 → 프로그램 모드" "$out" 'TASK: 코드 컴플리트 통과시키기'
has "프롬프트 = 타입 있는 API" "$out" 'declare const h'; has "제출 형식 안내" "$out" 'execute <<'
expect "프로그램 대기 중 직접 수정 차단" 2 "$(pre s1 p1 edit "$EDIT_IN")"
expect "프로그램 대기 중 임의 명령 차단" 2 "$(pre s1 p1 exec '{"command":"bash gate.sh"}')"
expect "읽기 도구는 허용" 0 "$(pre s1 p1 read '{"file_path":"lib/a.dart"}')"
expect "search CLI 허용" 0 "$(pre s1 p1 exec "$(printf '{"command":"node \\"%s\\" search"}' "$CLI")")"
expect "execute heredoc 허용" 0 "$(pre s1 p1 exec "$(execdoc "$PROG")")"
expect "heredoc 뒤에 명령을 붙이면 차단" 2 "$(pre s1 p1 exec "$(execdoc "$PROG
EOF
touch pwned")")"
expect "MCP execute 도구 허용" 0 "$(pre s1 p1 mcp__step-harness__execute '{"code":"x"}')"
expect "다른 MCP 도구는 차단" 2 "$(pre s1 p1 mcp__other__run '{}')"
out=$(hook "$(stopev s1 p1)"); has "프로그램 없이 멈추면 차단" "$out" '"decision":"block"'

out=$(node "$CLI" execute 'async (h) => { const r = await h.check("cc"); }'); is "거부 → exit 1" "$?" 1
has "거부 사유 출력" "$out" 'every path must end'; is "거부 횟수 기록" "$(st s.rejects)" 1
out=$(node "$CLI" next); has "다음 프롬프트에 거부 사유" "$out" 'Your last program was REJECTED (1/3)'

out=$(node "$CLI" execute "$PROG"); is "execute → 완료 exit 0" "$?" 0
has "단계별 기록: 실패한 게이트" "$out" 'FAILED: check:cc (route=unit-test)'; has "단계별 기록: 스킬 작업자" "$out" 'PASSED: skill:eats-write-unit-test'
has "DONE 메시지는 프로그램이 정함" "$out" 'DONE: code complete'; is "작업자 2번" "$(cat .w)" 2; is "게이트 3번" "$(cat .gate_runs)" 3
has "작업자 프롬프트는 하네스가 생성" "$(cat .last_prompt)" 'You may only write files under: lib/**, test/**.'
has "작업자: 범위 밖 쓰기 차단" "$(cat .w_out)" 'exit=2'; has "작업자: 범위 안 허용" "$(cat .w_in)" 'exit=0'; is "작업자의 Stop 은 무시" "$(cat .w_stop)" 'exit=0'
is "상태 done" "$(st s.status)" done; is "작업자 끝나면 쓰기 범위 해제" "$(jq_ .step-harness/flow.json 'JSON.stringify(s.actions.program.write_scope)')" undefined

pws; echo 9 > .w_need; hook "$(ups s1 p1 '프로그램: 고치기')" >/dev/null
out=$(node "$CLI" execute "$PROG"); has "못 고치면 handoff" "$out" 'PAUSED'; is "handoff 사유 = 프로그램 메시지" "$(st s.handoff.reason)" '3회 시도 후에도 실패'
out=$(hook "$(ups s1 p2 'retry')"); has "retry → 새 프로그램 요청" "$out" 'PROGRAM — do not do the work yourself'; is "retry 는 재시도 횟수를 새로 센다 (기존 handoff 규칙)" "$(st s.visits.program)" 1; is "retry 후 실행 중" "$(st s.status)" running

pws; hook "$(ups s1 p1 '프로그램: 고치기')" >/dev/null
for i in 1 2 3 4; do node "$CLI" execute 'async (h) => { while (1) {} }' >/dev/null; done
is "거부가 한도를 넘으면 handoff" "$(st s.status)" handoff

pws; echo 3 > .w_sleep; hook "$(ups s1 p1 '프로그램: 느린 작업')" >/dev/null
(cd "$W" && node "$CLI" execute "$PROG" >/dev/null 2>&1 &); sleep 1
expect "실행 중 메인의 직접 수정 차단" 2 "$(pre s1 p1 edit "$EDIT_IN")"
expect "실행 중 check 허용" 0 "$(pre s1 p1 exec "$(chk check)")"
out=$(node "$CLI" execute "$PROG"); has "실행 중 두 번째 execute 거부" "$out" 'already running'
out=$(hook "$(ups s1 p2 '진행 상황?')"); is "새 턴이 와도 실행 구간 유지" "$(st 'String(!!s.inFlight)')" true
for _ in $(seq 1 30); do [ "$(st s.status)" = done ] && break; node "$CLI" check --wait 2 >/dev/null; done
is "느린 프로그램도 완료" "$(st s.status)" done

pws; node "$CLI" start cc.flow.json gate='bash gate.sh' >/dev/null
out=$(node "$CLI" execute "$PROG"); has "일반 flow 중에는 execute 거부" "$out" 'another flow is active'

pws; hook "$(ups s1 p1 '프로그램: 멈춤')" >/dev/null; echo 30 > .w_sleep
(node "$CLI" execute "$PROG" >/dev/null 2>&1 &); sleep 1.5
hook "$(ups s1 p2 'harness stop')" >/dev/null; sleep 0.5
is "사람이 멈추면 상태 stopped" "$(st s.status)" stopped
pid=$(st 's.exec&&s.exec.pid'); if [ -n "$pid" ] && [ "$pid" != "null" ] && kill -0 "$pid" 2>/dev/null; then bad "실행 프로세스 정리"; else ok "실행 프로세스 정리"; fi

pws; out=$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}' '{"jsonrpc":"2.0","method":"notifications/initialized"}' '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  "$(node -e 'console.log(JSON.stringify({jsonrpc:"2.0",id:3,method:"tools/call",params:{name:"execute",arguments:{code:process.argv[1]}}}))' "$PROG")" | DEVIN_PROJECT_DIR="$W" node "$HERE/scripts/mcp.cjs")
has "MCP initialize" "$out" '"serverInfo":{"name":"step-harness"'; has "MCP 도구 목록" "$out" '"name":"execute"'
has "MCP execute 로 실행·완료" "$out" 'DONE: code complete'

# 플러그인만 설치한 프로젝트 (.step-harness 없음): 기본 규칙 "프로그램: …" 으로 바로 시작, 게이트 없이 작업자만으로 완료
W="$(mktemp -d)"; cd "$W"; mkdir -p lib
printf 'echo hi > lib/a.txt\nexit 0\n' > w.sh
out=$(hook "$(ups s1 p1 '일반 질문')"); is "상태 폴더 없고 규칙 밖이면 관여 안 함" "$([ -d .step-harness ] && echo y || echo n)" n
out=$(hook "$(ups s1 p1 '프로그램: a.txt 만들기')"); has "상태 폴더 없이 기본 규칙으로 시작" "$out" 'TASK: a.txt 만들기'
is "기본 작업자 = devin" "$(node -e 'console.log(require(process.argv[1]).registry(process.argv[2]).worker.split(" ")[0])' "$HERE/scripts/lib.cjs" "$W")" devin
echo '{"worker":"bash w.sh {prompt_file}"}' > .step-harness/config.json
out=$(node "$CLI" execute 'async (h) => {
  const r = await h.skill("mk", "a.txt", { scope: ["lib/**"] });
  if (r.ok) return h.done("made");
  return h.handoff("no");
}'); for _ in 1 2 3 4 5 6 7 8 9 10; do out=$(node "$CLI" check --wait 2); grep -q 'DONE\|PAUSED' <<<"$out" && break; done
has "게이트 없이 작업자만으로 완료 (reports 폴더 자동 생성)" "$out" 'DONE: made'
is "작업자가 파일을 씀" "$(cat lib/a.txt)" hi
# 프로젝트 규칙과 플러그인 기본 규칙이 둘 다 맞으면 프로젝트 규칙이 이긴다
pws; out=$(hook "$(ups s1 p1 '프로그램: 우선순위')"); hasnt "프로젝트 규칙 우선 (모호 처리 안 함)" "$out" 'more than one flow'

echo "[Y] 프로그램 모드: 완료 조건 · 동시 실행 · 실행 프로세스 정리 · 범위 밖 변경 감지"
setcfg() { node -e 'const fs=require("fs");const p=".step-harness/config.json";const c=JSON.parse(fs.readFileSync(p,"utf8"));eval(process.argv[1]);fs.writeFileSync(p,JSON.stringify(c))' "$1"; }
addroute() { node -e 'const fs=require("fs");const f=".step-harness/router.json";const r=JSON.parse(fs.readFileSync(f,"utf8"));r.routes.push(JSON.parse(process.argv[1]));fs.writeFileSync(f,JSON.stringify(r))' "$1"; }
waitdone() { for _ in $(seq 1 40); do case "$(st s.status)" in done|handoff|stopped) return;; esac; node "$CLI" check --wait 2 >/dev/null; done; }
nl_cmd() { node -e 'console.log(JSON.stringify({command:`node "${process.argv[1]}" ${process.argv[2]}\n${process.argv[3]}`}))' "$CLI" "$1" "$2"; }

# 프롬프트: 예시 프로그램 · 줄바꿈으로 붙인 명령 차단 · 플러그인 접두사 MCP 이름
pws; out=$(hook "$(ups s1 p1 '프로그램: 예시 확인')")
has "프롬프트에 예시 프로그램" "$out" 'Shape (adapt it'; has "예시는 등록된 이름을 쓴다" "$out" 'await h.agent(\"fixer\"'
expect "search 뒤에 줄바꿈으로 붙인 명령 차단" 2 "$(pre s1 p1 exec "$(nl_cmd search make)")"
expect "heredoc 종료 줄 뒤에 공백이 있으면 차단 (셸은 거기서 끝내지 않는다)" 2 "$(pre s1 p1 exec "$(node -e 'console.log(JSON.stringify({command:`node "${process.argv[1]}" execute <<'"'"'EOF'"'"'\nasync (h) => {}\nEOF `}))' "$CLI")")"
expect "check 뒤에 줄바꿈으로 붙인 명령 차단" 2 "$(pre s1 p1 exec "$(nl_cmd check 'rm -rf lib')")"
out=$(hook "$(pre s1 p1 exec "$(printf '{"command":"cd . && node \\"%s\\" search"}' "$CLI")")" 2>&1); has "형태가 틀린 하네스 명령에는 무엇이 틀렸는지 안내" "$out" 'must be written exactly as shown'
expect "플러그인 접두사가 붙은 MCP 도구 이름 허용" 0 "$(pre s1 p1 mcp__plugin_step-harness_step-harness__execute '{"code":"x"}')"
expect "이름이 비슷한 다른 서버의 도구는 차단" 2 "$(pre s1 p1 mcp__step-harness-evil__execute '{"code":"x"}')"

# check 는 아직 보여주지 않은 단계만 출력한다
pws; hook "$(ups s1 p1 '프로그램: 단계 출력')" >/dev/null; out=$(node "$CLI" execute "$PROG"); has "첫 출력에는 단계가 나온다" "$out" 'PASSED: skill:eats-write-unit-test'
out=$(node "$CLI" check); hasnt "check 를 다시 불러도 지난 단계를 반복하지 않음" "$out" 'PASSED: skill'; has "결과는 다시 알려준다" "$out" 'DONE: code complete'

# 완료 조건(done_when): h.done() 은 프로그램의 주장일 뿐. 정해진 게이트를 하네스가 직접 돌려 통과해야 끝난다
LIE='async (h) => {
  await h.agent("fixer", "do it", { scope: ["lib/**"] });
  return h.done("all good, trust me");
}'
dws() { pws; addroute '{"name":"strict","when":"^완료조건: (.+)","program":{"task":"$1","done_when":["cc"]}}'; }
dws; echo 9 > .w_need; out=$(hook "$(ups s1 p1 '완료조건: 통과시키기')")
has "프롬프트에 완료 조건 표시" "$out" 'accepted only if \"cc\" passes'
out=$(node "$CLI" execute "$LIE")
has "done 선언 뒤 하네스가 게이트를 직접 실행" "$out" 'FAILED: check:cc'; hasnt "게이트가 실패하면 done 을 받아들이지 않음" "$out" 'DONE:'
has "모델에게 사유 전달" "$out" 'returned h.done(), but the required gate "cc" FAILED'
is "흐름은 계속 진행 중" "$(st s.status)" running; is "시도 횟수 +1" "$(st s.visits.program)" 2; is "게이트 1회 실행" "$(cat .gate_runs)" 1
echo 1 > .w_need; out=$(node "$CLI" execute "$LIE")
has "게이트가 통과하면 그때 완료" "$out" 'DONE: all good, trust me'; is "상태 done" "$(st s.status)" done; is "게이트 총 2회" "$(cat .gate_runs)" 2
dws; touch .gate_ok; hook "$(ups s1 p1 '완료조건: 이미 통과')" >/dev/null
out=$(node "$CLI" execute 'async (h) => { const r = await h.check("cc"); if (r.pass) return h.done("ok"); return h.handoff("no"); }')
has "프로그램이 직접 확인한 게이트는 다시 돌리지 않음" "$out" 'DONE: ok'; is "게이트 1회만" "$(cat .gate_runs)" 1
dws; echo 9 > .w_need; hook "$(ups s1 p1 '완료조건: 끝내 실패')" >/dev/null
for _ in 1 2 3; do node "$CLI" execute "$LIE" >/dev/null; done
is "완료 조건을 한도까지 못 넘기면 handoff" "$(st s.status)" handoff; has "handoff 사유에 게이트 이름" "$(st s.handoff.reason)" '게이트 "cc"'
pws; addroute '{"name":"badgate","when":"^없는게이트","program":{"task":"x","done_when":["nope"]}}'
out=$(hook "$(ups s1 p1 '없는게이트')"); has "등록되지 않은 게이트를 완료 조건으로 쓰면 시작하지 않음" "$out" 'done_when names a gate that is not registered'
[ ! -f .step-harness/state.json ] && ok "시작 실패 시 상태 없음" || bad "시작 실패인데 상태가 생김"
pws; setcfg 'c.done_when=["cc"]'; echo 9 > .w_need; out=$(node "$CLI" execute "$LIE")
hasnt "config 의 done_when 은 규칙 없이 낸 프로그램에도 적용" "$out" 'DONE:'; is "config done_when → 진행 중" "$(st s.status)" running

# 동시에 낸 두 프로그램: 하나만 시작한다 (확인과 시작이 한 락 안)
pws; echo 1 > .w_sleep
(node "$CLI" execute "$PROG" > .e1 2>&1 &); (node "$CLI" execute "$PROG" > .e2 2>&1 &); sleep 1.2
is "동시 execute: 시작은 하나" "$(grep -c '"ev":"program"' .step-harness/log.jsonl)" 1
is "동시 execute: 다른 하나는 거부" "$(cat .e1 .e2 | grep -c 'already running')" 1
waitdone; is "동시 execute 후 정상 완료" "$(st s.status)" done; is "작업자는 한 프로그램 분량만 실행" "$(cat .w)" 2

# 실행 중에 흐름이 사람에게 넘어가면(막힌 호출 반복) 실행 프로세스를 정리하고, 남은 작업자는 쓰지 못한다
wk() { printf '%s' "$2" | DEVIN_PROJECT_DIR="$W" STEP_HARNESS_WORKER="$1" node "$HOOK" >/dev/null 2>&1; echo $?; }
pws; echo 30 > .w_sleep; hook "$(ups s1 p1 '프로그램: 오래 걸림')" >/dev/null
(node "$CLI" execute "$PROG" >/dev/null 2>&1 &); sleep 1.5
key="$(st 's.run+":"+s.seq')"; pid=$(st 's.exec.pid')
is "실행 중인 작업자: 범위 안 쓰기 허용" "$(wk "$key" "$(pre w w edit "$EDIT_IN")")" 0
is "실행 중인 작업자: 범위 밖 쓰기 차단" "$(wk "$key" "$(pre w w edit "$EDIT_OUT")")" 2
for _ in 1 2 3 4 5 6; do hook "$(pre s1 p1 edit "$EDIT_IN")" >/dev/null; done
is "실행 중 막힌 호출 반복 → handoff" "$(st s.status)" handoff; sleep 0.6
if kill -0 "$pid" 2>/dev/null; then bad "handoff 되면 실행 프로세스 정리"; else ok "handoff 되면 실행 프로세스 정리"; fi
is "끝난 실행의 작업자: 쓰기 차단" "$(wk "$key" "$(pre w w edit "$EDIT_IN")")" 2
is "끝난 실행의 작업자: 셸 차단" "$(wk "$key" "$(pre w w exec '{"command":"echo x > lib/a.dart"}')")" 2
is "끝난 실행의 작업자: 읽기는 허용" "$(wk "$key" "$(pre w w read '{"file_path":"lib/a.dart"}')")" 0
is "끝난 실행의 작업자: Stop 은 흐름에 영향 없음" "$(wk "$key" "$(stopev w w)")" 0
rm -f .w_sleep; out=$(hook "$(ups s1 p2 'retry')"); has "retry → 새 프로그램 요청" "$out" 'PROGRAM — do not do the work yourself'
out=$(node "$CLI" execute "$PROG"); has "retry 후 새 프로그램은 정상 실행" "$out" 'DONE: code complete'
hook "$(ups s1 p3 'harness stop')" >/dev/null
is "흐름이 멈춘 뒤에도 그 실행의 작업자 표식이 있으면 쓰기 차단" "$(wk "$key" "$(pre w w edit "$EDIT_IN")")" 2
ws; is "실행 기록이 없는 프로젝트에서는 표식이 남아 있어도 관여하지 않음" "$(wk "dead:1" "$(pre w w edit "$EDIT_IN")")" 0

# 실행 구간은 시간으로 만료되지 않는다 (프로세스의 생사로 판단) · 실행 중 Stop · 다른 세션의 프롬프트
pws; echo 6 > .w_sleep; echo 1 > .w_need; setcfg 'c.wait.stop=1;c.wait.prompt=0'; hook "$(ups s1 p1 '프로그램: 실행 구간')" >/dev/null
node -e 'const fs=require("fs");const p=".step-harness/flow.json";const f=JSON.parse(fs.readFileSync(p,"utf8"));f.inflight_ttl_sec=0.1;fs.writeFileSync(p,JSON.stringify(f,null,2))'
(node "$CLI" execute "$PROG" >/dev/null 2>&1 &); sleep 1.3
hook "$(pre s1 p1 read '{"file_path":"lib/a.dart"}')" >/dev/null
is "실행 구간은 시간이 지나도 유지" "$(st 'String(!!s.inFlight)')" true
out=$(node "$CLI" execute "$PROG"); has "실행 구간 유지 → 두 번째 execute 거부" "$out" 'already running'
out=$(hook "$(stopev s1 p1)"); has "실행 중 멈추려 하면 붙잡는다" "$out" 'the program is still running'; is "실행 중 Stop 은 횟수로 세지 않음" "$(st 's.stopBlocks||0')" 0
out=$(hook "$(ups s2 p9 '어떻게 됐어?')"); has "다른 세션의 프롬프트에도 진행 상황 주입" "$out" 'The program is running'
is "그 세션이 메인이 됨" "$(st s.mainSession)" s2; is "턴 기록 갱신" "$(st s.lastPromptId)" p9; is "실행 구간은 그대로" "$(st 'String(!!s.inFlight)')" true
out=$(hook '{"hook_event_name":"SessionStart","session_id":"s2","source":"resume"}'); has "세션 재개 시에도 진행 상황 주입" "$out" 'The program is running'
waitdone; is "끝까지 실행" "$(st s.status)" done

# 범위 밖 변경 감지: 작업자가 hook 을 거치지 않고(셸 명령) 범위 밖 파일을 바꾸면 실행 뒤 git 비교로 잡아 사람에게 넘긴다
gws() {
  pws; printf '.w*\n.gate*\n.last_prompt\n' > .gitignore
  cat > gw.sh <<'X'
[ -f .w_shell_out ] && echo hacked >> README.md
echo fixed >> lib/keep.txt
exit 0
X
  setcfg 'c.worker="bash gw.sh {prompt_file}"'
  echo base > README.md; echo x > lib/keep.txt
  git init -q . && git -c user.email=t@t -c user.name=t add -A >/dev/null 2>&1 && git -c user.email=t@t -c user.name=t commit -qm init >/dev/null 2>&1
  echo mine > notes.txt   # 실행 전부터 있던 사용자의 미커밋 파일
}
GPROG='async (h) => {
  const r = await h.agent("fixer", "fix", { scope: ["lib/**"] });
  if (r.ok) return h.done("fixed");
  return h.handoff("worker failed");
}'
gws; touch .w_shell_out; out=$(node "$CLI" execute "$GPROG")
is "범위 밖 변경 → handoff" "$(st s.status)" handoff; has "사유에 바뀐 파일" "$(st s.handoff.reason)" 'README.md'
hasnt "실행 전부터 있던 변경은 문제 삼지 않음" "$(st s.handoff.reason)" 'notes.txt'; hasnt "범위 안 변경은 문제 삼지 않음" "$(st s.handoff.reason)" 'keep.txt'
has "작업자 리포트에 목록" "$(cat .step-harness/reports/worker-1.txt)" 'files changed outside the scope'; has "단계 기록" "$out" 'FAILED: agent:fixer (route=out-of-scope)'
gws; out=$(node "$CLI" execute "$GPROG"); has "범위 안에서만 바꾸면 완료 (하네스 자신의 파일은 검사 대상 아님)" "$out" 'DONE: fixed'
gws; touch .w_shell_out; setcfg 'c.scope_check=false'; out=$(node "$CLI" execute "$GPROG"); has "scope_check=false 면 검사하지 않음" "$out" 'DONE: fixed'
# git status 에 보이지 않는 곳(.git 안의 hook)에 심은 파일도 잡는다
gws; printf 'mkdir -p .git/hooks; printf "#!/bin/sh\\ntouch PWNED\\n" > .git/hooks/pre-commit; echo fixed >> lib/keep.txt\n' > gw.sh; node "$CLI" execute "$GPROG" >/dev/null; waitdone
is "작업자가 .git/hooks 에 파일을 심으면 handoff" "$(st s.status)" handoff; has "사유에 hook 경로" "$(st s.handoff.reason)" '.git/hooks/pre-commit'
# 실행 전부터 고쳐져 있던 범위 밖 파일을, 크기와 수정 시각을 그대로 둔 채 내용만 바꿔도 잡는다 (ctime 은 되돌릴 수 없다)
gws; printf 'cp -p notes.txt .w_keep; printf "evil\\n" > notes.txt; touch -r .w_keep notes.txt; echo fixed >> lib/keep.txt\n' > gw.sh; node "$CLI" execute "$GPROG" >/dev/null; waitdone
is "크기·수정 시각을 맞춘 변경도 감지" "$(st s.status)" handoff; has "사유에 그 파일" "$(st s.handoff.reason)" 'notes.txt'
# 작업자가 백그라운드로 남긴 프로세스는 그 단계가 끝날 때 정리한다 (남겨 두면 검사가 끝난 뒤에 파일을 바꿀 수 있다)
gws; printf '(sleep 2; echo late >> README.md) &\necho fixed >> lib/keep.txt\n' > gw.sh; out=$(node "$CLI" execute "$GPROG"); has "백그라운드를 남긴 작업자도 단계는 끝난다" "$out" 'DONE: fixed'
has "남은 프로세스를 정리했다고 기록" "$(cat .step-harness/reports/worker-1.txt)" 'left running by the worker were stopped'; sleep 2.6
is "정리된 프로세스는 나중에 파일을 바꾸지 못함" "$(cat README.md)" base
# 하네스가 직접 돌리는 git 은 설정에 적힌 명령(fsmonitor)을 실행하지 않는다 (작업자가 쓸 수 있는 ~/.gitconfig 를 거쳐 하네스 프로세스가 엉뚱한 명령을 돌리지 않게)
gws; FH="$(mktemp -d)"; printf '#!/bin/sh\ntouch "%s/RAN"\n' "$FH" > "$FH/fsm.sh"; chmod +x "$FH/fsm.sh"; printf '[core]\n\tfsmonitor = %s/fsm.sh\n' "$FH" > "$FH/.gitconfig"
HOME="$FH" git status >/dev/null 2>&1; [ -e "$FH/RAN" ] && ok "(대조) 그 설정이면 보통의 git status 는 그 명령을 실행한다" || bad "(대조) fsmonitor 설정이 먹지 않음 — 이 테스트는 의미가 없다"
rm -f "$FH/RAN"; out=$(HOME="$FH" node "$CLI" execute "$GPROG"); has "사용자 git 설정이 있어도 정상 완료" "$out" 'DONE: fixed'
[ ! -e "$FH/RAN" ] && ok "하네스의 git 은 사용자 설정의 명령을 실행하지 않음" || bad "하네스의 git 이 ~/.gitconfig 의 fsmonitor 명령을 실행함"
gws; git config core.fsmonitor "$FH/fsm.sh"; rm -f "$FH/RAN"; out=$(node "$CLI" execute "$GPROG"); has "저장소 설정에 fsmonitor 가 있어도 정상 완료" "$out" 'DONE: fixed'
[ ! -e "$FH/RAN" ] && ok "하네스의 git 은 저장소 설정의 fsmonitor 도 실행하지 않음" || bad "하네스의 git 이 저장소 설정의 fsmonitor 명령을 실행함"
# 작업자가 PATH 앞쪽 폴더에 `git` 이라는 파일을 심어도 하네스는 그것을 실행하지 않는다 (처음에 정한 절대 경로의 git 만 쓴다)
gws; mkdir -p "$FH/bin"; rm -f "$FH/RAN"
printf 'printf "#!/bin/sh\\ntouch %s/RAN\\nexit 0\\n" > %s/bin/git; chmod +x %s/bin/git; echo hacked >> README.md; echo fixed >> lib/keep.txt\n' "$FH" "$FH" "$FH" > gw.sh
PATH="$FH/bin:$PATH" node "$CLI" execute "$GPROG" >/dev/null; waitdone
[ -x "$FH/bin/git" ] && [ ! -e "$FH/RAN" ] && ok "심어 둔 가짜 git 은 실행되지 않음" || bad "하네스가 PATH 에 심은 가짜 git 을 실행함"
is "진짜 git 으로 범위 밖 변경을 그대로 잡는다" "$(st s.status)" handoff; has "사유에 바뀐 파일" "$(st s.handoff.reason)" 'README.md'
# git 이 설정·필터·무시 목록을 다른 곳에서 읽게 만드는 파일을 작업자가 건드리면 git 을 돌리기 전에 멈춘다
gws; printf 'mkdir -p lib/evil && cp -R .git/. lib/evil/ 2>/dev/null; echo lib/evil > .git/commondir; echo fixed >> lib/keep.txt\n' > gw.sh; node "$CLI" execute "$GPROG" >/dev/null; waitdone
is ".git/commondir 를 바꾸면 handoff" "$(st s.status)" handoff; has "사유에 commondir" "$(st s.handoff.reason)" 'commondir'; rm -f .git/commondir
gws; printf 'mkdir -p .git/info; echo planted.sh >> .git/info/exclude; echo x > planted.sh; echo fixed >> lib/keep.txt\n' > gw.sh; node "$CLI" execute "$GPROG" >/dev/null; waitdone
is "무시 목록에 올려 숨긴 범위 밖 파일도 handoff" "$(st s.status)" handoff; has "사유에 무시 목록 파일" "$(st s.handoff.reason)" 'info/exclude'
# 작업자가 커밋을 해도(파일은 그대로, git 목록에서만 사라짐) 범위 밖 변경으로 잘못 잡지 않는다. 반대로 남의 변경을 되돌리면 잡는다
gws; echo dirty >> README.md; printf 'echo fixed >> lib/keep.txt\ngit add -A >/dev/null 2>&1 && git -c user.email=t@t -c user.name=t commit -qm worker >/dev/null 2>&1\n' > gw.sh
out=$(node "$CLI" execute "$GPROG"); has "작업자의 커밋은 범위 밖 변경이 아님" "$out" 'DONE: fixed'
gws; echo dirty >> README.md; printf 'git checkout -- README.md\necho fixed >> lib/keep.txt\n' > gw.sh; node "$CLI" execute "$GPROG" >/dev/null; waitdone
is "실행 전의 미커밋 변경을 되돌리면 범위 밖 변경" "$(st s.status)" handoff; has "사유에 되돌린 파일" "$(st s.handoff.reason)" 'README.md'
# 작업자가 범위 밖 파일을 고치고 커밋까지 해도 잡는다 (커밋하면 git status 에서는 사라진다 → 실행 전후의 커밋을 비교한다)
GC='git -c user.email=t@t -c user.name=t'
gws; printf 'echo hacked >> README.md; echo fixed >> lib/keep.txt\n%s commit -qam worker >/dev/null 2>&1\n' "$GC" > gw.sh; node "$CLI" execute "$GPROG" >/dev/null; waitdone
is "범위 밖 파일을 고치고 커밋해도 handoff" "$(st s.status)" handoff; has "사유에 커밋된 파일" "$(st s.handoff.reason)" 'README.md'; hasnt "범위 안에서 고친 파일은 문제 삼지 않음" "$(st s.handoff.reason)" 'keep.txt'
gws; printf 'echo new > extra.txt; echo fixed >> lib/keep.txt\ngit add -A >/dev/null 2>&1; %s commit -qm worker >/dev/null 2>&1\n' "$GC" > gw.sh; node "$CLI" execute "$GPROG" >/dev/null; waitdone
is "범위 밖에 새 파일을 만들고 커밋해도 handoff" "$(st s.status)" handoff; has "사유에 새 파일" "$(st s.handoff.reason)" 'extra.txt'; hasnt "실행 전부터 있던 미커밋 파일은 같이 커밋돼도 문제 삼지 않음" "$(st s.handoff.reason)" 'notes.txt'
gws; rm -rf .git; git init -q .; printf 'echo new > extra.txt; echo fixed >> lib/keep.txt\ngit add -A >/dev/null 2>&1; %s commit -qm first >/dev/null 2>&1\n' "$GC" > gw.sh; node "$CLI" execute "$GPROG" >/dev/null; waitdone
is "커밋이 없던 저장소에서 작업자가 첫 커밋을 만든 경우도 handoff" "$(st s.status)" handoff; has "사유에 새 파일" "$(st s.handoff.reason)" 'extra.txt'; hasnt "원래 있던 파일은 문제 삼지 않음" "$(st s.handoff.reason)" 'README.md'
gws; rm -rf .git; git init -q .; printf 'echo fixed >> lib/keep.txt\ngit add -A >/dev/null 2>&1; %s commit -qm first >/dev/null 2>&1\n' "$GC" > gw.sh; out=$(node "$CLI" execute "$GPROG"); has "첫 커밋이라도 범위 안에서만 바꿨으면 완료" "$out" 'DONE: fixed'
# git 이 보지 않게 표시해서 숨긴 변경(assume-unchanged), 커밋을 다른 내용으로 보이게 한 변경(git replace)도 잡는다
gws; printf 'echo hacked >> README.md; git update-index --assume-unchanged README.md; echo fixed >> lib/keep.txt\n' > gw.sh; node "$CLI" execute "$GPROG" >/dev/null; waitdone
[ -z "$(git status --porcelain README.md)" ] && ok "(대조) 그렇게 표시하면 보통의 git status 에는 보이지 않는다" || bad "(대조) assume-unchanged 가 먹지 않음 — 이 테스트는 의미가 없다"
is "숨김 표시를 한 범위 밖 변경도 handoff" "$(st s.status)" handoff; has "사유에 숨긴 파일" "$(st s.handoff.reason)" 'README.md'
gws; cat > gw.sh <<'X'
G='git -c user.email=t@t -c user.name=t'
echo hacked >> README.md; o=$(git rev-parse HEAD); git add README.md; $G commit -qm x; n=$(git rev-parse HEAD)
git reset -q --soft "$o"; git replace "$o" "$n"
echo fixed >> lib/keep.txt
X
node "$CLI" execute "$GPROG" >/dev/null; waitdone
[ -z "$(git status --porcelain README.md)" ] && ok "(대조) 커밋을 바꿔치기하면 보통의 git status 에는 보이지 않는다" || bad "(대조) git replace 가 먹지 않음 — 이 테스트는 의미가 없다"
is "커밋 바꿔치기로 숨긴 범위 밖 변경도 handoff" "$(st s.status)" handoff; has "사유에 숨긴 파일" "$(st s.handoff.reason)" 'README.md'
# 무시 목록 파일이 자기 자신까지 무시하게 만들어 숨긴 새 파일도 잡는다 (그 .gitignore 도, 그것이 가린 파일도 git status 에는 나오지 않는다)
dgs() { gws; mkdir -p docs; echo a > docs/a.md; git add docs >/dev/null 2>&1; $GC commit -qm docs >/dev/null 2>&1; }
dgs; printf 'printf "*\\n" > docs/.gitignore; echo x > docs/new.md; echo fixed >> lib/keep.txt\n' > gw.sh; node "$CLI" execute "$GPROG" >/dev/null; waitdone
[ -z "$(git status --porcelain docs)" ] && [ -f docs/new.md ] && ok "(대조) 그렇게 하면 보통의 git status 에는 아무것도 보이지 않는다" || bad "(대조) 자기 자신을 무시하는 .gitignore 가 먹지 않음 — 이 테스트는 의미가 없다"
is "자기 자신을 숨기는 .gitignore 로 가린 범위 밖 새 파일 → handoff" "$(st s.status)" handoff; has "사유에 그 무시 목록 파일" "$(st s.handoff.reason)" 'docs/.gitignore'
dgs; printf 'echo planted.sh >> .gitignore; echo x > planted.sh; echo fixed >> lib/keep.txt\n' > gw.sh; node "$CLI" execute "$GPROG" >/dev/null; waitdone
is "원래 있던 .gitignore 에 줄을 더해 숨겨도 handoff" "$(st s.status)" handoff; has "사유에 고친 무시 목록 파일" "$(st s.handoff.reason)" '.gitignore'
dgs; printf 'mkdir -p .tool_cache; printf "*\\n" > .tool_cache/.gitignore; echo x > .tool_cache/data; echo fixed >> lib/keep.txt\n' > gw.sh; out=$(node "$CLI" execute "$GPROG")
has "도구가 새로 만든 캐시 폴더(전부 무시)는 문제 삼지 않음" "$out" 'DONE: fixed'
dgs; printf 'printf "*.tmp\\n" > lib/.gitignore; echo x > lib/a.tmp; echo fixed >> lib/keep.txt\n' > gw.sh; out=$(node "$CLI" execute "$GPROG"); has "범위 안에 만든 .gitignore 는 범위 안 변경" "$out" 'DONE: fixed'
# git 이 답하지 못하게 만들면(색인 손상) 검사를 건너뛰지 않고 멈춘다
gws; printf 'echo hacked >> README.md; printf junk > .git/index; echo fixed >> lib/keep.txt\n' > gw.sh; node "$CLI" execute "$GPROG" >/dev/null; waitdone
is "작업자가 돈 뒤 git 이 답하지 못하면 handoff" "$(st s.status)" handoff; has "사유는 확인할 수 없다는 것" "$(st s.handoff.reason)" 'git 으로 변경을 확인할 수 없음'
# 안에 따로 있는 git 저장소(하위 모듈 등)는 폴더 한 덩어리로 본다: 그 안을 범위 밖에서 고치면 잡는다 (이미 고쳐져 있던 저장소 안을 또 고쳐도)
nws() { gws; mkdir -p "${1:-vendor}"; (cd "${1:-vendor}" && git init -q . && echo 1 > f && git add f && $GC commit -qm n) >/dev/null 2>&1
  git add -A >/dev/null 2>&1; $GC commit -qm with-nested >/dev/null 2>&1; }
nws; printf 'echo 2 >> vendor/f; echo fixed >> lib/keep.txt\n' > gw.sh; node "$CLI" execute "$GPROG" >/dev/null; waitdone
is "안에 있는 저장소의 범위 밖 변경 → handoff" "$(st s.status)" handoff; has "사유에 그 폴더" "$(st s.handoff.reason)" 'vendor'
nws; echo mine >> vendor/f; printf 'echo x > vendor/other; echo fixed >> lib/keep.txt\n' > gw.sh; node "$CLI" execute "$GPROG" >/dev/null; waitdone
is "이미 고쳐져 있던 저장소 안을 또 고쳐도 handoff" "$(st s.status)" handoff; has "사유에 그 폴더" "$(st s.handoff.reason)" 'vendor'
nws; echo mine >> vendor/f; out=$(node "$CLI" execute "$GPROG"); has "안에 있는 저장소가 이미 고쳐져 있어도 작업자가 건드리지 않았으면 완료" "$out" 'DONE: fixed'
nws test; printf 'echo 2 >> test/f\n' > gw.sh; out=$(node "$CLI" execute "$(echo "$GPROG" | sed 's#lib/\*\*#test/**#')"); has "범위가 그 저장소 폴더 전체를 덮으면 범위 안" "$out" 'DONE: fixed'
nws; git -C vendor config core.fsmonitor "$FH/fsm.sh"; echo mine >> vendor/f; rm -f "$FH/RAN"; git -C vendor status >/dev/null 2>&1
[ -e "$FH/RAN" ] && ok "(대조) 안에 있는 저장소의 설정이면 그 안의 git status 는 그 명령을 실행한다" || bad "(대조) 중첩 저장소의 fsmonitor 설정이 먹지 않음 — 이 테스트는 의미가 없다"
rm -f "$FH/RAN"; out=$(node "$CLI" execute "$GPROG"); has "안에 있는 저장소 설정에 fsmonitor 가 있어도 정상 완료" "$out" 'DONE: fixed'
[ ! -e "$FH/RAN" ] && ok "하네스의 git 은 안에 있는 저장소 설정의 fsmonitor 도 실행하지 않음" || bad "하네스의 git 이 중첩 저장소 설정의 fsmonitor 명령을 실행함"
# 작업자 샌드박스(macOS): 작업자의 프로세스 트리 전체가 하네스 상태·git hook 에 쓰지 못한다. 분리해 띄운 프로세스가 나중에 고치는 것도 막힌다
if [ "$(uname -s)" = Darwin ] && [ -x /usr/bin/sandbox-exec ]; then
  gws; setcfg 'c.worker_sandbox=true; c.gates.sb={cmd:"sh sbgate.sh"}'
  printf '(echo x > .step-harness/planted) 2>/dev/null && echo GATE-WROTE || echo GATE-DENIED\n(echo x > .mcp.json) 2>/dev/null && echo MCP-WROTE || echo MCP-DENIED\nexit 0\n' > sbgate.sh
  cat > gw.sh <<'X'
ev() { printf '{"hook_event_name":"PreToolUse","session_id":"w","prompt_id":"w","tool_name":"edit","tool_input":{"file_path":"%s"}}' "$1" | DEVIN_PROJECT_DIR="$PWD" node "$HOOK" >/dev/null 2>&1; echo "$1 hook_exit=$?" >> .w_sb; }
ev lib/keep.txt; ev README.md
FORGE='const fs=require("fs"),p=".st"+"ep-harness/state.json";try{const s=JSON.parse(fs.readFileSync(p,"utf8"));s.status="done";s.exec=null;s.handoff=null;fs.writeFileSync(p,JSON.stringify(s));console.log("forge: WROTE")}catch(e){console.log("forge: "+e.code)}'
node -e "$FORGE" >> .w_sb
node -e 'require("child_process").spawn(process.execPath,["-e","setTimeout(()=>{"+process.argv[1]+"},1500)"],{detached:true,stdio:"ignore"}).unref()' "$FORGE"
(mkdir -p .git/hooks && echo x > .git/hooks/pre-commit) 2>/dev/null && echo "githook: WROTE" >> .w_sb || echo "githook: denied" >> .w_sb
here=$(basename "$PWD"); (cd .. && mv "$here" "$here.moved" 2>/dev/null && { echo forged > "$here.moved/.step-harness/state.json" 2>/dev/null; mv "$here.moved" "$here"; echo "rename: MOVED"; } || echo "rename: denied") >> .w_sb
(mv .git .git2 2>/dev/null && { mv .git2 .git; echo "gitdir: MOVED"; } || echo "gitdir: denied") >> .w_sb
(echo x > .STEP-HARNESS/state.json) 2>/dev/null && echo "upper: WROTE" >> .w_sb || echo "upper: denied" >> .w_sb
(ln .step-harness/state.json lib/alias) 2>/dev/null && echo "hardlink: MADE" >> .w_sb || echo "hardlink: denied" >> .w_sb
git add -A >/dev/null 2>&1 && echo "git add: ok" >> .w_sb || echo "git add: FAILED" >> .w_sb
(echo x > "$FAKEBIN/node") 2>/dev/null && echo "pathnode: WROTE" >> .w_sb || echo "pathnode: denied" >> .w_sb
(echo x > "$FAKEBIN/other") 2>/dev/null && echo "pathother: ok" >> .w_sb || echo "pathother: DENIED" >> .w_sb
(mv "$FAKEBIN" "$FAKEBIN.x" 2>/dev/null && { mv "$FAKEBIN.x" "$FAKEBIN"; echo "pathdir: MOVED"; } || echo "pathdir: denied") >> .w_sb
(echo x >> "$HOME/.zshenv") 2>/dev/null && echo "zshenv: WROTE" >> .w_sb || echo "zshenv: denied" >> .w_sb
echo fixed >> lib/keep.txt
exit 0
X
  # (가짜 PATH 폴더와 가짜 홈으로 시험한다 — 막지 못했을 때 실제 실행 파일·설정이 바뀌지 않도록)
  mkdir -p "$FH/sbbin" "$FH/sbhome"
  FAKEBIN="$FH/sbbin" PATH="$FH/sbbin:$PATH" HOME="$FH/sbhome" node "$CLI" execute 'async (h) => { await h.agent("fixer", "fix", { scope: ["lib/**"] }); await h.check("sb"); return h.handoff("사람 확인 필요"); }' >/dev/null; waitdone
  has "샌드박스: 게이트도 같은 제한 안에서 돈다" "$(cat .step-harness/reports/sb.txt)" 'GATE-DENIED'; has "샌드박스: 프로젝트의 MCP 설정 파일도 보호" "$(cat .step-harness/reports/sb.txt)" 'MCP-DENIED'
  has "샌드박스 안에서도 hook 은 동작: 범위 안 허용" "$(cat .w_sb)" 'lib/keep.txt hook_exit=0'; has "샌드박스 안에서도 hook 은 동작: 범위 밖 차단" "$(cat .w_sb)" 'README.md hook_exit=2'
  has "샌드박스: 상태 파일 쓰기는 OS 가 거부" "$(cat .w_sb)" 'forge: EPERM'; has "샌드박스: git hook 쓰기 거부" "$(cat .w_sb)" 'githook: denied'
  has "샌드박스: 프로젝트 폴더 이름을 바꿔 피해 갈 수 없음" "$(cat .w_sb)" 'rename: denied'; has "샌드박스: .git 이름을 바꿔 피해 갈 수 없음" "$(cat .w_sb)" 'gitdir: denied'
  has "샌드박스: 대문자 경로도 거부" "$(cat .w_sb)" 'upper: denied'; has "샌드박스: 하드링크로 피해 갈 수 없음" "$(cat .w_sb)" 'hardlink: denied'
  has "샌드박스: 평소의 git 작업은 된다" "$(cat .w_sb)" 'git add: ok'
  # 하네스의 hook·CLI 는 샌드박스 밖에서 `node …` 로 시작된다 → 작업자가 그 node 를 가로챌 수 없어야 한다
  has "샌드박스: PATH 폴더에 node 를 심을 수 없음" "$(cat .w_sb)" 'pathnode: denied'; has "샌드박스: PATH 폴더의 다른 파일은 쓸 수 있음" "$(cat .w_sb)" 'pathother: ok'
  has "샌드박스: PATH 폴더 이름을 바꿔 피해 갈 수 없음" "$(cat .w_sb)" 'pathdir: denied'; has "샌드박스: 셸 시작 파일을 고칠 수 없음" "$(cat .w_sb)" 'zshenv: denied'
  is "샌드박스: 범위 안 쓰기는 된다" "$(tail -1 lib/keep.txt)" fixed; sleep 2.2
  is "샌드박스: 분리해 띄운 프로세스가 나중에 상태를 고치지 못함" "$(st s.status)" handoff; is "사유는 프로그램이 남긴 그대로" "$(st s.handoff.reason)" '사람 확인 필요'
fi
# 저장소의 하위 폴더가 프로젝트일 때: 폴더 밖(같은 저장소의 다른 곳)을 바꿔도 잡는다
R="$(mktemp -d)"; mkdir -p "$R/sub/lib" "$R/sub/.step-harness" "$R/other"; W="$R/sub"; cd "$W"
echo '{"worker":"sh -c \"echo x > ../other/leak.txt\""}' > .step-harness/config.json; echo a > lib/a.txt
(cd "$R" && git init -q . && git -c user.email=t@t -c user.name=t add -A >/dev/null 2>&1 && git -c user.email=t@t -c user.name=t commit -qm init >/dev/null 2>&1)
node "$CLI" execute "$(echo "$GPROG" | sed 's/"fixer"/"any"/')" >/dev/null; waitdone
is "하위 폴더 프로젝트: 폴더 밖 변경 → handoff" "$(st s.status)" handoff; has "사유에 폴더 밖 경로" "$(st s.handoff.reason)" '../other/leak.txt'

# 실행 중에 설정에서 게이트가 사라진 경우: 빈 명령(exit 0)을 통과로 치지 않는다
dws; echo 9 > .w_need; hook "$(ups s1 p1 '완료조건: 설정이 바뀜')" >/dev/null; setcfg 'delete c.gates.cc; c.gates.other="true"'
node "$CLI" execute "$LIE" >/dev/null; waitdone
is "완료 조건의 게이트가 사라지면 완료가 아니라 handoff" "$(st s.status)" handoff; has "사유: 게이트가 설정에 없음" "$(st s.handoff.reason)" '완료 조건의 게이트'

# 작업자가 hook 을 거치지 않고(셸) 하네스의 상태·설정 파일을 직접 고친 경우: 결과로 판단해 사람에게 넘긴다
tws() { pws; printf '%s\n' "$1" > tw.sh; setcfg 'c.worker="bash tw.sh {prompt_file}"'; }
FORGE='node -e "const fs=require(\"fs\"),p=\".step-harness/state.json\",s=JSON.parse(fs.readFileSync(p,\"utf8\"));s.status=\"done\";fs.writeFileSync(p,JSON.stringify(s))"'
tws "$FORGE"; node "$CLI" execute "$GPROG" >/dev/null; waitdone
is "상태 파일을 done 으로 고쳐도 완료가 되지 않음" "$(st s.status)" handoff; has "사유: 상태 파일이 직접 수정됨" "$(st s.handoff.reason)" '상태 파일이 직접 수정됨'
tws "$FORGE; sleep 6"; (node "$CLI" execute "$GPROG" >/dev/null 2>&1 &); sleep 1.5
out=$(node "$CLI" check --wait 1); has "실행이 아직 도는 중에 done 으로 고친 것도 잡는다" "$out" 'PAUSED'; is "위조된 완료 → handoff" "$(st s.status)" handoff
FORGE2='node -e "const fs=require(\"fs\"),p=\".step-harness/state.json\",s=JSON.parse(fs.readFileSync(p,\"utf8\"));s.status=\"done\";s.exec=null;s.inFlight=null;s.action=null;s.seq+=1;s.run=\"zz\";fs.writeFileSync(p,JSON.stringify(s))"'
tws "$FORGE2"; node "$CLI" execute "$GPROG" >/dev/null; sleep 0.5; waitdone
is "단계 번호·실행 id 까지 고친 위조도 받아들이지 않음" "$(st s.status)" handoff; has "사유: 상태 파일이 직접 수정됨 (2)" "$(st s.handoff.reason)" '상태 파일이 직접 수정됨'
out=$(hook "$(ups s1 p2 'retry')"); has "위조 뒤에도 흐름은 이어진다 (retry → 새 프로그램 요청)" "$out" 'PROGRAM — do not do the work yourself'
FORGE3='node -e "const fs=require(\"fs\"),p=\".step-harness/state.json\",s=JSON.parse(fs.readFileSync(p,\"utf8\"));s.status=\"stopped\";s.exec=null;fs.writeFileSync(p,JSON.stringify(s))"'
tws "$FORGE3"; hook "$(ups s1 p1 '프로그램: 위조된 중단')" >/dev/null; node "$CLI" execute "$GPROG" >/dev/null; sleep 2; waitdone
is "상태 파일을 stopped 로 고쳐도 흐름이 풀리지 않음" "$(st s.status)" handoff; has "사유: stopped 로 바뀌어 있었음" "$(st s.handoff.reason)" 'stopped'
expect "되돌린 뒤에는 그 턴의 직접 수정도 다시 막힌다" 2 "$(pre s1 p1 edit "$EDIT_IN")"
tws "$FORGE2; sleep 6"; (node "$CLI" execute "$GPROG" >/dev/null 2>&1 &); sleep 1.5
out=$(node "$CLI" check --wait 1); hasnt "실행 프로세스가 살아 있는 동안에는 위조된 완료를 알리지 않음" "$out" 'DONE:'; has "대신 사람에게 넘김" "$out" 'PAUSED'
is "위조된 완료(실행 기록까지 지움) → handoff" "$(st s.status)" handoff; sleep 0.3
is "남은 실행 프로세스 정리" "$(node -e 'console.log(require(process.argv[1]).liveExecs(process.argv[2]).length)' "$HERE/scripts/judge.cjs" "$W")" 0
tws 'sleep 30'; hook "$(ups s1 p1 '프로그램: 사람이 멈춤')" >/dev/null; (node "$CLI" execute "$GPROG" >/dev/null 2>&1 &); sleep 1.5
hook "$(ups s1 p2 'harness stop')" >/dev/null; sleep 2.2
is "사람이 멈춘 것은 그대로 중단 (위조로 보지 않음)" "$(st s.status)" stopped; is "중단 뒤 실행 프로세스 기록 정리" "$(st 'String(s.exec)')" null
is "사람이 멈추면 실행 프로세스도 정리" "$(node -e 'console.log(require(process.argv[1]).liveExecs(process.argv[2]).length)' "$HERE/scripts/judge.cjs" "$W")" 0
# 작업자가 하네스의 사람용 명령(reset · resume · execute)을 직접 실행해도 듣지 않는다
tws 'node "$(dirname "$HOOK")/harness.cjs" reset > .w_reset 2>&1; node "$(dirname "$HOOK")/harness.cjs" resume --proceed >> .w_reset 2>&1; echo fixed >> lib/keep.txt'
out=$(node "$CLI" execute "$GPROG"); has "작업자의 reset 은 거부" "$(cat .w_reset)" 'not available inside a harness worker'
has "흐름은 멈추지 않고 정상적으로 끝남" "$out" 'DONE: fixed'; is "작업자의 reset 뒤에도 상태는 done" "$(st s.status)" done
tws 'echo " " >> .step-harness/config.json'; node "$CLI" execute "$GPROG" >/dev/null; waitdone
is "작업자가 설정 파일을 고치면 handoff (git 이 없어도)" "$(st s.status)" handoff; has "사유: 보호 대상 파일이 바뀜" "$(st s.handoff.reason)" '보호 대상 파일이 바뀜'
has "바뀐 파일 이름" "$(st s.handoff.reason)" 'config.json'

# MCP 서버: 어느 프로젝트인지 알 수 없으면(플러그인 폴더에서 떴고 환경변수도 없음) 엉뚱한 곳에 쓰지 않고 거부한다
out=$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"search","arguments":{}}}' \
  | (cd "$HERE" && env -u DEVIN_PROJECT_DIR -u CLAUDE_PROJECT_DIR -u STEP_HARNESS_ROOT node scripts/mcp.cjs))
has "MCP: 프로젝트를 모르면 거부" "$out" 'cannot tell which project'; [ ! -e "$HERE/.step-harness" ] && ok "MCP: 플러그인 폴더에 상태를 만들지 않음" || bad "MCP: 플러그인 폴더에 상태가 생김"
D="$(mktemp -d)"; out=$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' "$(node -e 'console.log(JSON.stringify({jsonrpc:"2.0",id:2,method:"tools/call",params:{name:"execute",arguments:{code:process.argv[1]}}}))' "$GPROG")" \
  | (cd "$D" && env -u DEVIN_PROJECT_DIR -u CLAUDE_PROJECT_DIR -u STEP_HARNESS_ROOT node "$HERE/scripts/mcp.cjs"))
has "MCP: 프로젝트로 보이지 않는 폴더(저장소도 상태 폴더도 없음)에서는 실행하지 않음" "$out" 'cannot tell which project'; [ ! -e "$D/.step-harness" ] && ok "MCP: 그 폴더에 상태를 만들지 않음" || bad "MCP: 엉뚱한 폴더에 상태가 생김"
out=$(printf 'null\n[{"jsonrpc":"2.0","id":2,"method":"ping"}]\n{"jsonrpc":"2.0","id":3,"method":"ping"}\n' | node "$HERE/scripts/mcp.cjs"); is "MCP: 잘못된 입력에 죽지 않음" "$?" 0
has "MCP: 잘못된 입력에는 오류 응답" "$out" '"code":-32600'; has "MCP: 그 뒤의 요청은 정상 처리" "$out" '"id":3,"result":{}'
pws; out=$( (printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{"roots":{}}}}' '{"jsonrpc":"2.0","method":"notifications/initialized"}' '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"search","arguments":{}}}'; sleep 0.4; \
  printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":\"step-harness-roots\",\"result\":{\"roots\":[{\"uri\":\"file://$W\"}]}}") | (cd "$D" && env -u DEVIN_PROJECT_DIR -u CLAUDE_PROJECT_DIR -u STEP_HARNESS_ROOT node "$HERE/scripts/mcp.cjs"))
has "MCP: 작업 폴더 답이 오기 전에 온 도구 호출은 답을 기다렸다가 처리" "$out" 'check(gate: \"cc\")'
pws; out=$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{"roots":{}}}}' '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  "{\"jsonrpc\":\"2.0\",\"id\":\"step-harness-roots\",\"result\":{\"roots\":[{\"uri\":\"file://$W\"}]}}" '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"search","arguments":{}}}' \
  | (cd "$HERE" && env -u DEVIN_PROJECT_DIR -u CLAUDE_PROJECT_DIR -u STEP_HARNESS_ROOT node scripts/mcp.cjs))
has "MCP: 클라이언트에 작업 폴더를 묻는다 (roots/list)" "$out" '"method":"roots/list"'; has "MCP: 알려준 폴더의 등록부를 쓴다" "$out" 'check(gate: \"cc\")'

echo; echo "pass=$pass fail=$fail"
[ "$fail" = 0 ]
