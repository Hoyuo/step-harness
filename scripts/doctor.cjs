'use strict';
// 설치·진단 도구 (사람이 터미널에서 실행)
//   install   — 프로젝트의 .devin/hooks.v1.json 에 절대경로로 hook 등록 (플러그인 변수 치환에 기대지 않는 설치 방법)
//   probe     — 실환경의 hook 입력 형태를 기록하는 모드 on/off
//   doctor    — probe 기록을 분석해 "이 환경에서 서브에이전트 호출이 hook 에 어떻게 보이는지" 등을 알려준다
const fs = require('fs');
const path = require('path');
const L = require('./lib.cjs');

const MARK = 'STEP_HARNESS_HOOK=1';
const EVENTS = { PreToolUse: 10, PostToolUse: 30, UserPromptSubmit: 30, Stop: 55, SessionStart: 10, PermissionRequest: 5 };
// hook 안에서 판정을 기다리는 시간(config.wait)은 반드시 이 타임아웃보다 짧아야 한다.

function hooksObject(command, failClosed) {
  const o = {};
  for (const [ev, timeout] of Object.entries(EVENTS)) {
    const h = { type: 'command', command, timeout };
    if (failClosed && ev === 'PreToolUse') h.fail_closed = true;   // hook 이 실행조차 못 하면 호출을 막는다 (Devin v3000.11.205+)
    o[ev] = [{ matcher: '', hooks: [h] }];
  }
  return o;
}
const hooksFile = (root) => path.join(root, '.devin', 'hooks.v1.json');
function readHooks(root, out) {
  const f = hooksFile(root);
  if (!fs.existsSync(f)) return {};
  try { return JSON.parse(fs.readFileSync(f, 'utf8')); } catch (e) { out(`${f} 를 JSON 으로 읽지 못함 (${e.message}). 직접 고친 뒤 다시 실행.`); process.exit(1); }
}
function strip(hooks) {   // 우리가 넣은 항목 제거
  const o = {};
  for (const [ev, entries] of Object.entries(hooks)) {
    if (!Array.isArray(entries)) { o[ev] = entries; continue; }
    const kept = entries.map((e) => ({ ...e, hooks: (e.hooks || []).filter((h) => !String(h.command || '').includes(MARK)) })).filter((e) => (e.hooks || []).length);
    if (kept.length) o[ev] = kept;
  }
  return o;
}
function install(root, { has, out }) {
  const ours = hooksObject(`${MARK} node "${path.join(L.PLUGIN_DIR, 'scripts', 'hook.cjs')}"`, has('--fail-closed'));
  const merged = strip(readHooks(root, out));
  for (const [ev, entries] of Object.entries(ours)) merged[ev] = [...(merged[ev] || []), ...entries];
  L.writeJson(hooksFile(root), merged);
  fs.mkdirSync(path.join(root, L.DIR), { recursive: true });
  out(`설치됨: ${hooksFile(root)}` + (has('--fail-closed') ? ' (PreToolUse fail_closed)' : ''));
  out(`상태 폴더: ${path.join(root, L.DIR)}  ← 라우팅 규칙은 여기에 router.json 으로 (예시: ${path.join(L.PLUGIN_DIR, 'router.example.json')})`);
  out('주의: 플러그인으로도 설치돼 있다면 hook 이 두 번 돈다. 둘 중 하나만 쓴다.');
}
function uninstall(root, { out }) {
  const f = hooksFile(root);
  if (!fs.existsSync(f)) return out('설치된 hook 이 없다.');
  L.writeJson(f, strip(readHooks(root, out)));
  out(`제거됨: ${f}`);
}
function probe(root, { argv, out }) {
  const flag = L.sp(root, 'probe');
  fs.mkdirSync(path.dirname(flag), { recursive: true });
  if (argv[1] === 'on') {
    fs.writeFileSync(flag, new Date().toISOString());
    out('probe ON. Devin 세션에서 아래를 그대로 입력한 뒤 `harness.cjs doctor` 를 실행:\n');
    out('  Do exactly these two tool calls in order and nothing else. (1) run_subagent with profile "subagent_general" and this task: "Use the write tool to create the file step-harness-probe.txt containing the word ok, then stop." (2) the skill tool for any one installed skill. Then stop.');
  } else if (argv[1] === 'off') {
    try { fs.renameSync(flag, flag + '.off'); } catch { /* 이미 꺼져 있음 */ }
    out('probe OFF');
  } else out('usage: harness.cjs probe on|off');
}

