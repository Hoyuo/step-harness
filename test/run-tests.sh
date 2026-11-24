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
  node -e 'const fs=require("fs");const f=JSON.parse(fs.readFileSync(process.argv[1]+"/test/fixtures/code-complete.flow.json","utf8"));
    fs.writeFileSync("cc.flow.json",JSON.stringify({...f,max_blocks:60,max_idle_calls:60}));
    fs.writeFileSync("cc1.flow.json",JSON.stringify({...f,max_visits:1,max_blocks:60}));' "$HERE"
  cat > .step-harness/router.json <<J
{ "routes": [
  { "name": "cc", "when": "^코드 컴플리트 돌려", "flow": "cc.flow.json", "args": { "gate": "bash gate.sh" } },
  { "name": "cc1", "when": "^한번만 코드 컴플리트", "flow": "cc1.flow.json", "args": { "gate": "bash gate.sh" } },
  { "name": "cc-strict", "when": "^엄격", "flow": "$HERE/test/fixtures/code-complete.flow.yaml", "args": { "gate": "bash gate.sh" } },
  { "name": "delegate", "when": "^fix: (\\\\S+)", "flow": "$HERE/test/fixtures/delegate.flow.yaml", "args": { "target": "\$1", "verify": "bash gate.sh" } },
  { "name": "both-a", "when": "모호", "flow": "cc.flow.json", "args": { "gate": "true" } },
  { "name": "both-b", "when": "모호", "flow": "cc1.flow.json", "args": { "gate": "true" } }
] }
J
  echo '{"plan":"prefix","wait":{"prompt":4,"post":4,"stop":4}}' > .step-harness/config.json
}
cfg() { node -e 'require("fs").writeFileSync(".step-harness/config.json",JSON.stringify({plan:"prefix",...JSON.parse(process.argv[1])}))' "$1"; }
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
out=$(node "$CLI" start cc.flow.json gate='bash gate.sh'); has "judge 로 시작 → NEXT_ACTION 은 check" "$out" 'harness.cjs" check'
out=$(node "$CLI" check --wait 1); has "아직 판정 중 → STILL RUNNING" "$out" 'STILL RUNNING'
node "$CLI" check --wait 1 >/dev/null & node "$CLI" check --wait 1 >/dev/null & wait
out=$(node "$CLI" check --wait 8); has "판정 결과 출력" "$out" 'FAILED: gate (route=unit-test)'; has "다음 액션 출력" "$out" 'tool: skill'
is "check 를 여러 번·동시에 불러도 게이트는 1회" "$(cat .gate_runs)" 1
hook "$(pre s1 p1 skill "$SK")" >/dev/null; out=$(hook "$(post s1 p1 skill "$SK")")
has "wait 0: hook 은 기다리지 않고 check 지시" "$out" 'harness.cjs\" check'
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

echo "[X] 프로그램: 문법 · 검증 · 한 걸음씩 되짚기 · 허용 명령"
if node - "$HERE" <<'N'
const P = require(process.argv[2] + '/scripts/program.cjs'); const assert = require('assert');
const reg = { gates: { cc: 'x' }, skills: { s1: '' }, agents: { fixer: '' }, writable: ['lib/**', 'test/**'] };
const ok = (c) => assert.deepStrictEqual(P.compile(c, reg).errors, [], c);
const no = (c, frag) => { const e = P.compile(c, reg).errors.join('\n'); assert(e.includes(frag), `${c}\n→ ${e || '(accepted)'}\n  want: ${frag}`); };
ok('async (h) => { const r = await h.check("cc"); if (r.pass) return h.done("ok"); return h.handoff(`failed ${r.report}`); }');
ok('(async (h: H) => { for (const i of h.retries(2)) { const r = await h.check("cc"); if (r?.pass) break; await h.agent("fixer", "fix", { scope: ["lib/**"] }); } return h.done(); });');
ok('async (h) => { await h.work("add a button", { scope: ["lib/**"] }); return h.done("added"); }');
no('async (h) => { await h.work("x"); return h.done(); }', 'h.work(task: string, { scope: [...] })');
no('async (h) => { await h.work("x", { scope: ["src/**"] }); return h.done(); }', 'not in the writable list');
no('async (h) => { return h.work("x", { scope: ["lib/**"] }); }', 'not h.work');
no('async (h) => { while (true) {} }', '(use for (const i of h.retries(N)))');
no('async (h) => { let r = 1; return h.done(); }', '(use const)');
no('async (h) => { const r = await h.check("cc"); }', 'every path must end');
no('async (h) => { const r = await h.check("nope"); return h.done(); }', 'unknown gate "nope"');
no('async (h) => { await h.skill("s1", "a", { scope: ["**"] }); return h.done(); }', 'not in the writable list');
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
const c = P.compile('async (h) => { for (const i of h.retries(3)) { const r = await h.check("cc"); if (r.pass) return h.done(`ok after ${i}`); if (r.route === "a") await h.skill("s1", r.report, { scope: ["lib/**"] }); else await h.work(`fix ${r.report}`, { scope: ["test/**"] }); } return h.handoff("gave up"); }', reg);
assert.deepStrictEqual(c.errors, []);
let n = 0; const calls = [];
const host = { maxSteps: 40, check: () => (++n === 3 ? { pass: true } : { pass: false, route: n === 1 ? 'a' : 'b', report: `r${n}` }),
  skill: (x, a, s) => (calls.push(`skill ${a} ${s}`), { ok: true }), work: (t, s) => (calls.push(`work ${t} ${s}`), { ok: true }), agent: () => ({ ok: true }) };
