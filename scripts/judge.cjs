'use strict';
// 판정(check 명령) 실행과, 모델 도움 없이 갈 수 있는 데까지 흐름을 진행시키는 settle().
// 판정은 hook·CLI 와 분리된 프로세스로 돈다 → hook 타임아웃(1분)·exec 백그라운드 전환과 무관하고, 같은 판정이 두 번 돌지 않는다.
const fs = require('fs');
const path = require('path');
const { spawn, spawnSync } = require('child_process');
const L = require('./lib.cjs');
const F = require('./flow.cjs');

const SHELL = fs.existsSync('/bin/bash') ? '/bin/bash' : '/bin/sh';   // PATH 에서 찾지 않는다
const PS = fs.existsSync('/bin/ps') ? '/bin/ps' : (fs.existsSync('/usr/bin/ps') ? '/usr/bin/ps' : 'ps');   // PATH 에서 찾지 않는다 (PATH 앞쪽의 사용자 폴더에 같은 이름의 파일을 심을 수 있다)
const jfile = (root) => L.sp(root, 'judge.json');
const readJudge = (root) => L.readJson(jfile(root), null);
const mine = (j, state) => !!j && j.run === state.run && j.seq === state.seq;

function launch(root, state, respawns) {
  const j = { run: state.run, seq: state.seq, action: state.action, status: 'running', pid: null, respawns, startedAt: new Date().toISOString() };
  L.writeJson(jfile(root), j);
  const child = spawn(process.execPath, [L.HARNESS_CLI, '_judge', `${state.run}:${state.seq}`],
    { cwd: root, detached: true, stdio: 'ignore', env: { ...process.env, STEP_HARNESS_ROOT: root } });
  child.on('error', () => {});
  child.unref();
  return j;
}
// 현재 액션의 판정이 돌고 있게 한다 (락을 잡은 상태에서 호출)
function ensureJudge(root, state) {
  const j = readJudge(root);
  if (!mine(j, state)) return launch(root, state, 0);
  if (j.status === 'done') return j;
  const young = Date.now() - Date.parse(j.startedAt) < 5000;
  if (j.pid ? L.alive(j.pid) : young) return j;
  if ((j.respawns || 0) >= 1) {   // 두 번 죽었으면 실패로 확정
    const d = { ...j, status: 'done', exit: 137, died: true, endedAt: new Date().toISOString() };
    L.writeJson(jfile(root), d);
    return d;
  }
  return launch(root, state, (j.respawns || 0) + 1);
}

