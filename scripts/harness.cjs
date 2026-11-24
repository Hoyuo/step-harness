#!/usr/bin/env node
'use strict';
// step-harness CLI
//   모델 (hook 이 이것만 통과시킨다): next | check [--wait N] | status | plan | search [q] | execute
//   사람: reset · resume [--proceed] · install [--fail-closed] · uninstall · probe on|off · doctor [--apply]
//   엔진 시험용: start <flow 파일> k=v.. [--force] · lint <flow 파일>   (엔진의 액션을 파일로 직접 주는 형식)
const fs = require('fs');
const path = require('path');
const L = require('./lib.cjs');
const F = require('./flow.cjs');
const J = require('./judge.cjs');
const P = require('./program.cjs');
const S = require('./steps.cjs');

const argv = process.argv.slice(2);
const cmd = argv[0];
const VALUE_OPTS = ['--wait'];
const pos = [];
const kv = {};
for (let i = 1; i < argv.length; i++) {
  const t = argv[i];
  if (VALUE_OPTS.includes(t)) i++;                       // 옵션의 값은 건너뜀
  else if (t.startsWith('--')) continue;
  else if (t.includes('=')) { const [k, v] = t.split(/=(.*)/s); kv[k] = v; }
  else pos.push(t);
}
const has = (f) => argv.includes(f);
const opt = (f, d) => { const i = argv.indexOf(f); return i >= 0 && argv[i + 1] != null ? argv[i + 1] : d; };
const out = (s) => { if (s) { try { fs.writeSync(1, s + '\n'); } catch { /* 닫힌 파이프 */ } } };
const root = L.findRoot(process.cwd());

// seq0 이후에 내려진 판정을 한 줄씩 보여준다 (again = 새 판정이 없을 때 마지막 판정을 다시 보여줄지)
function report(seq0, again) {
  const { flow, state } = L.load(root);
  const line = (h, note) => `[step-harness] ${h.pass ? 'PASSED' : 'FAILED'}: ${h.action}` + (h.route ? ` (route=${h.route})` : '') + (h.report ? ` — report: ${h.report}` : '') + note;
  const hist = state.history || [];
  const fresh = hist.filter((x) => x.seq >= seq0);
  for (const h of fresh) out(line(h, ''));
  if (!fresh.length && hist.length && again) out(line(hist[hist.length - 1], ' (already recorded)'));   // 다른 hook 이 먼저 반영한 판정
  return { flow, state };
}
// 모델 도움 없이 갈 수 있는 데까지 진행시키고, 판정과 다음 할 일을 보여준다
function show(trigger, seq0, wait) {
  const r = J.settle(root, { trigger, waitMs: wait * 1000 });
  const { flow, state } = report(seq0, trigger === 'check');
  if (r === 'pending') {
    const j = J.readJudge(root) || {};
    const sec = j.startedAt ? Math.round((Date.now() - Date.parse(j.startedAt)) / 1000) : 0;
    const a = flow.actions[state.action] || {};
    return out(`[step-harness] STILL RUNNING — verifying "${(a.step && a.step.label) || state.action}" (${sec}s so far). Run the same command again.`);
  }
  if (trigger === 'check') {
    if (r === 'need-action') out('[step-harness] NOT DONE — the NEXT_ACTION below has not been called yet (no receipt).');
    if (r === 'in-flight') out('[step-harness] NOT DONE — the NEXT_ACTION is still in progress.');
    if (r === 'need-work') out('[step-harness] NOT DONE — nothing has been changed yet for the WORK below.');
    if (r === 'need-program' && !state.notDone) out('[step-harness] NOT DONE — no program has been accepted yet.');
  }
  out(L.renderNext(flow, state));
}
function check() {
  const first = L.load(root);
  if (!first.flow || !first.state) return out('[step-harness] No flow is active.');
  show('check', first.state.seq, Number(opt('--wait', first.flow.check_wait_sec || L.config(root).check_wait_sec)));
}