assert.deepStrictEqual(P.run(c.ast, host).message, 'ok after 3');
assert.deepStrictEqual(calls, ['skill r1 lib/**', 'work fix r2 test/**']);
assert.strictEqual(P.run(c.ast, { ...host, check: () => ({ pass: false, route: 'a', report: 'r' }) }).status, 'handoff');
assert.throws(() => P.run(c.ast, { ...host, maxSteps: 2, check: () => ({ pass: false, route: 'a' }) }), /step budget/);
// 한 걸음씩: 기록을 되짚어 다음 걸음을 구한다. 같은 기록이면 언제 다시 물어도 같은 걸음이다
const tr = [];
const results = [{ pass: false, route: 'a', report: 'R1', exit: 1 }, { ok: true }, { pass: false, route: 'b', report: 'R2', exit: 1 }, { ok: true }, { pass: true, route: null, report: 'R3', exit: 0 }];
const seen = [];
for (const res of results) {
  const a1 = P.next(c.ast, tr, 40), a2 = P.next(c.ast, tr, 40);
  assert.deepStrictEqual(a1, a2);
  seen.push(`${a1.step.op}:${a1.step.args[0]}`);
  tr.push({ key: a1.step.key, result: res });
}
assert.deepStrictEqual(seen, ['check:cc', 'skill:s1', 'check:cc', 'work:fix R2', 'check:cc']);
assert.deepStrictEqual(P.next(c.ast, tr, 40), { end: 'done', message: 'ok after 3' });
assert.throws(() => P.next(c.ast, [{ key: '["work","other",["lib/**"]]', result: { ok: true } }], 40), /do not match the program/);
assert.throws(() => P.next(c.ast, tr.slice(0, 4), 3), /step budget/);
// 쓰기 범위 (writable 목록이 없을 때): 이름으로 시작해야 하고, 숨김 경로·자리표시는 안 된다
const free = { gates: { cc: 'x', nocmd: { about: 'x' } } };
const sc = (g) => P.compile(`async (h) => { await h.work("t", { scope: [${JSON.stringify(g)}] }); return h.done(); }`, free).errors.join('\n');
for (const g of ['src/**', 'README.md', './lib/a/*.dart', 'docs/']) assert.strictEqual(sc(g), '', g);
for (const [g, frag] of [['**', 'too broad'], ['*/**', 'too broad'], ['?*/**', 'too broad'], ['**/*.ts', 'too broad'], ['.devin/**', 'hidden paths'], ['.git/hooks/*', 'hidden paths'],
  ['./.github/workflows/x.yml', 'hidden paths'], ['<dir>/**', 'placeholder'], ['/etc/passwd', 'only relative'], ['a/../../b', 'only relative'], ['x/.step-harness/y', 'harness files'], ['', 'empty'], ['-delete', 'may not start with "-"'], ['lib/-exec/**', 'may not start with "-"']]) {
  assert(sc(g).includes(frag), `${g} → ${sc(g) || '(accepted)'}`);
}
const noF = (c2, frag) => { const e = P.compile(c2, free).errors.join('\n'); assert(e.includes(frag), `${c2}\n→ ${e || '(accepted)'}\n  want: ${frag}`); };
noF('async (h) => { await h.check("nocmd"); return h.done(); }', 'has no command');
noF('async (h) => { for (const h of h.retries(2)) { await h.check("cc"); } return h.done(); }', 'cannot redeclare h');
noF('async (h) => { const r = await h.check("cc"); for (const r of h.retries(2)) { await h.check("cc"); } return h.done(); }', '"r" is already defined');
// 등록하지 않은 종류(스킬·서브에이전트)는 쓸 수 없다 → h.work 를 쓰라고 알려준다
noF('async (h) => { await h.agent("a", "t", { scope: ["src/**"] }); return h.done(); }', 'h.agent is not available');
noF('async (h) => { await h.skill("a", "t", { scope: ["src/**"] }); return h.done(); }', 'h.skill is not available');
// 반복: 겹친 횟수의 곱 상한(정적) + 연산 횟수 상한(동적)
const nest = (d) => { let b = 'await h.check("cc");'; for (let i = 0; i < d; i++) b = `for (const i${i} of h.retries(10)) { ${b} }`; return `async (h) => { ${b} return h.done(); }`; };
assert.deepStrictEqual(P.compile(nest(3), free).errors, []);
noF(nest(4), 'multiply to more than 1000');
assert.throws(() => P.run(P.compile(nest(3), free).ast, { maxSteps: 1e9, maxOps: 200, check: () => ({ pass: false }) }), /operation budget/);
// 흔한 실수에는 대안을 알려준다 (Opus 4.6 수준의 모델이 한두 번 안에 고쳐 내도록)
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
noF('async (h) => { await h.work("t", { scope: ["src/**"], scope: ["**"] }); return h.done(); }', 'duplicate key "scope"');
noF('async (h) => { await h.work("t", { scope: ["src/**"], "scope": [".git/**"] }); return h.done(); }', 'duplicate key "scope"');
no('async (h) => { await h.skill("s1", "a", { scope: ["lib/**"], scope: ["src/**"] }); return h.done(); }', 'duplicate key "scope"');
// 타입 표기는 받고 무시한다
for (const head of ['async (h: Harness<X>): Promise<void> =>', 'async (h): Promise<never> =>', '(async (h: H) =>']) {
  assert.deepStrictEqual(P.compile(`${head} { const r: Verdict = await h.check("cc"); const o: { pass: boolean } = r; if (o.pass) return h.done(); return h.handoff(); }${head.startsWith('(') ? ')' : ''}`, free).errors, [], head);
}
// 프롬프트에 넣는 예시는 (쓰기 범위가 정해져 있으면) 그 등록부에서 그대로 검증을 통과해야 한다. 정해져 있지 않으면 자리표시만 채우면 된다
assert.deepStrictEqual(P.compile(P.example(reg, ['cc']), reg).errors, []);
assert.deepStrictEqual(P.compile(P.example({ gates: {}, writable: ['lib/**'] }, []), { gates: {}, writable: ['lib/**'] }).errors, []);
assert.deepStrictEqual(P.compile(P.example(free, []).split('<dir>').join('src'), free).errors, []);
assert(P.declaration(reg, ['cc']).includes('accepted only if "cc" passes'));
// 선언에는 등록된 종류만 나온다 (없는 것을 보여주면 모델이 없는 스킬을 지어낸다)
assert(P.declaration(reg, []).includes('skill(name: "s1"') && P.declaration(reg, []).includes('agent(profile: "fixer"'));
assert(!P.declaration(free, []).includes('skill(') && !P.declaration(free, []).includes('agent(') && P.declaration(free, []).includes('work(task: string'));
assert(!P.declaration({ gates: {} }, []).includes('check('));
N
then ok "파서·검증기·인터프리터·되짚기 (거부 규칙 포함)"; else bad "파서·검증기·인터프리터·되짚기"; fi
if node - "$HERE" <<'N'
const L = require(process.argv[2] + '/scripts/lib.cjs'); const assert = require('assert');
const C = L.HARNESS_CLI, root = process.cwd();
const t = (cmd, sub) => assert.strictEqual(L.harnessCmd(root, cmd), sub, JSON.stringify(cmd));
t(`node "${C}" check`, 'check'); t(`node "${C}" check --wait 50`, 'check'); t(`node "${C}" plan`, 'plan'); t(`node '${C}' search`, 'search'); t(`node "${C}" search 'unit test'`, 'search'); t(`node "${C}" search unit`, 'search');
t(`node "${C}" execute <<'EOF'\nasync (h) => {}\nEOF`, 'execute'); t(`node "${C}" execute <<'EOF'\nx\nEOF\n`, 'execute'); t(`node "${C}" execute 'async (h) => {\n}'`, 'execute');
// 셸에서는 줄바꿈 뒤가 별개의 명령이다 → 낱말 사이의 줄바꿈은 받지 않는다. heredoc 은 따옴표 친 종료어 하나로 끝나야 한다
for (const bad of [`node "${C}" search\nmake`, `node "${C}"\ncheck`, `node "${C}" check\n--wait 5`, `node "${C}" check --wait\n5`, `node "${C}" execute\n'make'`, `node "${C}" execute\n<<'EOF'\nx\nEOF`,
  `node\n"${C}" check`, `node "${C}" search; make`, `node "${C}" search $(make)`, `node "${C}" search \`make\``, `node "${C}" execute <<EOF\nx\nEOF`, `node "${C}" execute <<-'EOF'\nx\nEOF`,
  `node "${C}" execute <<'EOF'\nx\nEOF\nmake`, `node "${C}" execute <<'EOF' | sh\nx\nEOF`, `node "${C}" execute <<'EOF'\nx\nEOF\ny\nEOF`, `node "/tmp/other/harness.cjs" check`,
  `node "${C}" check && make`, `node "${C}" reset`, `node "${C}" resume --proceed`, `node "${C}" plan; make`,
  `node "${C}" execute <<'EOF'\nx\nEOF `, `node "${C}" execute <<'EOF'\nx\nEOF\t`, `\r node "${C}" check`, ` node "${C}" check`, `node "${C}" check\f`]) t(bad, null);
t(`\n  node "${C}" check\n\n`, 'check');
// 상대 경로는 받지 않는다 (hook 은 프로젝트 루트 기준, 셸은 그때의 작업 폴더 기준으로 푼다 → 다른 파일이 실행될 수 있다)
assert.strictEqual(L.harnessCmd(L.PLUGIN_DIR, 'node scripts/harness.cjs check'), null);
assert.strictEqual(L.harnessCmd(L.PLUGIN_DIR, 'node ./scripts/harness.cjs check'), null);
assert.strictEqual(L.harnessCmd(L.PLUGIN_DIR, `node "${C}" check`), 'check');
for (const [name, yes] of [['mcp__step-harness__execute', true], ['mcp__step_harness__check', true], ['mcp__step-harness__plan', true], ['mcp__plugin_step-harness_step-harness__search', true],
  ['mcp__step-harness-evil__execute', false], ['mcp__other__execute', false], ['mcp__step-harness__reset', false]]) assert.strictEqual(L.isHarnessMcp(name), yes, name);
// 계획 없이 해도 되는 셸 명령: 읽기만 하는 명령과 그것을 | 로 이은 것. 모르는 명령·그 밖의 셸 문법은 "바꿀 수 있는 것"으로 본다
for (const c of ['ls -la', 'git status', 'grep -rn "foo bar" src | head -20', 'cat a | sort | uniq -c', 'find . -name "*.ts"', 'find . -name \\*.md', 'git branch -a', 'git branch', 'git log --oneline -5', 'git diff --stat',
  'rg foo', 'git remote -v', 'grep -o x f', "grep '$HOME' f", 'grep "a|b" f', "jq '.a | .b' x.json", 'file a.txt', 'date', 'ls *.js', 'cat docs/*.md | head -5', 'grep foo src/*.ts', "find . -name '*.ts'"])
  assert.strictEqual(L.readOnlyShell(c), true, c);
for (const c of ['find . -delete', 'find . -exec rm {} +', 'rm -rf x', 'ls; rm x', 'cat a > b', 'echo $(rm x)', 'echo "$(rm x)"', 'echo `rm x`', 'git commit -m x', 'git branch new', 'npm test', 'sort -o out in', 'cd x && ls', 'ls || rm x',
  'sed -n 1,5p f', 'git diff --output=x', 'rg --pre cat x', 'git remote add o u', 'tree -o f', 'tree --output f', 'uniq a b', '', 'ls\nrm x', 'git -C x status', 'cat a | tee b', 'cat a | sh', 'less -o x f', 'ls {a,b}', '(ls)', 'FOO=1 ls',
  'date -s 2020', 'grep "unterminated f', 'ls \\', undefined,
  // 따옴표·백슬래시로 감싼 옵션도 셸에게는 그 옵션이다. 줄여 쓴 옵션도 마찬가지다
  'tree -L 2', 'tree -R -L 1 d', 'find . *', 'git diff *', 'rg foo *', 'file *', 'find . "-exec" touch X {} +', 'find . -exe\\c touch X {} +', "find . '-delete'", 'git diff "--output=X"', 'git diff --outpu=X', 'rg "--pre=./p.sh" a f', 'rg --hostname-bin x a', 'file -C -m X', 'file "-C" -m X'])
  assert.strictEqual(L.readOnlyShell(c), false, String(c));