// 분리된 판정 프로세스 본체: `harness.cjs _judge <run>:<seq>`
function runJudge(root, key) {
  const [run, seqStr] = String(key).split(':');
  const seq = Number(seqStr);
  const current = () => {
    const s = L.load(root).state;
    const j = readJudge(root);
    return s && s.run === run && s.seq === seq && j && j.run === run && j.seq === seq && j.status !== 'done' ? { s, j } : null;
  };
  const c = current();
  const flow = L.load(root).flow;
  if (!c || !flow) return;
  const a = flow.actions[c.s.action];
  if (!a || !a.check) return;
  const rel = `${L.DIR}/reports/${a.id}.txt`;
  const file = path.join(root, rel);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const fd = fs.openSync(file, 'w');
  const t0 = Date.now();
  let timedOut = false, finished = false;
  const child = spawn(SHELL, ['-c', a.check], { cwd: root, stdio: ['ignore', fd, fd], detached: true,   // 자체 프로세스 그룹 → 시간 초과 시 자식까지 정리
    env: { ...process.env, STEP_HARNESS: '1', STEP_HARNESS_FLOW: flow.flow, STEP_HARNESS_ACTION: a.id } });
  L.writeJson(jfile(root), { ...c.j, pid: process.pid, gatePid: child.pid || null });
  const timer = setTimeout(() => { timedOut = true; killGroup(child.pid); }, flow.check_timeout_sec * 1000);
  const finish = (code) => {
    if (finished) return;
    finished = true;
    clearTimeout(timer);
    try { fs.closeSync(fd); } catch { /* 무시 */ }
    const exit = timedOut ? 124 : (typeof code === 'number' ? code : 1);
    let route = null;
    try {   // 실패 분기 키: 출력의 마지막 `HARNESS_ROUTE=<키>` 줄
      const size = fs.statSync(file).size;
      const len = Math.min(size, 65536);
      const buf = Buffer.alloc(len);
      const f2 = fs.openSync(file, 'r');
      fs.readSync(f2, buf, 0, len, size - len);
      fs.closeSync(f2);
      const m = [...buf.toString('utf8').matchAll(/^HARNESS_ROUTE=([\w.:\/-]+)[ \t]*$/gm)].pop();
      if (m) route = m[1];
    } catch { /* 리포트를 못 읽으면 route 없이 */ }
    const still = current();
    if (!still) return;   // 그 사이 흐름이 바뀌었다 → 결과 버림
    try { fs.copyFileSync(file, L.sp(root, 'last-report.txt')); } catch { /* 무시 */ }
    L.writeJson(jfile(root), { ...still.j, pid: process.pid, status: 'done', exit, timedOut, route, report: rel, ms: Date.now() - t0, endedAt: new Date().toISOString() });
  };
  child.on('error', () => finish(127));
  child.on('exit', (code) => finish(code));
}
function killGroup(pid) {
  if (!pid) return;
  try { process.kill(-pid, 'SIGKILL'); } catch { try { process.kill(pid, 'SIGKILL'); } catch { /* 이미 끝남 */ } }
}
// 프로그램 실행 프로세스(`harness.cjs _exec <run>:<seq>`)와 그 자식(작업자·게이트)을 정리한다.
// pid 가 다른 프로세스에 재사용됐을 수 있으므로, 명령줄이 이 실행의 것일 때만 죽인다.
function killExec(st) {
  const x = st && st.exec;
  if (!x || !x.pid || x.pid === process.pid || !L.alive(x.pid)) return false;
  let cmdline = '';
  try { cmdline = String(spawnSync(PS, ['-o', 'command=', '-p', String(x.pid)], { encoding: 'utf8' }).stdout || ''); } catch { /* ps 없음 */ }
  if (!cmdline.includes(`_exec ${st.run}:`)) return false;
  killGroup(x.pid);
  return true;
}
// 흐름이 더는 프로그램을 기다리지 않는데(사람에게 넘어감 · 중단 · 완료) 실행 프로세스 기록이 남아 있으면 정리한다.
// hook 과 CLI 가 끝날 때마다 부른다 (락을 잡지 않은 상태에서 호출).
function reapExec(root) {
  const st = L.readJson(L.sp(root, 'state.json'), null);
  if (!st || !st.exec || !st.exec.pid) return false;
  if (st.status === 'running' && st.inFlight && st.inFlight.seq === st.seq) return false;   // 정상: 실행을 기다리는 중
  // 사람이 멈춘 경우는 멈춘 쪽이 직접 정리한다(killJudge). 여기서 죽이면, 상태 파일만 "stopped" 로 고쳐진 경우에 실행 프로세스가 그것을 바로잡지 못한다
  if (st.status === 'stopped') return false;
  const killed = killExec(st);
  L.withLock(root, () => {
    const { flow, state: s } = L.load(root);
    if (!s || !s.exec || s.exec.pid !== st.exec.pid || (s.status === 'running' && s.inFlight && s.inFlight.seq === s.seq)) return;
    if (s.status === 'done' && flow && flow.actions && flow.actions.program) {
      // 완료는 실행 프로세스가 exec 기록을 지우면서 남긴다. exec 가 남은 done 은 상태 파일을 직접 고친 것이다
      const next = F.handoff(flow, { ...s, status: 'running', action: 'program' }, '실행 중에 상태 파일이 직접 수정됨 (완료 표시는 실행 프로세스만 남길 수 있다)');
      L.saveState(root, { ...next, exec: null });
      L.log(root, { ev: 'program-end', status: 'handoff', why: 'state-tampered' });
      return;
    }
    L.saveState(root, { ...s, exec: null });
  });
  if (killed) L.log(root, { ev: 'program-killed', pid: st.exec.pid, status: st.status });
  return killed;
}
// 환경변수에 marker 가 들어 있는 프로세스의 pid (Linux: /proc/<pid>/environ. 그런 것이 없는 OS 에서는 빈 목록)
function markedPids(marker, procDir = '/proc') {
  const out = [];
  let names = [];
  try { names = fs.readdirSync(procDir); } catch { return out; }
  for (const name of names) {
    if (!/^\d+$/.test(name)) continue;
    try { if (fs.readFileSync(path.join(procDir, name, 'environ'), 'utf8').split('\0').includes(marker)) out.push(Number(name)); } catch { /* 읽을 수 없는 프로세스 */ }
  }
  return out;
}
// 이 프로젝트의 프로그램 실행 프로세스(`… harness.cjs _exec <run>:<seq> <root>`) 중 살아 있는 것의 pid.
// 상태 파일의 기록(exec.pid)이 아니라 프로세스 목록에서 찾는다 (상태 파일은 고쳐질 수 있다).
function liveExecs(root) {
  let out = '';
  try { out = String(spawnSync(PS, ['-axo', 'pid=,command='], { encoding: 'utf8', maxBuffer: 16 << 20 }).stdout || ''); } catch { return []; }
  const roots = [root];
  try { roots.push(fs.realpathSync(root)); } catch { /* 그대로 */ }
  return out.split('\n').map((l) => l.trim())
    .filter((l) => l.includes('harness.cjs') && / _exec \S+ /.test(l) && roots.some((r) => l.endsWith(` ${r}`)))
    .map((l) => parseInt(l, 10)).filter((p) => p && p !== process.pid);
}
// 프로그램 흐름이 "완료"·"중단"으로 돼 있는데 실행 프로세스가 아직 살아 있으면 상태 파일이 직접 고쳐진 것이다 → 사람에게 넘기고 실행을 정리한다.
// (정상 완료·중단이면 실행 프로세스는 곧 사라진다. 그래서 잠깐 기다렸다가 다시 본다.) 고쳐진 것으로 판단했으면 true
function endedButRunning(root) {
  const st = L.readJson(L.sp(root, 'state.json'), null);
  if (!st || (st.status !== 'done' && st.status !== 'stopped')) return false;
  if (!liveExecs(root).length) return false;
  L.sleep(st.status === 'stopped' ? 1500 : 400);
  const pids = liveExecs(root);
  if (!pids.length) return false;
  let fixed = false;
  L.withLock(root, () => {
    const { flow, state: s } = L.load(root);
    if (!flow || !flow.actions || !flow.actions.program || !s || (s.status !== 'done' && s.status !== 'stopped')) return;
    const next = F.handoff(flow, { ...s, status: 'running', action: 'program' }, `실행 중에 상태 파일이 직접 수정됨 ("${s.status}" 로 바뀌어 있었음)`);
    L.saveState(root, { ...next, exec: null });
    L.log(root, { ev: 'program-end', status: 'handoff', why: 'state-tampered', found: s.status });
    fixed = true;
  });
  if (fixed) for (const p of pids) killGroup(p);
  return fixed;
}
// 흐름을 사람이 멈췄을 때: 돌고 있는 판정(명령과 그 자식들)을 정리
function killJudge(root) {
  const st = L.readJson(L.sp(root, 'state.json'), null);
  killExec(st);   // 프로그램 실행 프로세스(와 그 작업자·게이트)도 정리
  if (st && st.exec) L.withLock(root, () => { const s = L.load(root).state; if (s && s.exec && s.status !== 'running') L.saveState(root, { ...s, exec: null }); });
  const j = readJudge(root);
  if (!j || j.status === 'done') return;
  killGroup(j.gatePid);
  if (j.pid && j.pid !== process.pid) { try { process.kill(j.pid, 'SIGKILL'); } catch { /* 이미 끝남 */ } }
}