// ───────── 계획(프로그램) 제출
const lastPrompt = () => L.readJson(L.sp(root, 'last-prompt.json'), null) || {};
const startPlan = () => { const p = lastPrompt(); return F.startProgram(root, { task: p.prompt || '', session: p.sid || null, promptId: p.pid || null, lazy: true }); };
// 계획 단계를 시작하고(진행 중인 흐름이 없으면) 계획 API 와 제출 방법을 보여준다
function plan() {
  let cur = L.load(root);
  if (!cur.state || !['running', 'handoff'].includes(cur.state.status)) {
    L.withLock(root, () => {
      const now = L.load(root);
      if (now.state && ['running', 'handoff'].includes(now.state.status)) { cur = now; return; }
      cur = startPlan();
    });
    if (cur.error) { out(`[step-harness] Could not start the plan step: ${cur.error}`); process.exit(1); }
  }
  out(L.renderNext(cur.flow, cur.state));
}
function search() {
  const reg = L.registry(root);
  const cur = L.load(root);
  const doneWhen = S.isProgramFlow(cur.flow) && cur.state && cur.state.status === 'running' ? cur.flow.actions.program.program.done_when || [] : [].concat(L.config(root).done_when || []);
  const q = String(argv[1] || '').toLowerCase();
  const about = (v) => (typeof v === 'string' ? v : (v && (v.about || v.cmd)) || '');
  const rows = [];
  for (const [kind, sect] of [['gate', reg.gates], ['skill', reg.skills], ['agent', reg.agents]]) {
    for (const [name, v] of Object.entries(sect || {})) {
      const d = kind === 'gate' ? (v && v.about) || '' : about(v);   // 게이트는 명령 대신 설명만 보여준다
      if (!q || name.toLowerCase().includes(q) || d.toLowerCase().includes(q)) rows.push(`  ${kind.padEnd(5)} ${name}${d ? ` — ${d}` : ''}`);
    }
  }
  out('```ts\n' + P.declaration(reg, doneWhen) + '\n```');
  out(rows.length ? `registered${q ? ` (matching "${q}")` : ''}:\n${rows.join('\n')}` : `nothing registered${q ? ` matches "${q}"` : ''} (.step-harness/config.json: gates / skills / agents) — use h.work`);
  if (Array.isArray(reg.writable)) out(`writable scopes: ${reg.writable.join(', ')}`);
  out('gate report = a file path with the check output; read it in the step that fixes the failures.');
}
function readProgram() {
  if (argv[1] != null && !argv[1].startsWith('--')) return argv[1];   // pos 가 아니라 원문 그대로 (프로그램에는 "=>" 의 = 가 들어 있다)
  try { return fs.readFileSync(0, 'utf8'); } catch { return ''; }
}
function execute() {
  const code = readProgram();
  const { errors } = P.compile(code, L.registry(root));   // 순수 계산 — 락 밖에서
  let res = null;
  // 확인(다른 흐름인가 · 이미 받아들인 프로그램이 진행 중인가)과 시작을 한 락 안에서 한다 → 동시에 낸 두 프로그램이 둘 다 시작되는 일이 없다
  L.withLock(root, () => {
    let { flow, state } = L.load(root);
    const active = !!(state && ['running', 'handoff'].includes(state.status));
    if (active && (state.status !== 'running' || !S.isProgramFlow(flow))) { res = { kind: 'other' }; return; }
    if (active && L.kind(flow.actions[state.action]) !== 'program') { res = { kind: 'busy' }; return; }
    if (errors.length) {
      if (active) {
        let s = { ...state, rejects: (state.rejects || 0) + 1, rejected: errors.slice(0, 12) };
        if (s.rejects > flow.max_visits) s = F.handoff(flow, s, `프로그램이 검증을 ${flow.max_visits}회 넘게 통과하지 못함`);
        L.saveState(root, s);
      }
      res = { kind: 'rejected', active }; return;
    }
    if (!active) {
      const started = startPlan();
      if (started.error) { res = { kind: 'error', error: started.error }; return; }
      ({ flow, state } = started);
    }
    for (const id of Object.keys(flow.actions)) if (id !== 'program') delete flow.actions[id];   // 앞선 프로그램의 걸음들
    fs.writeFileSync(L.sp(root, 'program.ts'), code);
    L.saveState(root, S.begin(root, flow, state));
    L.log(root, { ev: 'program', run: state.run, bytes: code.length });
    res = { kind: 'started', seq: state.seq };
  });
  if (res.kind === 'started') {
    out('[step-harness] ACCEPTED — the program passed verification. The harness now takes you through it one step at a time.');
    return show('cli', res.seq + 1, Number(opt('--wait', L.config(root).check_wait_sec)));
  }
  const { flow, state } = L.load(root);
  process.exitCode = 1;
  if (res.kind === 'error') return out(`[step-harness] REJECTED — ${res.error}`);
  if (res.kind === 'other') { out(`[step-harness] REJECTED — another flow is active (${flow && flow.flow}, ${state.status}). Do its NEXT_ACTION instead:`); return out(L.renderNext(flow, state)); }
  if (res.kind === 'busy') { out('[step-harness] REJECTED — a program has already been accepted and is in progress. Do its NEXT_ACTION:'); return out(L.renderNext(flow, state)); }
  if (res.active && state.status === 'handoff') return out(L.renderNext(flow, state));
  out('[step-harness] REJECTED — the program did not pass verification. Nothing was started.');
  for (const e of errors.slice(0, 12)) out(`  - ${e}`);
  out('Fix these and submit the whole program again.' + (res.active ? ` (${state.rejects}/${flow.max_visits})` : ''));
}