// 계획 없이 해도 되는 도구는 "읽기만 한다고 아는 것"뿐이다. MCP 도구와 모르는 도구는 무언가를 바꿀 수 있다고 본다
const d0 = require('fs').mkdtempSync(require('path').join(require('os').tmpdir(), 'np-'));
for (const [tool, input, yes] of [['write', {}, true], ['edit', {}, true], ['apply_patch', {}, true], ['exec', { command: 'make' }, true], ['exec', { command: 'find . "-exec" rm {} +' }, true], ['skill', {}, true], ['run_subagent', {}, true],
  ['mcp__filesystem__write_file', {}, true], ['mcp_call_tool', {}, true], ['kill_shell', {}, true], ['some_unknown_tool', {}, true],
  ['exec', { command: 'git status' }, false], ['read', {}, false], ['grep', {}, false], ['ask_user_question', {}, false], ['webfetch', {}, false], ['tool_search', {}, false], ['mcp_list_tools', {}, false]])
  assert.strictEqual(L.needsPlan(d0, tool, input), yes, tool + JSON.stringify(input));
require('fs').mkdirSync(require('path').join(d0, '.step-harness'));
require('fs').writeFileSync(require('path').join(d0, '.step-harness', 'config.json'), JSON.stringify({ explore_tools: ['run_subagent'], passive_tools: ['mcp__docs__search'] }));
assert.strictEqual(L.needsPlan(d0, 'run_subagent', {}), false); assert.strictEqual(L.needsPlan(d0, 'mcp__docs__search', {}), false); assert.strictEqual(L.needsPlan(d0, 'mcp__docs__write', {}), true);
N
then ok "허용 명령 형태 · 읽기 전용 셸 판별 (줄바꿈·heredoc 으로 명령 끼워넣기 거부)"; else bad "허용 명령 형태 · 읽기 전용 셸 판별"; fi
if node - "$HERE" <<'N'
const L = require(process.argv[2] + '/scripts/lib.cjs'), F = require(process.argv[2] + '/scripts/flow.cjs');
const assert = require('assert'), cp = require('child_process'), fs = require('fs'), os = require('os'), path = require('path');
// 프롬프트에서 뽑은 값이 판정 명령에 들어갈 때: 따옴표 안에 두었든 밖에 두었든 한 개의 글자 그대로의 인자가 된다
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
then ok "따옴표 처리 · exec_allow · 락"; else bad "따옴표 처리 · exec_allow · 락"; fi

pws() {   # 프로그램 흐름 작업 폴더: 등록부(게이트·스킬·서브에이전트·쓰기 범위). "계획 먼저"는 기본값 그대로(켜짐)
  ws
  cat > .step-harness/config.json <<'J'
{ "wait": {"prompt":4,"post":4,"stop":4}, "check_wait_sec": 20,
  "gates": { "cc": { "cmd": "bash gate.sh", "about": "code complete gate" } },
  "skills": { "eats-write-unit-test": "writes unit tests" }, "agents": { "fixer": "fixer" },
  "writable": ["lib/**", "test/**"] }
J
  node -e 'const fs=require("fs");const f=".step-harness/router.json";const r=JSON.parse(fs.readFileSync(f,"utf8"));
    r.routes.push({name:"prog",when:"^프로그램: (.+)",program:{task:"$1"}});fs.writeFileSync(f,JSON.stringify(r));'
}
setcfg() { node -e 'const fs=require("fs");const p=".step-harness/config.json";const c=JSON.parse(fs.readFileSync(p,"utf8"));eval(process.argv[1]);fs.writeFileSync(p,JSON.stringify(c))' "$1"; }
addroute() { node -e 'const fs=require("fs");const f=".step-harness/router.json";const r=JSON.parse(fs.readFileSync(f,"utf8"));r.routes.push(JSON.parse(process.argv[1]));fs.writeFileSync(f,JSON.stringify(r))' "$1"; }
execdoc() { node -e 'const c=process.argv[1],p=process.argv[2];console.log(JSON.stringify({command:`node "${c}" execute <<'"'"'EOF'"'"'\n${p}\nEOF`}))' "$CLI" "$1"; }
edit_in() { hook "$(pre s1 p1 edit "$EDIT_IN")" >/dev/null; hook "$(post s1 p1 edit "$EDIT_IN")" >/dev/null; }   # 범위 안의 수정 한 번 (허용 확인 + 결과 기록)
PROG='async (h) => {
  for (const attempt of h.retries(3)) {
    const r = await h.check("cc");
    if (r.pass) return h.done("code complete");
    if (r.route === "unit-test") await h.skill("eats-write-unit-test", r.report, { scope: ["lib/**", "test/**"] });
    else await h.work(`Fix ${r.report}`, { scope: ["lib/**"] });
  }
  return h.handoff("3회 시도 후에도 실패");
}'
WPROG='async (h) => { await h.work("make it pass", { scope: ["lib/**"] }); return h.done("claimed"); }'
SKP='{"skill":"eats-write-unit-test","args":".step-harness/reports/cc.txt"}'

echo "[Y] 계획 먼저: 읽기는 자유, 바꾸려면 프로그램부터"
pws; out=$(node "$CLI" search); has "search: 타입 선언에 등록 이름이 리터럴로" "$out" 'check(gate: "cc"): Promise<Verdict>'
has "search: 직접 작업 걸음" "$out" 'work(task: string'; has "search: 쓰기 범위 타입" "$out" '("lib/**" | "test/**")[]'; hasnt "search: 게이트 명령은 노출 안 함" "$out" 'bash gate.sh'
out=$(node "$CLI" search unit); has "search 필터" "$out" 'eats-write-unit-test'; hasnt "search 필터 제외" "$out" 'agent fixer'

pws; out=$(hook "$(ups s1 p1 'lib 에 버튼을 추가해줘')"); has "보통의 프롬프트: 계획 먼저라는 것만 알림" "$out" 'plan-first'; has "계획 명령 안내" "$out" 'harness.cjs\" plan'
is "프롬프트만으로는 흐름을 시작하지 않음" "$([ -f .step-harness/state.json ] && echo y || echo n)" n
expect "계획 전: 읽기 허용" 0 "$(pre s1 p1 read '{"file_path":"lib/a.dart"}')"
expect "계획 전: 읽기만 하는 셸 허용" 0 "$(pre s1 p1 exec '{"command":"git status"}')"
expect "계획 전: 사용자에게 질문 허용" 0 "$(pre s1 p1 ask_user_question '{}')"
is "읽기만으로는 흐름을 시작하지 않음" "$([ -f .step-harness/state.json ] && echo y || echo n)" n
out=$(hook "$(pre s1 p1 exec '{"command":"npm test"}')"); has "계획 전: 무언가를 바꾸는 셸 차단 + 이유" "$out" 'nothing may be changed before a plan is accepted'
has "차단 메시지에 과제(= 사용자의 프롬프트)" "$out" 'TASK: lib 에 버튼을 추가해줘'; has "차단 메시지에 계획 API" "$out" 'declare const h'; has "제출 방법 안내" "$out" "execute <<'EOF'"
is "바꾸려는 첫 호출에서 계획 단계 시작" "$(st s.action)" program; is "그렇게 시작된 흐름 표시" "$(st s.lazy)" true
expect "계획 전: 수정 차단" 2 "$(pre s1 p1 edit "$EDIT_IN")"
expect "계획 전: 스킬 차단" 2 "$(pre s1 p1 skill "$SKP")"; expect "계획 전: 서브에이전트 차단" 2 "$(pre s1 p1 run_subagent '{"profile":"fixer","task":"x"}')"
expect "계획 전: MCP 도구(무엇을 바꾸는지 알 수 없다) 차단" 2 "$(pre s1 p1 mcp__filesystem__write_file '{"path":"lib/a.dart","content":"x"}')"; expect "계획 전: 모르는 도구 차단" 2 "$(pre s1 p1 some_new_tool '{}')"
out=$(hook "$(stopev s1 p1)"); hasnt "프로그램을 내지 않고 멈추는 것은 막지 않음 (바뀐 것이 없다)" "$out" '"decision":"block"'
is "시작만 해 둔 계획 단계는 접는다" "$(st s.status)" stopped
out=$(hook "$(ups s1 p2 '그러면 이 함수가 뭐 하는 건지만 알려줘')"); has "다음 프롬프트는 다시 처음부터" "$out" 'plan-first'
expect "접힌 뒤에도 수정은 다시 차단" 2 "$(pre s1 p2 edit "$EDIT_IN")"; has "새 과제는 새 프롬프트" "$(node "$CLI" next)" 'TASK: 그러면 이 함수가'