function doctor(root, { has, out }) {
  out(`node ${process.version} · plugin ${L.PLUGIN_DIR} · project ${root}`);
  const hf = hooksFile(root);
  const proj = fs.existsSync(hf) && fs.readFileSync(hf, 'utf8').includes(MARK);
  out(`프로젝트 hook(.devin/hooks.v1.json): ${proj ? '설치됨' : '없음 (플러그인으로 설치했다면 정상)'}`);
  const cfg = L.config(root);
  out(`config: subagent_hooks=${cfg.subagent_hooks} (현재 동작: ${L.subagentMode(root)}) · wait=${JSON.stringify(cfg.wait)} · auto_approve_cli=${cfg.auto_approve_cli}`);

  const pf = L.sp(root, 'probe.jsonl');
  if (!fs.existsSync(pf)) return out('\nprobe 기록 없음 → `harness.cjs probe on` 후 안내된 프롬프트를 Devin 에서 실행.');
  const rows = fs.readFileSync(pf, 'utf8').split('\n').filter(Boolean).map((l) => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean);
  if (!rows.length) return out('\nprobe.jsonl 이 비어 있음 → hook 이 실행되지 않고 있다 (설치 경로 / `/hooks` 확인).');

  const count = {};
  for (const r of rows) count[r.ev] = (count[r.ev] || 0) + 1;
  out(`\n[1] 수신한 이벤트: ${Object.entries(count).map(([k, v]) => `${k}×${v}`).join(' ')}`);
  for (const need of ['PreToolUse', 'PostToolUse', 'UserPromptSubmit', 'Stop']) if (!count[need]) out(`    ⚠ ${need} 이벤트가 한 번도 오지 않음`);

  const env = rows[rows.length - 1].env || {};
  out(`[2] 환경변수: ${Object.entries(env).map(([k, v]) => `${k}=${v ? 'set' : '-'}`).join(' ')}`);
  if (!env.DEVIN_PLUGIN_ROOT && !env.PLUGIN_ROOT && !env.CLAUDE_PLUGIN_ROOT && !proj) out('    ⚠ 플러그인 루트 변수가 없음 → hooks.json 의 경로가 안 풀릴 수 있다. `harness.cjs install` 권장');

  const keys = {};
  for (const r of rows) keys[r.ev] = [...new Set([...(keys[r.ev] || []), ...(r.payload_keys || [])])];
  out('[3] 이벤트별 payload 키:');
  for (const [k, v] of Object.entries(keys)) out(`    ${k}: ${v.join(', ')}`);

  const inputs = {};
  for (const r of rows.filter((x) => x.ev === 'PreToolUse' && x.tool)) inputs[r.tool] = [...new Set([...(inputs[r.tool] || []), ...Object.keys(r.input || {})])];
  out('[4] 도구별 입력 키 (flow 의 params 키는 이것과 같아야 한다):');
  for (const [k, v] of Object.entries(inputs)) out(`    ${k}: ${v.join(', ') || '(없음)'}`);
  const prov = rows.find((r) => r.provenance);
  if (prov) out(`    tool_provenance 예: ${JSON.stringify(prov.provenance)}`);

  // 서브에이전트 호출이 hook 에 어떻게 보이는가
  const ups = rows.find((r) => r.ev === 'UserPromptSubmit');
  const main = ups ? ups.sid : (rows.find((r) => r.sid) || {}).sid;
  const SPAWN = /^(run_subagent|skill|Task|Agent|Skill)$/;
  let windows = 0, sameIn = 0, foreignIn = 0, instant = 0, noPost = 0;
  rows.forEach((r, i) => {
    if (r.ev !== 'PreToolUse' || !SPAWN.test(r.tool || '') || r.sid !== main) return;
    const end = rows.findIndex((x, j) => j > i && x.ev === 'PostToolUse' && x.tool === r.tool && x.sid === r.sid);
    if (end < 0) { noPost++; return; }
    windows++;
    const inner = rows.slice(i + 1, end).filter((x) => x.ev === 'PreToolUse');
    sameIn += inner.filter((x) => x.sid === main).length;
    foreignIn += inner.filter((x) => x.sid !== main).length;
    const after = rows.slice(end + 1).some((x) => x.ev === 'PreToolUse' && x.sid && x.sid !== main);
    if (!inner.length && after) instant++;
  });
  const others = new Set(rows.map((r) => r.sid).filter((s) => s && s !== main));
  const wrote = fs.existsSync(path.join(root, 'step-harness-probe.txt'));
  const seen = (L.readJson(L.sp(root, 'caps.json'), {}) || {}).foreign_seen;
  if (seen) out(`    (참고) 실행 구간 중 다른 session_id 의 호출이 관측된 적 있음: ${seen}`);
  out(`[5] 서브에이전트: 위임 호출 ${windows}건 · 그 사이 도구 호출 — 메인과 같은 session_id ${sameIn}건, 다른 session_id ${foreignIn}건 · 다른 세션 ${others.size}개 · probe 파일 ${wrote ? '생성됨' : '없음'}`);
  let verdict = null;
  if (noPost) out(`    ⚠ 위임 호출 ${noPost}건에 PostToolUse 가 오지 않았다 → receipt 를 기록할 수 없다. config.json 에 "assume_done_on_stop": true 를 넣으면 메인이 멈추려는 시점에 "호출됨"으로 친다.`);
  if (!windows) out('    → 위임 호출(run_subagent/skill)이 기록되지 않음. 안내된 probe 프롬프트를 실행했는지 확인.');
  else if (foreignIn || others.size) verdict = 'foreign';
  else if (sameIn) verdict = 'same';
  else if (wrote) verdict = 'none';
  else out('    → 서브에이전트가 도구를 썼는지 알 수 없음 (probe 파일이 없음). 다시 실행.');
  if (verdict === 'foreign') out('    → foreign: 서브에이전트는 다른 session_id 로 보인다. 실행 중에도 메인의 직접 수정을 막을 수 있다 (가장 안전).');
  if (verdict === 'same') out('    → same: 서브에이전트 호출이 메인과 구분되지 않는다. 위임 실행 구간에는 메인의 호출도 통과한다 (서브에이전트는 foreground 로만 쓸 것).');
  if (verdict === 'none') out('    → none: hook 이 서브에이전트 안에서는 돌지 않는다. hook 에 보이는 호출은 전부 메인 → 실행 중에도 메인의 직접 수정을 막는다. (서브에이전트의 쓰기 범위는 프로필 allowed-tools 로)');
  if (instant) out('    ⚠ 위임 호출의 PostToolUse 가 서브에이전트 작업보다 먼저 왔다 (background 실행). receipt 가 일찍 찍힌다 → foreground 로 실행되게 할 것.');
  if (verdict) {
    if (has('--apply')) {
      const f = L.sp(root, 'config.json');
      L.writeJson(f, { ...(L.readJson(f, {}) || {}), subagent_hooks: verdict });
      out(`    config.json 에 subagent_hooks="${verdict}" 기록함.`);
    } else if (cfg.subagent_hooks !== verdict) out(`    적용: harness.cjs doctor --apply   (config.json 의 subagent_hooks 를 "${verdict}" 로)`);
  }
  const stopRow = rows.find((r) => r.ev === 'Stop');
  if (stopRow) out(`[6] Stop payload 키: ${(stopRow.payload_keys || []).join(', ')}`);
}

module.exports = { install, uninstall, probe, doctor, hooksObject, MARK };
