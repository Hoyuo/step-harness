#!/usr/bin/env node
'use strict';
// step-harness CLI
//   모델 (hook 이 이 셋만 통과시킨다): next | check [--wait N] | status
//   사람: start <flow> k=v.. [--force] · lint <flow> · reset · resume
//         run <flow> k=v.. --worker "<명령>"   (러너 모드: 순서를 스크립트가 쥐고, 작업마다 작업자 명령을 실행)
//         install [--fail-closed] · uninstall · probe on|off · doctor [--apply]
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const L = require('./lib.cjs');
const F = require('./flow.cjs');
const J = require('./judge.cjs');

const argv = process.argv.slice(2);
const cmd = argv[0];
const VALUE_OPTS = ['--wait', '--worker', '--timeout'];
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

function report(seq0) {
  const { flow, state } = L.load(root);
  const line = (h, note) => `[step-harness] ${h.pass ? 'PASSED' : 'FAILED'}: ${h.action}` + (h.route ? ` (route=${h.route})` : '') + (h.report ? ` — report: ${h.report}` : '') + note;
  const hist = state.history || [];
  const fresh = hist.filter((x) => x.seq >= seq0);
  for (const h of fresh) out(line(h, ''));
  if (!fresh.length && hist.length) out(line(hist[hist.length - 1], ' (already recorded)'));   // 다른 hook 이 먼저 반영한 판정
  return { flow, state };
}
function check() {
  const first = L.load(root);
  if (!first.flow || !first.state) return out('[step-harness] No flow is active.');
  const wait = Number(opt('--wait', first.flow.check_wait_sec || L.config(root).check_wait_sec));
  const r = J.settle(root, { trigger: 'check', waitMs: wait * 1000 });
  const { flow, state } = report(first.state.seq);
  if (r === 'pending') {
    const j = J.readJudge(root) || {};
    const sec = j.startedAt ? Math.round((Date.now() - Date.parse(j.startedAt)) / 1000) : 0;
    return out(`[step-harness] STILL RUNNING — verifying "${state.action}" (${sec}s so far). Call the same command again.`);
  }
  if (r === 'need-action') out('[step-harness] NOT DONE — the NEXT_ACTION below has not been called yet (no receipt).');
  if (r === 'in-flight') out('[step-harness] NOT DONE — the NEXT_ACTION is still in progress.');
  if (r === 'need-work') out('[step-harness] NOT DONE — nothing has been changed yet for the WORK below.');
  out(L.renderNext(flow, state));
}

function workerPrompt(flow, a) {
  if (a.prompt) return a.prompt;
  const p = a.params || {};
  const tail = [];
  if (a.write_scope) tail.push(`You may only write files under: ${a.write_scope.join(', ')}.`);
  tail.push('Do not ask questions. When you are finished, stop.');
  if (a.work) return [a.work, ...tail].join('\n');
  if (a.tool === 'skill') return [`Use the skill "${p.skill || p.name}"` + (p.args ? ` with these arguments: ${p.args}` : '') + '. Follow it exactly and completely.', ...tail].join('\n');
  if (a.tool === 'run_subagent') return [String(p.task || p.prompt || JSON.stringify(p)), ...tail].join('\n');
  return [`Call the tool ${a.tool} with exactly these params: ${JSON.stringify(p)}.`, ...tail].join('\n');
}
// 러너 모드: 다음에 무엇을 할지는 전부 이 루프가 정한다. 모델은 작업자 명령 안에서 "한 가지 일"만 한다.
function run() {
  const res = F.start(root, path.resolve(pos[0] || ''), kv, { mode: 'runner' });
  if (res.error) { out(res.error); process.exit(1); }
  const worker = opt('--worker', res.flow.worker || L.config(root).worker);
  const needsWorker = Object.values(res.flow.actions).some((a) => L.kind(a) !== 'judge');
  if (needsWorker && !worker) {
    out('worker 명령이 필요함: --worker \'devin -p --prompt-file {prompt_file} --permission-mode accept-edits --respect-workspace-trust false\' (또는 flow 의 "worker")');
    process.exit(1);
  }
  const timeout = Number(opt('--timeout', 3600)) * 1000;
  let seq0 = 0;
  for (;;) {
    const { flow, state } = L.load(root);
    if (state.status !== 'running') break;
    const a = flow.actions[state.action];
    if (L.kind(a) !== 'judge') {
      const pf = L.sp(root, 'prompt.txt');
      fs.writeFileSync(pf, workerPrompt(flow, a) + '\n');
      const line = worker.replace(/\{prompt_file\}/g, L.shq(pf)).replace(/\{action\}/g, a.id);
      out(`[step-harness] ▶ ${a.id} (attempt ${state.visits[a.id]}/${flow.max_visits}): ${line}`);
      const r = spawnSync(J.SHELL, ['-c', line], { cwd: root, stdio: 'inherit', timeout });
      L.withLock(root, () => {
        const s = L.load(root).state;
        if (s.seq !== state.seq) return;
        L.saveState(root, { ...s, workDone: true, receipt: { seq: s.seq, ok: r.status === 0, tool: 'worker', mutations: 1, at: new Date().toISOString() } });
      });
    }
    J.settle(root, { trigger: 'check', waitMs: (flow.check_timeout_sec + 60) * 1000 });
    seq0 = report(seq0).state.seq;
  }
  const { flow, state } = L.load(root);
  out(state.status === 'done' ? `[step-harness] DONE: ${flow.done || flow.flow}` : `[step-harness] ${state.status.toUpperCase()}: ${(state.handoff && state.handoff.reason) || ''}`);
  process.exitCode = state.status === 'done' ? 0 : 2;
}

switch (cmd) {
  case 'next': { const { flow, state } = L.load(root); out(L.renderNext(flow, state) || '[step-harness] No flow is active.'); break; }
  case 'check': check(); break;
  case 'status': {
    const { flow, state } = L.load(root);
    out(JSON.stringify({ root, flow: flow && flow.flow, state: state && { status: state.status, action: state.action, visits: state.visits, receipt: state.receipt,
      inFlight: state.inFlight, handoff: state.handoff, history: (state.history || []).slice(-5) }, judge: J.readJudge(root) }, null, 2));
    break;
  }
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
    out('[step-harness] 중지됨. hook 은 더 이상 막지 않는다.');
    break;
  }
  case 'resume': {
    const { flow, state } = L.load(root);
    if (!state || state.status !== 'handoff') { out('handoff 상태가 아니다.'); process.exit(1); }
    L.saveState(root, F.answer(flow, state, has('--proceed') ? 'proceed' : 'retry'));
    J.settle(root, { trigger: 'cli' });
    const cur = L.load(root);
    out(L.renderNext(cur.flow, cur.state));
    break;
  }
  case 'run': run(); break;
  case '_judge': J.runJudge(root, argv[1]); break;
  case 'install': case 'uninstall': case 'probe': case 'doctor': require('./doctor.cjs')[cmd](root, { argv, has, out }); break;
  default:
    out('usage: harness.cjs next | check [--wait N] | status\n       harness.cjs start <flow> k=v.. [--force] | lint <flow> | reset | resume [--proceed]\n' +
      '       harness.cjs run <flow> k=v.. --worker "<cmd with {prompt_file}>"\n       harness.cjs install [--fail-closed] | uninstall | probe on|off | doctor [--apply]');
    process.exit(cmd ? 1 : 0);
}