pws; hook "$(ups s1 p1 '버튼 추가')" >/dev/null
expect "plan 명령은 hook 을 통과" 0 "$(pre s1 p1 exec "$(chk plan)")"; out=$(node "$CLI" plan)
has "plan: 계획 단계를 시작하고 API 를 보여줌" "$out" 'PLAN FIRST'; has "plan: 과제" "$out" 'TASK: 버튼 추가'; is "plan 으로 시작" "$(st s.action)" program
out=$(node "$CLI" plan); has "plan 을 또 불러도 같은 안내" "$out" 'PLAN FIRST'; is "흐름은 하나" "$(st s.seq)" 1
expect "프로그램 제출 명령은 hook 을 통과" 0 "$(pre s1 p1 exec "$(execdoc "$WPROG")")"
expect "heredoc 뒤에 명령을 붙이면 차단" 2 "$(pre s1 p1 exec "$(execdoc "$WPROG
EOF
touch pwned")")"
expect "MCP execute 도구 허용" 0 "$(pre s1 p1 mcp__step-harness__execute '{"code":"x"}')"; expect "MCP plan 도구 허용" 0 "$(pre s1 p1 mcp__step-harness__plan '{}')"

pws; setcfg 'c.plan="prefix"'; out=$(hook "$(ups s1 p1 '버튼 추가')"); hasnt "plan=prefix: 보통의 프롬프트에는 관여 안 함" "$out" 'plan-first'
expect "plan=prefix: 계획 없이도 수정 허용" 0 "$(pre s1 p1 edit "$EDIT_IN")"
pws; hook "$(ups s1 p1 '따옴표로 감싼 옵션')" >/dev/null
expect "계획 전: 따옴표로 감싼 -exec 도 차단" 2 "$(pre s1 p1 exec '{"command":"find . \"-exec\" touch X {} +"}')"
pws; hook "$(ups s1 p1 'MCP 로 쓰기')" >/dev/null
expect "계획 전: MCP 쓰기 도구가 첫 호출이어도 차단" 2 "$(pre s1 p1 mcp__filesystem__write_file '{"path":"lib/a.dart","content":"x"}')"; is "그 호출로 계획 단계가 시작됨" "$(st s.action)" program
pws; setcfg 'c.passive_tools=["mcp__docs__search"]'; hook "$(ups s1 p1 '문서 찾기')" >/dev/null
expect "passive_tools 에 넣은 읽기 도구는 계획 없이 허용" 0 "$(pre s1 p1 mcp__docs__search '{"q":"x"}')"
pws; setcfg 'c.explore_tools=["run_subagent"]'; hook "$(ups s1 p1 '조사')" >/dev/null
expect "explore_tools 에 넣은 도구는 계획 없이 허용" 0 "$(pre s1 p1 run_subagent '{"profile":"explore","task":"x"}')"; expect "나머지는 그대로 차단" 2 "$(pre s1 p1 edit "$EDIT_IN")"

# 규칙으로 명시해서 시작한 흐름("프로그램: …"): 프롬프트에서 바로 계획 단계. 프로그램을 내기 전에는 멈출 수 없다
pws; out=$(hook "$(ups s1 p1 '프로그램: 코드 컴플리트 통과시키기')"); has "규칙 → 계획 단계" "$out" 'TASK: 코드 컴플리트 통과시키기'
has "프롬프트 = 타입 있는 API" "$out" 'declare const h'; has "제출 형식 안내" "$out" "execute <<'EOF'"
expect "계획 단계: 직접 수정 차단" 2 "$(pre s1 p1 edit "$EDIT_IN")"; expect "계획 단계: 임의 명령 차단" 2 "$(pre s1 p1 exec '{"command":"bash gate.sh"}')"
expect "계획 단계: 읽기 허용" 0 "$(pre s1 p1 read '{"file_path":"lib/a.dart"}')"; expect "계획 단계: search 허용" 0 "$(pre s1 p1 exec "$(chk search)")"
expect "다른 MCP 도구는 차단" 2 "$(pre s1 p1 mcp__other__run '{}')"
out=$(hook "$(stopev s1 p1)"); has "명시해서 시작한 흐름은 프로그램 없이 멈출 수 없음" "$out" '"decision":"block"'
out=$(node "$CLI" execute 'async (h) => { const r = await h.check("cc"); }'); is "거부 → exit 1" "$?" 1
has "거부 사유 출력" "$out" 'every path must end'; is "거부 횟수 기록" "$(st s.rejects)" 1
out=$(node "$CLI" next); has "다음 안내에 거부 사유" "$out" 'Your last program was REJECTED (1/3)'
for i in 1 2 3; do node "$CLI" execute 'async (h) => { while (1) {} }' >/dev/null; done
is "거부가 한도를 넘으면 handoff" "$(st s.status)" handoff

echo "[Z] 프로그램을 한 걸음씩: 게이트는 하네스가, 작업·스킬은 그 세션이 지시된 대로만"
pws; hook "$(ups s1 p1 '프로그램: 코드 컴플리트 통과시키기')" >/dev/null
out=$(node "$CLI" execute "$PROG"); is "execute → 받아들임 exit 0" "$?" 0; has "받아들임" "$out" 'ACCEPTED'
has "첫 걸음(게이트)은 하네스가 직접 돌림" "$out" 'FAILED: check:cc (route=unit-test)'
has "다음 걸음 = 스킬 호출" "$out" 'step 2: skill:eats-write-unit-test'; has "스킬 호출 지시" "$out" 'tool: skill'
has "게이트 리포트 경로가 스킬 인자로" "$out" '"args":".step-harness/reports/cc.txt"'
expect "스킬 걸음: 직접 수정 차단" 2 "$(pre s1 p1 edit "$EDIT_IN")"; expect "스킬 걸음: 다른 스킬 차단" 2 "$(pre s1 p1 skill '{"skill":"other","args":"x"}')"
out=$(node "$CLI" check); has "스킬을 부르지 않고 끝났다고 하면 거부" "$out" 'NOT DONE — the NEXT_ACTION below has not been called yet'
out=$(node "$CLI" execute "$WPROG"); has "진행 중에 다른 프로그램을 내면 거부" "$out" 'already been accepted'
expect "스킬 걸음: 지시된 호출 허용" 0 "$(pre s1 p1 skill "$SKP")"
echo other > .route; out=$(hook "$(post s1 p1 skill "$SKP")")
has "스킬이 끝나면 게이트 재실행 → 다른 실패 종류 → 작업 걸음" "$out" 'step 4: work'; has "작업 지시문은 프로그램이 쓴 그대로" "$out" 'Fix .step-harness/reports/cc.txt'
has "왜 다시 하는지 한 줄" "$out" 'The last verification FAILED (check:cc, route=other)'
expect "작업 걸음: 범위 안 수정 허용" 0 "$(pre s1 p1 edit "$EDIT_IN")"; expect "작업 걸음: 범위 밖 수정 차단" 2 "$(pre s1 p1 edit "$EDIT_OUT")"
expect "작업 걸음: 계획에 없는 스킬 호출 차단" 2 "$(pre s1 p1 skill "$SKP")"; expect "작업 걸음: 셸 허용" 0 "$(pre s1 p1 exec '{"command":"dart format lib"}')"
expect "작업 걸음: 하네스 상태 파일은 셸로도 못 고침" 2 "$(pre s1 p1 exec '{"command":"echo {} > .step-harness/state.json"}')"
out=$(node "$CLI" check); has "아무것도 바꾸지 않고 끝났다고 하면 거부" "$out" 'NOT DONE — nothing has been changed yet'
hook "$(post s1 p1 edit "$EDIT_IN")" >/dev/null; touch .gate_ok
out=$(node "$CLI" check); has "작업 끝 → 게이트 통과 → 완료 (메시지는 프로그램이 정함)" "$out" 'DONE: code complete'
has "걸음별 기록: 작업" "$out" 'PASSED: work'; has "걸음별 기록: 게이트" "$out" 'PASSED: check:cc'
is "상태 done" "$(st s.status)" done; is "기록된 걸음 수" "$(st s.trace.length)" 5; is "게이트 실행 횟수" "$(cat .gate_runs)" 3
expect "끝난 뒤에는 다시 계획부터" 2 "$(pre s1 p1 edit "$EDIT_IN")"

# 멈추려 하면 hook 이 걸음을 마무리하고 다음 걸음을 준다 (check 를 부르지 않아도 진행된다)
pws; hook "$(ups s1 p1 '프로그램: 멈춤으로 진행')" >/dev/null; node "$CLI" execute "$WPROG" >/dev/null; edit_in
out=$(hook "$(stopev s1 p1)"); has "작업 뒤에 멈추면: 걸음을 끝내고 완료를 전하게 함" "$out" 'DONE: claimed'; is "완료" "$(st s.status)" done
pws; hook "$(ups s1 p1 '프로그램: 안 하고 멈춤')" >/dev/null; node "$CLI" execute "$WPROG" >/dev/null
out=$(hook "$(stopev s1 p1)"); has "아무것도 안 하고 멈추면 차단" "$out" 'You cannot stop yet'; has "할 일을 다시 알려줌" "$out" 'make it pass'