function commit(root, flow, state, outcome, report) {
  const next = F.advance(flow, state, outcome);
  next.history = [...(state.history || []), { seq: state.seq, action: state.action, pass: !!outcome.pass, route: outcome.route || null,
    report: report || null, at: new Date().toISOString() }].slice(-30);
  L.saveState(root, next);
  L.log(root, { ev: 'advance', from: state.action, pass: !!outcome.pass, route: outcome.route || null, why: outcome.why || null,
    to: next.status === 'running' ? next.action : next.status });
  return 'again';
}
// 한 걸음. 'again' = 진행했음(다시 호출) / 'pending' = 판정 중 / 그 외 = 모델이나 사람이 할 차례
function step(root, trigger) {
  const { flow, state } = L.load(root);
  if (!flow || !state) return 'idle';
  if (state.status !== 'running') return state.status;
  const a = flow.actions[state.action];
  const k = L.kind(a);
  const fresh = (x) => !!x && x.seq === state.seq;
  if (k === 'program') {   // 프로그램 실행 프로세스가 끝나면 스스로 상태를 done / handoff 로 바꾼다. 여기서는 죽었는지만 본다
    if (!fresh(state.inFlight)) return 'need-program';
    const x = state.exec || {};
    const young = Date.now() - Date.parse(state.inFlight.since) < 5000;
    if (x.pid ? L.alive(x.pid) : young) return 'pending';
    const next = F.handoff(flow, state, '프로그램 실행 프로세스가 결과를 남기지 않고 끝남');
    L.saveState(root, next);
    L.log(root, { ev: 'advance', from: 'program', pass: false, why: 'program-died', to: 'handoff' });
    return 'again';
  }
  if (k === 'call') {
    if (!fresh(state.receipt)) return fresh(state.inFlight) ? 'in-flight' : 'need-action';
    if (!state.receipt.ok) return commit(root, flow, state, { pass: false, why: `${a.tool} 호출이 실패함` });
    if (!a.check) return commit(root, flow, state, { pass: true });
  } else if (k === 'work') {
    if (!state.workDone) {
      if (trigger !== 'check' && trigger !== 'stop') return 'working';
      if (!fresh(state.receipt) || !state.receipt.mutations) return 'need-work';
      state.workDone = true;
      L.saveState(root, state);
    }
    if (!a.check) return commit(root, flow, state, { pass: true });
  }
  const j = ensureJudge(root, state);
  if (j.status !== 'done') return 'pending';
  const why = j.died ? '판정 프로세스가 죽음' : j.timedOut ? `판정 시간 초과(${flow.check_timeout_sec}s)` : null;
  return commit(root, flow, state, { pass: j.exit === 0, route: j.route, why }, j.report);
}
// 모델 도움 없이 갈 수 있는 데까지 진행. waitMs 동안은 판정이 끝나길 기다린다.
function settle(root, { trigger = 'auto', waitMs = 0 } = {}) {
  const deadline = Date.now() + waitMs;
  let trig = trigger;
  for (let guard = 0; guard < 100000; guard++) {
    const r = L.withLock(root, () => step(root, trig));
    if (r === 'again') { trig = 'auto'; continue; }   // "끝났다"는 신호(check/stop)는 그때의 액션에만 해당한다
    if (r !== 'pending' || Date.now() >= deadline) return r;
    L.sleep(Math.min(80, Math.max(5, deadline - Date.now())));
  }
  return 'pending';
}

module.exports = { readJudge, ensureJudge, runJudge, killJudge, killGroup, killExec, reapExec, liveExecs, endedButRunning, markedPids, settle, SHELL, PS };