switch (cmd) {
  case 'next': { const { flow, state } = L.load(root); out(L.renderNext(flow, state) || '[step-harness] No flow is active.'); break; }
  case 'check': check(); break;
  case 'status': {
    const { flow, state } = L.load(root);
    const a = flow && state && state.action ? flow.actions[state.action] : null;
    out(JSON.stringify({ root, flow: flow && flow.flow, state: state && { status: state.status, action: state.action, step: (a && a.step && a.step.label) || null, visits: state.visits,
      receipt: state.receipt, inFlight: state.inFlight, handoff: state.handoff, history: (state.history || []).slice(-5) }, judge: J.readJudge(root) }, null, 2));
    break;
  }
  case 'plan': plan(); break;
  case 'search': search(); break;
  case 'execute': execute(); break;
  case 'start': {
    const cur = L.load(root);
    if (cur.state && ['running', 'handoff'].includes(cur.state.status) && !has('--force')) {
      out(`[step-harness] 이미 진행 중 (${cur.flow && cur.flow.flow}, ${cur.state.status}). 새로 시작하려면 --force`);
      process.exit(1);
    }
    const res = F.start(root, path.resolve(pos[0] || ''), kv);
    if (res.error) { out(res.error); process.exit(1); }
    J.settle(root, { trigger: 'cli' });   // 첫 액션이 judge 면 판정을 바로 시작해 둔다
    const { flow, state } = L.load(root);
    out(`[step-harness] started ${flow.flow} @ ${root}`);
    out(L.renderNext(flow, state));
    break;
  }
  case 'lint': {
    let raw;
    try { raw = F.loadFile(path.resolve(pos[0] || '')); } catch (e) { out('읽기 실패: ' + e.message); process.exit(1); }
    const errors = F.lint(raw);
    if (errors.length) { out(errors.join('\n')); process.exit(1); }
    out(`ok: ${raw.flow} · start=${raw.start} · ` + Object.entries(raw.actions).map(([id, a]) => `${id}(${L.kind(a)})`).join(' '));
    break;
  }
  case 'reset': {
    const { state } = L.load(root);
    if (state) L.saveState(root, { ...state, status: 'stopped' });
    J.killJudge(root);
    out('[step-harness] 중지됨. 진행 중이던 흐름은 끝났다.');
    break;
  }
  case 'resume': {
    const { flow, state } = L.load(root);
    if (!state || state.status !== 'handoff') { out('handoff 상태가 아니다.'); process.exit(1); }
    L.withLock(root, () => { const cur = L.load(root); L.saveState(root, S.answer(root, cur.flow, cur.state, has('--proceed') ? 'proceed' : 'retry')); });
    J.settle(root, { trigger: 'cli' });
    const cur = L.load(root);
    out(L.renderNext(cur.flow, cur.state));
    break;
  }
  case '_judge': J.runJudge(root, argv[1]); break;
  case 'install': case 'uninstall': case 'probe': case 'doctor': require('./doctor.cjs')[cmd](root, { argv, has, out }); break;
  default:
    out('usage: harness.cjs next | check [--wait N] | status | plan | search [q] | execute \'<program>\' (or a quoted heredoc on stdin)\n' +
      '       harness.cjs reset | resume [--proceed] | install [--fail-closed] | uninstall | probe on|off | doctor [--apply]');
    process.exit(cmd ? 1 : 0);
}