# 서브에이전트 걸음
pws; hook "$(ups s1 p1 '프로그램: 위임')" >/dev/null
out=$(node "$CLI" execute 'async (h) => { const r = await h.agent("fixer", "Fix the login screen", { scope: ["lib/**"] }); if (r.ok) return h.done("fixed"); return h.handoff("subagent failed"); }')
has "서브에이전트 걸음 지시" "$out" 'tool: run_subagent'; has "다른 호스트의 도구 이름도 함께" "$out" 'Agent'; has "넘길 값" "$out" '"task":"Fix the login screen"'
expect "지시와 다른 과제로 부르면 차단" 2 "$(pre s1 p1 run_subagent '{"profile":"fixer","task":"do something else"}')"
AG='{"subagent_type":"fixer","prompt":"Fix the login screen","description":"fix"}'
expect "파라미터 이름이 달라도 값이 같으면 허용 (호스트마다 이름이 다르다)" 0 "$(pre s1 p1 run_subagent "$AG")"
out=$(hook "$(post s1 p1 run_subagent "$AG" '{"success":false,"output":"","error":"boom"}')"); has "호출이 실패하면 프로그램이 r.ok=false 를 받는다" "$out" 'PAUSED'
is "프로그램이 정한 사유" "$(st s.handoff.reason)" 'subagent failed'

# 완료 조건(done_when): h.done() 은 주장일 뿐이고, 정해 둔 게이트는 하네스가 직접 돌린다
dws() { pws; addroute '{"name":"strict","when":"^완료조건: (.+)","program":{"task":"$1","done_when":["cc"]}}'; }
dws; hook "$(ups s1 p1 '완료조건: 통과시키기')" >/dev/null; has "완료 조건이 API 설명에" "$(node "$CLI" next)" 'accepted only if "cc" passes'
node "$CLI" execute "$WPROG" >/dev/null; edit_in
out=$(node "$CLI" check); has "h.done() 뒤에 하네스가 게이트를 직접 돌림 → 실패" "$out" 'FAILED: check:cc (required to finish)'
has "완료 거부 → 새 프로그램 요구" "$out" 'returned h.done(), but the required check "cc" FAILED'; is "계획 단계로 돌아감" "$(st s.action)" program; is "시도 횟수 +1" "$(st s.visits.program)" 2
expect "돌아간 계획 단계에서도 직접 수정은 차단" 2 "$(pre s1 p1 edit "$EDIT_IN")"
out=$(hook "$(stopev s1 p1)"); has "완료가 거부된 뒤에는 멈출 수 없음" "$out" 'You cannot stop yet'
touch .gate_ok; node "$CLI" execute "$WPROG" >/dev/null; edit_in
out=$(node "$CLI" check); has "게이트가 통과하면 완료" "$out" 'DONE: claimed'
dws; hook "$(ups s1 p1 '완료조건: 끝내 실패')" >/dev/null
for i in 1 2 3; do node "$CLI" execute "$WPROG" >/dev/null; edit_in; node "$CLI" check >/dev/null; done
is "완료 조건을 3번 못 넘기면 handoff" "$(st s.status)" handoff; has "사유에 게이트 이름" "$(st s.handoff.reason)" '게이트 "cc" 가 통과하지 못함'
dws; touch .gate_ok; hook "$(ups s1 p1 '완료조건: 이미 확인')" >/dev/null
node "$CLI" execute 'async (h) => { await h.work("x", { scope: ["lib/**"] }); const r = await h.check("cc"); if (r.pass) return h.done("ok"); return h.handoff("no"); }' >/dev/null; edit_in
out=$(node "$CLI" check); has "마지막 작업 뒤에 프로그램이 통과를 확인한 게이트는 다시 돌리지 않음" "$out" 'DONE: ok'; is "게이트는 한 번만 실행" "$(cat .gate_runs)" 1
dws; touch .gate_ok; hook "$(ups s1 p1 '완료조건: 확인 뒤에 또 고침')" >/dev/null
node "$CLI" execute 'async (h) => { const r = await h.check("cc"); await h.work("x", { scope: ["lib/**"] }); return h.done("ok"); }' >/dev/null; edit_in
out=$(node "$CLI" check); has "게이트 통과 뒤에 또 고쳤으면 다시 돌린다" "$out" 'PASSED: check:cc (required to finish)'; is "게이트 두 번 실행" "$(cat .gate_runs)" 2
pws; addroute '{"name":"bad","when":"^없는게이트","program":{"task":"x","done_when":["nope"]}}'
out=$(hook "$(ups s1 p1 '없는게이트')"); has "등록되지 않은 완료 조건이면 시작하지 않음" "$out" 'done_when names a gate that is not registered'
dws; hook "$(ups s1 p1 '완료조건: 설정이 바뀜')" >/dev/null; node "$CLI" execute "$WPROG" >/dev/null; setcfg 'delete c.gates.cc; c.gates.other="true"'; edit_in
node "$CLI" check >/dev/null; is "실행 중에 게이트가 설정에서 사라지면 통과로 치지 않고 handoff" "$(st s.status)" handoff; has "사유" "$(st s.handoff.reason)" '없음 (실행 중에 설정이 바뀜)'

# 프로그램이 스스로 사람에게 넘긴 경우: retry = 새 프로그램 / proceed = 사람이 끝난 것으로 인정
HPROG='async (h) => { const r = await h.check("cc"); if (r.pass) return h.done("ok"); return h.handoff("게이트가 실패해서 사람에게"); }'
pws; hook "$(ups s1 p1 '프로그램: 넘기기')" >/dev/null; out=$(node "$CLI" execute "$HPROG")
has "프로그램이 넘기면 PAUSED" "$out" 'PAUSED'; is "사유 = 프로그램 메시지" "$(st s.handoff.reason)" '게이트가 실패해서 사람에게'
expect "넘긴 그 턴에는 수정 불가" 2 "$(pre s1 p1 edit "$EDIT_IN")"
out=$(hook "$(ups s1 p2 'retry')"); has "retry → 새 프로그램을 받는다" "$out" 'PLAN FIRST'; is "계획 단계" "$(st s.action)" program
pws; hook "$(ups s1 p1 '프로그램: 넘기기')" >/dev/null; node "$CLI" execute "$HPROG" >/dev/null
hook "$(ups s1 p2 'proceed')" >/dev/null; is "proceed → 사람이 끝난 것으로 인정" "$(st s.status)" done
# 걸음 도중에 막힌 경우: retry = 그 걸음을 다시 / proceed = 그 걸음을 통과로 치고 계속
pws; hook "$(ups s1 p1 '프로그램: 막힘')" >/dev/null; node "$CLI" execute "$WPROG" >/dev/null
for i in 1 2 3 4 5 6; do hook "$(pre s1 p1 edit "$EDIT_OUT")" >/dev/null; done
is "막힌 호출만 반복하면 handoff" "$(st s.status)" handoff; is "넘어온 곳 = 그 걸음" "$(st s.handoff.from)" step1
out=$(hook "$(ups s1 p2 'retry')"); has "retry → 그 걸음을 다시" "$out" 'make it pass'; is "같은 걸음" "$(st s.action)" step1
pws; hook "$(ups s1 p1 '프로그램: 막힘')" >/dev/null; node "$CLI" execute "$WPROG" >/dev/null
for i in 1 2 3 4 5 6; do hook "$(pre s1 p1 edit "$EDIT_OUT")" >/dev/null; done
hook "$(ups s1 p2 'proceed')" >/dev/null; is "proceed → 그 걸음을 통과로 치고 프로그램을 이어감" "$(st s.status)" done
# 걸음 수 한도: 끝나지 않는 프로그램은 한도에서 멈추고 사람에게 넘어간다. retry 는 (이미 끝난 걸음을 다시 하는 것이 아니라) 새 프로그램을 받는다
pws; hook "$(ups s1 p1 '프로그램: 끝나지 않음')" >/dev/null
node "$CLI" execute 'async (h) => { for (const i of h.retries(10)) { for (const j of h.retries(10)) { const r = await h.check("cc"); if (r.pass) return h.done("ok"); } } return h.handoff("never"); }' >/dev/null
for _ in $(seq 1 20); do [ "$(st s.status)" = handoff ] && break; node "$CLI" check --wait 5 >/dev/null; done
is "걸음 수 한도에서 handoff" "$(st s.status)" handoff; has "사유는 한도 초과" "$(st s.handoff.reason)" 'max_steps(40)'; is "넘어온 곳 = 계획 단계" "$(st s.handoff.from)" program
out=$(hook "$(ups s1 p2 'retry')"); has "한도 초과 뒤의 retry → 새 프로그램을 받는다" "$out" 'PLAN FIRST'; is "기록은 비워진다" "$(st s.trace.length)" 0
# 걸음 도중 proceed 한 뒤에도 기록과 프로그램이 어긋나지 않는다 (그 걸음의 결과가 기록되고, 그다음 걸음들이 이어진다)
pws; hook "$(ups s1 p1 '프로그램: proceed 뒤에 이어감')" >/dev/null
node "$CLI" execute 'async (h) => { await h.work("first", { scope: ["lib/**"] }); await h.work("second", { scope: ["lib/**"] }); return h.done("both"); }' >/dev/null
for i in 1 2 3 4 5 6; do hook "$(pre s1 p1 edit "$EDIT_OUT")" >/dev/null; done
out=$(hook "$(ups s1 p2 'proceed')"); has "proceed 뒤에는 그다음 걸음" "$out" 'step 2: work'; has "두 번째 걸음의 지시" "$out" 'second'; is "첫 걸음이 기록됨" "$(st s.trace.length)" 1
hook "$(pre s1 p2 edit "$EDIT_IN")" >/dev/null; hook "$(post s1 p2 edit "$EDIT_IN")" >/dev/null; out=$(node "$CLI" check); has "이어서 끝까지" "$out" 'DONE: both'
pws; hook "$(ups s1 p1 '프로그램: 사람이 멈춤')" >/dev/null; node "$CLI" execute "$WPROG" >/dev/null
hook "$(ups s1 p2 'harness stop')" >/dev/null; is "사람이 멈추면 stopped" "$(st s.status)" stopped
pws; node "$CLI" start cc.flow.json gate='bash gate.sh' >/dev/null
out=$(node "$CLI" execute "$WPROG"); has "다른 흐름이 진행 중이면 프로그램 거부" "$out" 'another flow is active'

# 작업 걸음의 설정: 셸을 막거나 허용 목록으로 좁힌다
pws; setcfg 'c.work_shell=false'; hook "$(ups s1 p1 '프로그램: 셸 없이')" >/dev/null; out=$(node "$CLI" execute "$WPROG")
has "work_shell=false: 안내문에 반영" "$out" 'shell commands are not allowed in this step'; expect "work_shell=false: 셸 차단" 2 "$(pre s1 p1 exec '{"command":"dart format lib"}')"
expect "work_shell=false: 수정은 허용" 0 "$(pre s1 p1 edit "$EDIT_IN")"
pws; hook "$(ups s1 p1 '프로그램: MCP 도구')" >/dev/null; node "$CLI" execute "$WPROG" >/dev/null
expect "작업 걸음: MCP 도구 허용 (계획 아래에서 하는 일)" 0 "$(pre s1 p1 mcp__jira__create_issue '{"title":"x"}')"
expect "작업 걸음: MCP 도구라도 범위 밖 경로는 차단" 2 "$(pre s1 p1 mcp__filesystem__write_file '{"path":"README.md","content":"x"}')"
expect "작업 걸음: MCP 도구의 범위 안 경로는 허용" 0 "$(pre s1 p1 mcp__filesystem__write_file '{"path":"lib/a.dart","content":"x"}')"
pws; setcfg 'c.work_mcp=false'; hook "$(ups s1 p1 '프로그램: MCP 없이')" >/dev/null; node "$CLI" execute "$WPROG" >/dev/null
expect "work_mcp=false: 작업 걸음에서 MCP 도구 차단" 2 "$(pre s1 p1 mcp__jira__create_issue '{"title":"x"}')"
pws; setcfg 'c.exec_allow=["dart format"]'; hook "$(ups s1 p1 '프로그램: 허용 목록')" >/dev/null; node "$CLI" execute "$WPROG" >/dev/null
expect "exec_allow: 목록에 있는 명령 허용" 0 "$(pre s1 p1 exec '{"command":"dart format lib"}')"; expect "exec_allow: 그 밖의 명령 차단" 2 "$(pre s1 p1 exec '{"command":"rm -rf lib"}')"

echo "[G] 작업 걸음 뒤의 범위 검사: 셸로 바꾼 범위 밖 파일은 걸음이 끝날 때 git 비교로 잡는다"
GC='git -c user.email=t@t -c user.name=t'
gws() {
  pws; printf '.gate*\n.route\n' > .gitignore; echo base > README.md; echo x > lib/keep.txt
  git init -q . && $GC add -A >/dev/null 2>&1 && $GC commit -qm init >/dev/null 2>&1
  echo mine > notes.txt   # 걸음 전부터 있던 사용자의 미커밋 파일
}
# 작업 걸음 하나짜리 프로그램을 시작하고, 그 걸음 동안 "$1" 을 셸에서 실행한 뒤 걸음을 끝낸다 (hook 은 셸 명령이 무엇을 바꾸는지 보지 못한다)
gstep() {
  hook "$(ups s1 p1 '프로그램: 범위 검사')" >/dev/null; node "$CLI" execute "$WPROG" >/dev/null
  hook "$(pre s1 p1 exec '{"command":"make gen"}')" >/dev/null; ( eval "$1" ) >/dev/null 2>&1; hook "$(post s1 p1 exec '{"command":"make gen"}')" >/dev/null
  OUT=$(node "$CLI" check)
}
gws; gstep 'echo hacked >> README.md; echo fixed >> lib/keep.txt'
is "범위 밖 변경 → handoff" "$(st s.status)" handoff; has "사유에 바뀐 파일" "$(st s.handoff.reason)" 'README.md'
hasnt "걸음 전부터 있던 변경은 문제 삼지 않음" "$(st s.handoff.reason)" 'notes.txt'; hasnt "범위 안 변경은 문제 삼지 않음" "$(st s.handoff.reason)" 'keep.txt'
has "판정 기록" "$OUT" 'FAILED: work (route=out-of-scope)'; is "넘어온 곳 = 그 걸음" "$(st s.handoff.from)" step1
out=$(hook "$(ups s1 p2 'retry')"); has "retry → 그 걸음을 다시 (지금 상태가 새 기준)" "$out" 'make it pass'
hook "$(pre s1 p2 exec '{"command":"make gen"}')" >/dev/null; echo more >> lib/keep.txt; hook "$(post s1 p2 exec '{"command":"make gen"}')" >/dev/null
out=$(node "$CLI" check); has "다시 한 걸음에서 범위 안만 바꾸면 완료" "$out" 'DONE: claimed'
gws; gstep 'echo hacked >> README.md'; hook "$(ups s1 p2 'proceed')" >/dev/null; is "proceed → 사람이 받아들이고 계속" "$(st s.status)" done
gws; gstep 'echo fixed >> lib/keep.txt'; has "범위 안에서만 바꾸면 완료 (하네스 자신의 파일은 검사 대상 아님)" "$OUT" 'DONE: claimed'
gws; setcfg 'c.scope_check=false'; $GC commit -qam cfg >/dev/null 2>&1; gstep 'echo hacked >> README.md'; has "scope_check=false 면 검사하지 않음" "$OUT" 'DONE: claimed'
pws; gstep 'echo hacked >> README.md'; has "git 저장소가 아니면 검사할 수 없다 (문서에 적은 한계)" "$OUT" 'DONE: claimed'
# 커밋까지 해도(그러면 git status 에서는 사라진다) 잡는다. 범위 안의 커밋, 전부터 있던 변경을 같이 커밋한 것은 문제 삼지 않는다
gws; gstep "echo hacked >> README.md; echo fixed >> lib/keep.txt; $GC commit -qam step"
is "범위 밖 파일을 고치고 커밋해도 handoff" "$(st s.status)" handoff; has "사유에 커밋된 파일" "$(st s.handoff.reason)" 'README.md'; hasnt "범위 안 파일은 문제 삼지 않음" "$(st s.handoff.reason)" 'keep.txt'
gws; gstep "echo new > extra.txt; echo fixed >> lib/keep.txt; git add -A; $GC commit -qm step"
is "범위 밖에 새 파일을 만들고 커밋해도 handoff" "$(st s.status)" handoff; has "사유에 새 파일" "$(st s.handoff.reason)" 'extra.txt'; hasnt "전부터 있던 미커밋 파일은 같이 커밋돼도 문제 삼지 않음" "$(st s.handoff.reason)" 'notes.txt'
gws; echo dirty >> README.md; gstep "echo fixed >> lib/keep.txt; git add -A; $GC commit -qm step"; has "커밋만으로는 범위 밖 변경이 아님" "$OUT" 'DONE: claimed'
gws; echo dirty >> README.md; gstep 'git checkout -- README.md; echo fixed >> lib/keep.txt'
is "걸음 전의 미커밋 변경을 되돌리면 범위 밖 변경" "$(st s.status)" handoff; has "사유에 되돌린 파일" "$(st s.handoff.reason)" 'README.md'
gws; rm -rf .git; git init -q .; gstep "echo new > extra.txt; echo fixed >> lib/keep.txt; git add -A; $GC commit -qm first"
is "커밋이 없던 저장소에서 첫 커밋을 만든 경우도 handoff" "$(st s.status)" handoff; has "사유에 새 파일" "$(st s.handoff.reason)" 'extra.txt'; hasnt "원래 있던 파일은 문제 삼지 않음" "$(st s.handoff.reason)" 'README.md'
# 크기·수정 시각을 맞춘 변경, git 이 보지 않게 숨긴 변경, 커밋을 다른 내용으로 보이게 한 변경도 잡는다
gws; gstep 'cp -p notes.txt .n_keep; printf "evil\n" > notes.txt; touch -r .n_keep notes.txt; rm .n_keep; echo fixed >> lib/keep.txt'
is "크기·수정 시각을 맞춘 변경도 감지 (ctime)" "$(st s.status)" handoff; has "사유에 그 파일" "$(st s.handoff.reason)" 'notes.txt'
gws; gstep 'echo hacked >> README.md; git update-index --assume-unchanged README.md; echo fixed >> lib/keep.txt'
[ -z "$(git status --porcelain README.md)" ] && ok "(대조) 그렇게 표시하면 보통의 git status 에는 보이지 않는다" || bad "(대조) assume-unchanged 가 먹지 않음 — 이 테스트는 의미가 없다"
is "숨김 표시를 한 범위 밖 변경도 handoff" "$(st s.status)" handoff; has "사유에 숨긴 파일" "$(st s.handoff.reason)" 'README.md'
gws; gstep 'G="git -c user.email=t@t -c user.name=t"; echo hacked >> README.md; o=$(git rev-parse HEAD); git add README.md; $G commit -qm x; n=$(git rev-parse HEAD); git reset -q --soft "$o"; git replace "$o" "$n"; echo fixed >> lib/keep.txt'
[ -z "$(git status --porcelain README.md)" ] && ok "(대조) 커밋을 바꿔치기하면 보통의 git status 에는 보이지 않는다" || bad "(대조) git replace 가 먹지 않음 — 이 테스트는 의미가 없다"
is "커밋 바꿔치기로 숨긴 범위 밖 변경도 handoff" "$(st s.status)" handoff; has "사유에 숨긴 파일" "$(st s.handoff.reason)" 'README.md'
# 무시 목록 파일이 자기 자신까지 무시하게 만들어 숨긴 새 파일도 잡는다. 도구가 만드는 캐시 폴더(통째로 새 폴더)는 문제 삼지 않는다
dgs() { gws; mkdir -p docs; echo a > docs/a.md; git add docs >/dev/null 2>&1; $GC commit -qm docs >/dev/null 2>&1; }
dgs; gstep 'printf "*\n" > docs/.gitignore; echo x > docs/new.md; echo fixed >> lib/keep.txt'
[ -z "$(git status --porcelain docs)" ] && [ -f docs/new.md ] && ok "(대조) 그렇게 하면 보통의 git status 에는 아무것도 보이지 않는다" || bad "(대조) 자기 자신을 무시하는 .gitignore 가 먹지 않음 — 이 테스트는 의미가 없다"
is "자기 자신을 숨기는 .gitignore 로 가린 범위 밖 새 파일 → handoff" "$(st s.status)" handoff; has "사유에 그 무시 목록 파일" "$(st s.handoff.reason)" 'docs/.gitignore'
dgs; gstep 'echo planted.sh >> .gitignore; echo x > planted.sh; echo fixed >> lib/keep.txt'
is "원래 있던 .gitignore 에 줄을 더해 숨겨도 handoff" "$(st s.status)" handoff; has "사유에 고친 무시 목록 파일" "$(st s.handoff.reason)" '.gitignore'
dgs; gstep 'mkdir -p .tool_cache; printf "*\n" > .tool_cache/.gitignore; echo x > .tool_cache/data; echo fixed >> lib/keep.txt'; has "도구가 새로 만든 캐시 폴더(전부 무시)는 문제 삼지 않음" "$OUT" 'DONE: claimed'
dgs; gstep 'printf "*.tmp\n" > lib/.gitignore; echo x > lib/a.tmp; echo fixed >> lib/keep.txt'; has "범위 안에 만든 .gitignore 는 범위 안 변경" "$OUT" 'DONE: claimed'
# git 이 답하지 못하게 만들면(색인 손상) 검사를 건너뛰지 않고 멈춘다
gws; gstep 'echo hacked >> README.md; printf junk > .git/index; echo fixed >> lib/keep.txt'
is "걸음 뒤에 git 이 답하지 못하면 handoff" "$(st s.status)" handoff; has "사유는 확인할 수 없다는 것" "$(st s.handoff.reason)" 'git 으로 변경을 확인할 수 없음'
# 안에 따로 있는 git 저장소(하위 모듈 등)는 폴더 한 덩어리로 본다
nws() { gws; mkdir -p "${1:-vendor}"; (cd "${1:-vendor}" && git init -q . && echo 1 > f && git add f && $GC commit -qm n) >/dev/null 2>&1
  git add -A >/dev/null 2>&1; $GC commit -qm with-nested >/dev/null 2>&1; }
nws; gstep 'echo 2 >> vendor/f; echo fixed >> lib/keep.txt'; is "안에 있는 저장소의 범위 밖 변경 → handoff" "$(st s.status)" handoff; has "사유에 그 폴더" "$(st s.handoff.reason)" 'vendor'
nws; echo mine >> vendor/f; gstep 'echo x > vendor/other; echo fixed >> lib/keep.txt'; is "이미 고쳐져 있던 저장소 안을 또 고쳐도 handoff" "$(st s.status)" handoff
nws; echo mine >> vendor/f; gstep 'echo fixed >> lib/keep.txt'; has "안에 있는 저장소가 이미 고쳐져 있어도 건드리지 않았으면 완료" "$OUT" 'DONE: claimed'
nws lib/sub; gstep 'echo 2 >> lib/sub/f'; has "범위 안에 있는 저장소를 고친 것은 범위 안" "$OUT" 'DONE: claimed'
# 하네스가 직접 돌리는 git 은 설정에 적힌 명령(fsmonitor)과 PATH 에 심은 git 을 실행하지 않는다
gws; FH="$(mktemp -d)"; printf '#!/bin/sh\ntouch "%s/RAN"\n' "$FH" > "$FH/fsm.sh"; chmod +x "$FH/fsm.sh"; git config core.fsmonitor "$FH/fsm.sh"
git status >/dev/null 2>&1; [ -e "$FH/RAN" ] && ok "(대조) 그 설정이면 보통의 git status 는 그 명령을 실행한다" || bad "(대조) fsmonitor 설정이 먹지 않음 — 이 테스트는 의미가 없다"
rm -f "$FH/RAN"; gstep 'echo fixed >> lib/keep.txt'; has "저장소 설정에 fsmonitor 가 있어도 정상 완료" "$OUT" 'DONE: claimed'
[ ! -e "$FH/RAN" ] && ok "하네스의 git 은 설정의 fsmonitor 명령을 실행하지 않음" || bad "하네스의 git 이 fsmonitor 명령을 실행함"
gws; mkdir -p "$FH/bin"; rm -f "$FH/RAN"; printf '#!/bin/sh\ntouch %s/RAN\nexit 0\n' "$FH" > "$FH/bin/git"; chmod +x "$FH/bin/git"
PATH="$FH/bin:$PATH" gstep 'echo hacked >> README.md'
[ ! -e "$FH/RAN" ] && ok "PATH 앞쪽에 심어 둔 가짜 git 은 실행되지 않음" || bad "하네스가 PATH 에 심은 가짜 git 을 실행함"
is "진짜 git 으로 범위 밖 변경을 그대로 잡는다" "$(st s.status)" handoff
# 저장소의 하위 폴더가 프로젝트일 때: 폴더 밖(같은 저장소의 다른 곳)을 바꿔도 잡는다
R="$(mktemp -d)"; mkdir -p "$R/sub/lib" "$R/sub/.step-harness" "$R/other"; W="$R/sub"; cd "$W"; echo '{"wait":{"prompt":4,"post":4,"stop":4}}' > .step-harness/config.json; echo a > lib/a.txt
(cd "$R" && git init -q . && $GC add -A >/dev/null 2>&1 && $GC commit -qm init >/dev/null 2>&1)
gstep 'echo x > ../other/leak.txt; echo y >> lib/a.txt'; is "하위 폴더 프로젝트: 폴더 밖 변경 → handoff" "$(st s.status)" handoff; has "사유에 폴더 밖 경로" "$(st s.handoff.reason)" '../other/leak.txt'

echo "[H2] 다른 호스트의 hook 형식 (Claude Code: 도구 이름·환경변수가 다르고 prompt_id 가 없다)"
chook() { printf '%s' "$1" | env -u DEVIN_PROJECT_DIR CLAUDE_PROJECT_DIR="$W" node "$HOOK" 2>/dev/null; }
cexp() { local code; printf '%s' "$3" | env -u DEVIN_PROJECT_DIR CLAUDE_PROJECT_DIR="$W" node "$HOOK" >/dev/null 2>&1; code=$?; if [ "$code" = "$2" ]; then ok "$1"; else bad "$1 (exit=$code, want $2)"; fi; }
cpre() { printf '{"hook_event_name":"PreToolUse","session_id":"c1","transcript_path":"/x","cwd":"%s","tool_name":"%s","tool_input":%s}' "$W" "$1" "$2"; }
cpost() { printf '{"hook_event_name":"PostToolUse","session_id":"c1","cwd":"%s","tool_name":"%s","tool_input":%s,"tool_response":{"filePath":"x"}}' "$W" "$1" "$2"; }
pws; out=$(chook "{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"c1\",\"cwd\":\"$W\",\"prompt\":\"lib 에 파일 추가\"}"); has "계획 먼저 안내" "$out" 'plan-first'
cexp "Read 허용" 0 "$(cpre Read '{"file_path":"lib/a.dart"}')"; cexp "읽기만 하는 Bash 허용" 0 "$(cpre Bash '{"command":"git log --oneline -3"}')"
cexp "계획 없이 Write 차단" 2 "$(cpre Write '{"file_path":"lib/n.dart","content":"x"}')"; cexp "계획 없이 Agent(서브에이전트) 차단" 2 "$(cpre Agent '{"subagent_type":"general-purpose","prompt":"x"}')"
cexp "Bash 로 프로그램 제출 허용" 0 "$(cpre Bash "$(execdoc "$WPROG")")"; node "$CLI" execute "$WPROG" >/dev/null
CE='{"file_path":"lib/a.dart","old_string":"a","new_string":"b"}'
cexp "작업 걸음: 범위 안 Edit 허용" 0 "$(cpre Edit "$CE")"; cexp "작업 걸음: 범위 밖 Write 차단" 2 "$(cpre Write '{"file_path":"README.md","content":"x"}')"
cexp "작업 걸음: Bash 허용" 0 "$(cpre Bash '{"command":"npm test"}')"; cexp "작업 걸음: check 명령 허용" 0 "$(cpre Bash "$(chk check)")"
chook "$(cpost Edit "$CE")" >/dev/null
out=$(chook "{\"hook_event_name\":\"Stop\",\"session_id\":\"c1\",\"cwd\":\"$W\",\"stop_hook_active\":false}")
has "멈추려 하면 hook 이 걸음을 끝내고 결과를 전하게 함" "$out" 'DONE: claimed'; has "Stop 차단 형식" "$out" '"decision":"block"'
pws; chook "{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"c1\",\"cwd\":\"$W\",\"prompt\":\"위임\"}" >/dev/null
node "$CLI" execute 'async (h) => { await h.agent("fixer", "Fix the login screen", { scope: ["lib/**"] }); return h.done("fixed"); }' >/dev/null
AG='{"subagent_type":"fixer","prompt":"Fix the login screen","description":"fix"}'
cexp "서브에이전트 걸음: Agent 도구로 같은 값을 넘기면 허용" 0 "$(cpre Agent "$AG")"; cexp "그동안 범위 안 수정 허용(서브에이전트의 호출이 같은 세션으로 보인다)" 0 "$(cpre Edit "$CE")"
cexp "범위 밖은 여전히 차단" 2 "$(cpre Write '{"file_path":"README.md","content":"x"}')"
out=$(chook "$(cpost Agent "$AG")"); has "서브에이전트가 끝나면 완료" "$out" 'DONE: fixed'

echo "[W] 플러그인만 설치한 프로젝트 · 규칙 우선순위 · MCP"
W="$(mktemp -d)"; cd "$W"; mkdir -p lib
out=$(hook "$(ups s1 p1 '일반 질문')"); is "상태 폴더 없고 규칙 밖이면 관여 안 함" "$([ -d .step-harness ] && echo y || echo n)" n
expect "상태 폴더가 없는 프로젝트에서는 수정도 막지 않음" 0 "$(pre s1 p1 write '{"file_path":"lib/a.txt"}')"
out=$(hook "$(ups s1 p1 '프로그램: a.txt 만들기')"); has "상태 폴더 없이 기본 규칙으로 시작" "$out" 'TASK: a.txt 만들기'
has "등록된 것이 없으면 직접 작업 걸음만" "$out" 'work(task: string'; hasnt "등록되지 않은 종류는 API 에 없음" "$out" 'skill(name'; hasnt "게이트가 없으면 check 도 없음" "$out" 'check(gate'
out=$(node "$CLI" execute 'async (h) => { await h.work("Create lib/a.txt", { scope: ["lib/**"] }); return h.done("made"); }'); has "게이트 없이 작업 걸음만으로" "$out" 'step 1: work'
expect "쓰기 허용" 0 "$(pre s1 p1 write '{"file_path":"lib/a.txt"}')"; hook "$(post s1 p1 write '{"file_path":"lib/a.txt"}')" >/dev/null
out=$(hook "$(stopev s1 p1)"); has "멈추려 하면 걸음을 끝내고 완료를 알림" "$out" 'DONE: made'
out=$(hook "$(ups s1 p2 '이제 다른 것도 고쳐줘')"); has "한 번 쓰기 시작한 프로젝트는 그 뒤로 계획 먼저" "$out" 'plan-first'
# 프로젝트 규칙과 플러그인 기본 규칙이 둘 다 맞으면 프로젝트 규칙이 이긴다
pws; out=$(hook "$(ups s1 p1 '프로그램: 우선순위')"); hasnt "프로젝트 규칙 우선 (모호 처리 안 함)" "$out" 'more than one flow'

pws; out=$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}' '{"jsonrpc":"2.0","method":"notifications/initialized"}' '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"plan","arguments":{}}}' \
  "$(node -e 'console.log(JSON.stringify({jsonrpc:"2.0",id:4,method:"tools/call",params:{name:"execute",arguments:{code:process.argv[1]}}}))' "$WPROG")" | DEVIN_PROJECT_DIR="$W" node "$HERE/scripts/mcp.cjs")
has "MCP initialize" "$out" '"serverInfo":{"name":"step-harness"'; has "MCP 도구 목록" "$out" '"name":"execute"'; has "MCP plan" "$out" 'PLAN FIRST'
has "MCP execute 로 프로그램 제출" "$out" 'ACCEPTED'; has "MCP 응답에 다음 걸음" "$out" 'make it pass'; is "걸음 진행 중" "$(st s.action)" step1
# MCP 서버: 어느 프로젝트인지 알 수 없으면(플러그인 폴더에서 떴고 환경변수도 없음) 엉뚱한 곳에 쓰지 않고 거부한다
out=$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"search","arguments":{}}}' \
  | (cd "$HERE" && env -u DEVIN_PROJECT_DIR -u CLAUDE_PROJECT_DIR -u STEP_HARNESS_ROOT node scripts/mcp.cjs))
has "MCP: 프로젝트를 모르면 거부" "$out" 'cannot tell which project'; [ ! -e "$HERE/.step-harness" ] && ok "MCP: 플러그인 폴더에 상태를 만들지 않음" || bad "MCP: 플러그인 폴더에 상태가 생김"
D="$(mktemp -d)"; out=$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' "$(node -e 'console.log(JSON.stringify({jsonrpc:"2.0",id:2,method:"tools/call",params:{name:"execute",arguments:{code:process.argv[1]}}}))' "$WPROG")" \
  | (cd "$D" && env -u DEVIN_PROJECT_DIR -u CLAUDE_PROJECT_DIR -u STEP_HARNESS_ROOT node "$HERE/scripts/mcp.cjs"))
has "MCP: 프로젝트로 보이지 않는 폴더(저장소도 상태 폴더도 없음)에서는 실행하지 않음" "$out" 'cannot tell which project'; [ ! -e "$D/.step-harness" ] && ok "MCP: 그 폴더에 상태를 만들지 않음" || bad "MCP: 엉뚱한 폴더에 상태가 생김"
out=$(printf 'null\n[{"jsonrpc":"2.0","id":2,"method":"ping"}]\n{"jsonrpc":"2.0","id":3,"method":"ping"}\n' | node "$HERE/scripts/mcp.cjs"); is "MCP: 잘못된 입력에 죽지 않음" "$?" 0
has "MCP: 잘못된 입력에는 오류 응답" "$out" '"code":-32600'; has "MCP: 그 뒤의 요청은 정상 처리" "$out" '"id":3,"result":{}'
pws; out=$( (printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{"roots":{}}}}' '{"jsonrpc":"2.0","method":"notifications/initialized"}' '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"search","arguments":{}}}'; sleep 0.3
  printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":\"step-harness-roots\",\"result\":{\"roots\":[{\"uri\":\"file://$W\"}]}}") | (cd "$D" && env -u DEVIN_PROJECT_DIR -u CLAUDE_PROJECT_DIR -u STEP_HARNESS_ROOT node "$HERE/scripts/mcp.cjs"))
has "MCP: 작업 폴더 답이 오기 전에 온 도구 호출은 답을 기다렸다가 처리" "$out" 'check(gate: \"cc\")'
pws; out=$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{"roots":{}}}}' '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  "{\"jsonrpc\":\"2.0\",\"id\":\"step-harness-roots\",\"result\":{\"roots\":[{\"uri\":\"file://$W\"}]}}" '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"search","arguments":{}}}' \
  | (cd "$HERE" && env -u DEVIN_PROJECT_DIR -u CLAUDE_PROJECT_DIR -u STEP_HARNESS_ROOT node scripts/mcp.cjs))
has "MCP: 클라이언트에 작업 폴더를 묻는다 (roots/list)" "$out" '"method":"roots/list"'; has "MCP: 알려준 폴더의 등록부를 쓴다" "$out" 'check(gate: \"cc\")'

echo; echo "pass=$pass fail=$fail"
[ "$fail" = 0 ]
