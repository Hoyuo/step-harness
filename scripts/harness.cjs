#!/usr/bin/env node
'use strict';
// step-harness CLI
//   모델 (hook 이 이 셋만 통과시킨다): next | check [--wait N] | status
//   사람: start <flow> k=v.. [--force] · lint <flow> · reset · resume
//         run <flow> k=v.. --worker "<명령>"   (러너 모드: 순서를 스크립트가 쥐고, 작업마다 작업자 명령을 실행)
//         install [--fail-closed] · uninstall · probe on|off · doctor [--apply]
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { spawn, spawnSync } = require('child_process');
const L = require('./lib.cjs');
const F = require('./flow.cjs');
const J = require('./judge.cjs');
const P = require('./program.cjs');

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
// 프로그램 흐름: 실행 프로세스가 남긴 단계 중 아직 보여주지 않은 것만 (check 를 여러 번 불러도 같은 줄이 반복되지 않게)
function reportProgram() {
  let cur, fresh = [];
  L.withLock(root, () => {
    cur = L.load(root);
    fresh = (cur.state.history || []).filter((x) => (x.n || 0) > (cur.state.reportedN || 0));
    if (fresh.length) { cur.state = { ...cur.state, reportedN: fresh[fresh.length - 1].n }; L.saveState(root, cur.state); }
  });
  for (const h of fresh) out(`[step-harness] ${h.pass ? 'PASSED' : 'FAILED'}: ${h.action}` + (h.route ? ` (route=${h.route})` : '') + (h.report ? ` — report: ${h.report}` : ''));   // 출력은 락 밖에서
  return cur;
}
function check() {
  const first = L.load(root);
  if (!first.flow || !first.state) return out('[step-harness] No flow is active.');
  const wait = Number(opt('--wait', first.flow.check_wait_sec || L.config(root).check_wait_sec));
  const r0 = J.settle(root, { trigger: 'check', waitMs: wait * 1000 });
  J.reapExec(root);
  const program = !!(first.flow.actions.program && first.flow.actions.program.program);
  // 프로그램 흐름이 끝났다고 돼 있는데 그 실행 프로세스가 아직 살아 있다 = 상태 파일이 직접 고쳐진 것 → 결과를 알리지 않고 사람에게 넘긴다
  const r = program && J.endedButRunning(root) ? 'handoff' : r0;
  const { flow, state } = program ? reportProgram() : report(first.state.seq);
  if (r === 'pending' && L.kind(flow.actions[state.action] || {}) === 'program') {
    const sec = state.inFlight ? Math.round((Date.now() - Date.parse(state.inFlight.since)) / 1000) : 0;
    return out(`[step-harness] STILL RUNNING — the program is running (${sec}s so far). Call the same command again.`);
  }
  if (r === 'pending') {
    const j = J.readJudge(root) || {};
    const sec = j.startedAt ? Math.round((Date.now() - Date.parse(j.startedAt)) / 1000) : 0;
    return out(`[step-harness] STILL RUNNING — verifying "${state.action}" (${sec}s so far). Call the same command again.`);
  }
  if (r === 'need-action') out('[step-harness] NOT DONE — the NEXT_ACTION below has not been called yet (no receipt).');
  if (r === 'in-flight') out('[step-harness] NOT DONE — the NEXT_ACTION is still in progress.');
  if (r === 'need-work') out('[step-harness] NOT DONE — nothing has been changed yet for the WORK below.');
  if (r === 'need-program' && !state.notDone) out('[step-harness] NOT DONE — no program has been executed yet.');
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
      const r = spawnSync(J.SHELL, ['-c', line], { cwd: root, stdio: 'inherit', timeout, env: { ...process.env, STEP_HARNESS_WORKER: `${state.run}:${state.seq}` } });
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


// ───────── 프로그램 모드 (Code Mode)
const isProgram = (flow, state) => !!(flow && state && state.action && flow.actions[state.action] && L.kind(flow.actions[state.action]) === 'program');
const waiting = (state) => !!(state && state.status === 'running' && state.inFlight && state.inFlight.seq === state.seq);
function search() {
  const reg = L.registry(root);
  const cur = L.load(root);
  const doneWhen = isProgram(cur.flow, cur.state) ? cur.flow.actions.program.program.done_when || [] : [].concat(L.config(root).done_when || []);
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
  out(rows.length ? `registered${q ? ` (matching "${q}")` : ''}:\n${rows.join('\n')}` : `nothing registered${q ? ` matches "${q}"` : ''} (.step-harness/config.json: gates / skills / agents)`);
  if (Array.isArray(reg.writable)) out(`writable scopes: ${reg.writable.join(', ')}`);
  if (!reg.worker) out('note: no "worker" command is configured, so h.skill / h.agent cannot be used.');
  out('gate report = a file path with the gate output; pass it to a skill/agent instead of reading it yourself.');
}
function readProgram() {
  if (argv[1] != null && !argv[1].startsWith('--')) return argv[1];   // pos 가 아니라 원문 그대로 (프로그램에는 "=>" 의 = 가 들어 있다)
  try { return fs.readFileSync(0, 'utf8'); } catch { return ''; }
}
function execute() {
  const code = readProgram();
  const { errors } = P.compile(code, L.registry(root));   // 순수 계산 — 락 밖에서
  J.reapExec(root);                                        // 끝난 흐름의 실행 프로세스가 남아 있으면 먼저 정리
  let res = null;
  // 확인(다른 흐름인가 · 이미 도는가)과 시작을 한 락 안에서 한다 → 동시에 낸 두 프로그램이 둘 다 시작되는 일이 없다
  L.withLock(root, () => {
    let { flow, state } = L.load(root);
    const active = !!(state && ['running', 'handoff'].includes(state.status));
    if (active && (state.status !== 'running' || !isProgram(flow, state))) { res = { kind: 'other' }; return; }
    if (active && state.exec && state.exec.pid && L.alive(state.exec.pid) && !waiting(state)) {   // 실행 구간 표시만 사라진 경우: 되살린다
      state = { ...state, inFlight: { seq: state.seq, since: state.exec.startedAt || new Date().toISOString(), tool: 'program' } };
      L.saveState(root, state);
    }
    if (active && waiting(state)) { res = { kind: 'busy' }; return; }
    if (errors.length) {
      if (active) {
        let s = { ...state, rejects: (state.rejects || 0) + 1, rejected: errors.slice(0, 12) };
        if (s.rejects > flow.max_visits) s = F.handoff(flow, s, `프로그램이 검증을 ${flow.max_visits}회 넘게 통과하지 못함`);
        L.saveState(root, s);
      }
      res = { kind: 'rejected', active }; return;
    }
    if (!active) {
      const started = F.startProgram(root, { task: '' });
      if (started.error) { res = { kind: 'error', error: started.error }; return; }
      ({ flow, state } = started);
    }
    if (flow.actions.program.write_scope) { delete flow.actions.program.write_scope; L.writeJson(L.sp(root, 'flow.json'), flow); }   // 죽은 실행이 남긴 범위
    fs.writeFileSync(L.sp(root, 'program.ts'), code);
    const next = { ...state, inFlight: { seq: state.seq, since: new Date().toISOString(), tool: 'program' }, rejects: 0, rejected: null, notDone: null, exec: null };
    L.saveState(root, next);
    const child = spawn(process.execPath, [L.HARNESS_CLI, '_exec', `${state.run}:${state.seq}`, root],   // 마지막 인자(root)는 "이 프로젝트의 실행 프로세스"를 찾을 때 쓴다
      { cwd: root, detached: true, stdio: 'ignore', env: { ...process.env, STEP_HARNESS_ROOT: root } });
    child.on('error', () => {});
    child.unref();
    L.saveState(root, { ...next, exec: { pid: child.pid || null, startedAt: next.inFlight.since } });
    L.log(root, { ev: 'program', run: state.run, seq: state.seq, bytes: code.length });
    res = { kind: 'started' };
  });
  const { flow, state } = L.load(root);
  if (res.kind === 'started') { out('[step-harness] ACCEPTED — the program passed verification and is running.'); return check(); }
  process.exitCode = 1;
  if (res.kind === 'error') return out(`[step-harness] REJECTED — ${res.error}`);
  if (res.kind === 'other') { out(`[step-harness] REJECTED — another flow is active (${flow && flow.flow}, ${state.status}). Do its NEXT_ACTION instead:`); return out(L.renderNext(flow, state)); }
  if (res.kind === 'busy') { out('[step-harness] REJECTED — a program is already running. Wait for it:'); return out(L.renderNext(flow, state)); }
  if (res.active && state.status === 'handoff') return out(L.renderNext(flow, state));
  out('[step-harness] REJECTED — the program did not pass verification. Nothing was run.');
  for (const e of errors.slice(0, 12)) out(`  - ${e}`);
  out('Fix these and submit the whole program again.' + (res.active ? ` (${state.rejects}/${flow.max_visits})` : ''));
}
// 하네스가 직접 돌리는 git. git 은 설정에 적힌 명령을 대신 실행한다 (예: core.fsmonitor 는 `git status` 때마다 실행된다).
// 작업자가 쓸 수 있는 설정(~/.gitconfig 등)을 통해 하네스 프로세스가 엉뚱한 명령을 실행하지 않도록:
//   · 사용자·시스템 설정은 읽지 않는다 · fsmonitor 와 hook 은 끈다 · 색인을 고쳐 쓰지 않는다
// (저장소의 .git/config 는 "보호 대상 파일"이다: 작업자가 도는 동안 바뀌면 git 을 돌리기 전에 멈춘다)
//   · 실행 파일은 PATH 에서 그때그때 찾지 않고 처음에 정한 절대 경로를 쓴다 (PATH 앞쪽의 사용자 폴더에 심은 `git` 을 실행하지 않도록)
//   · 샌드박스가 켜져 있으면 git 도 그 안에서 돌린다 (그래도 git 이 무언가를 실행하게 됐을 때 보호 대상에 쓰지 못하게)
//   · 객체 바꿔치기(refs/replace)는 따르지 않는다 (커밋을 다른 내용으로 보이게 해서 변경을 숨기지 못하도록)
const GIT_ENV = { GIT_CONFIG_GLOBAL: '/dev/null', GIT_CONFIG_SYSTEM: '/dev/null', GIT_CONFIG_NOSYSTEM: '1', GIT_ATTR_NOSYSTEM: '1', GIT_OPTIONAL_LOCKS: '0', GIT_TERMINAL_PROMPT: '0', GIT_NO_REPLACE_OBJECTS: '1' };
const notMine = (p) => { try { fs.accessSync(p, fs.constants.W_OK); return false; } catch { return fs.existsSync(p); } };   // 있지만 내가 고쳐 쓸 수는 없는 경로
const fixedPlace = (p) => !!p && path.isAbsolute(p) && notMine(p) && notMine(path.dirname(p));
function findGit() {
  let found = '';
  try { found = String(spawnSync('/bin/sh', ['-c', 'command -v git'], { encoding: 'utf8' }).stdout || '').trim(); } catch { /* 없음 */ }
  try { if (found) found = fs.realpathSync(found); } catch { /* 그대로 */ }
  if (fixedPlace(found)) return found;
  // PATH 의 git 이 사용자가 고쳐 쓸 수 있는 곳에 있다(Homebrew 등) → 시스템 것이 쓸 만하면 그것을, 아니면 지금 찾은 것을 절대 경로로 고정한다
  const sys = '/usr/bin/git';
  const usable = fixedPlace(sys) && (process.platform !== 'darwin' || spawnSync('/usr/bin/xcode-select', ['-p'], { stdio: 'ignore' }).status === 0);
  return usable ? sys : (found || 'git');
}
let GIT_BIN = null;     // 처음 쓸 때 정한다 (실행 프로세스에서는 작업자를 돌리기 전에)
let GIT_BOX = null;     // 샌드박스 프로필 (execProgram 이 정한다)
let GIT_FLAGS = null;
function gitFlags() {
  if (GIT_FLAGS) return GIT_FLAGS;
  GIT_FLAGS = ['-c', 'core.fsmonitor=false', '-c', 'core.untrackedCache=false'];
  // 사용자 설정을 읽지 않으면 사용자가 정해 둔 전역 무시 목록(core.excludesFile)도 빠진다 → 그 값만 읽어 넘긴다 (값을 읽는 것은 아무것도 실행하지 않는다)
  try {
    const r = spawnSync(GIT_BIN, ['config', '--global', '--get', 'core.excludesFile'], { encoding: 'utf8' });
    const v = String(r.stdout || '').trim();
    if (r.status === 0 && v) GIT_FLAGS.push('-c', `core.excludesFile=${v}`);
  } catch { /* 없음 */ }
  return GIT_FLAGS;
}
const git = (args, cwd) => {
  if (!GIT_BIN) GIT_BIN = findGit();
  const argv = [...gitFlags(), ...args];
  const opts = { cwd: cwd || root, encoding: 'utf8', maxBuffer: 64 << 20, env: { ...process.env, ...GIT_ENV } };
  return GIT_BOX ? spawnSync('/usr/bin/sandbox-exec', ['-p', GIT_BOX, GIT_BIN, ...argv], opts) : spawnSync(GIT_BIN, argv, opts);
};
const realRoot = () => { try { return fs.realpathSync(root); } catch { return root; } };
// 파일 하나의 서명: 크기·수정 시각·ctime·모드 (없으면 gone). ctime 은 내용을 바꾸고 크기·수정 시각을 되돌려도 달라진다.
const fileSig = (abs) => { try { const st = fs.lstatSync(abs); return `${st.size}:${st.mtimeMs}:${st.ctimeMs}:${st.mode}`; } catch { return 'gone'; } };
// 폴더가 그 자체로 git 저장소(하위 모듈 · 안에 따로 만든 저장소)면 한 덩어리로 본다: 그 저장소의 커밋과 "깨끗하지 않은 파일" 전부가 서명이다.
//   (바깥 저장소의 `git status` 는 그 폴더가 달라졌다는 것만 알려준다 → 이미 달라져 있던 폴더 안을 또 고친 것은 이 서명으로 잡는다)
const onDisk = (p) => { try { return (fs.realpathSync.native || fs.realpathSync)(p); } catch { return p; } };
const isRepoDir = (abs) => { try { return fs.lstatSync(abs).isDirectory() && fs.existsSync(path.join(abs, '.git')); } catch { return false; } };
const sigOf = (abs, depth = 0) => {
  const inner = depth < 3 && isRepoDir(abs) ? gitSnapshot(abs, depth + 1) : null;
  return inner ? `repo:${inner.head}:${crypto.createHash('sha1').update(JSON.stringify([...inner].sort())).digest('hex')}` : fileSig(abs);
};
// 작업자가 범위 밖을 고쳤는지는 실행 뒤에 git 으로 확인한다 (hook 은 파일 도구의 경로만 본다. 셸 명령이 쓴 파일은 여기서 잡힌다).
// 반환: Map<프로젝트 기준 상대경로, 서명> — git 이 "깨끗하지 않다"고 보는 파일 전부(변경·추가·삭제·미추적)와,
//   git 이 보지 않게 표시해 둔 파일(assume-unchanged · skip-worktree). 지금의 커밋은 .head 에 둔다. git 저장소가 아니거나 git 이 답하지 못하면 null.
function gitSnapshot(dir = root, depth = 0) {
  const top = git(['rev-parse', '--show-toplevel'], dir);
  if (top.status !== 0 || !top.stdout.trim()) return null;
  let base = top.stdout.trim();
  try { base = fs.realpathSync(base); } catch { /* 그대로 */ }
  if (depth && onDisk(base) !== onDisk(dir)) return null;   // .git 이 있지만 저장소가 아닌 폴더 (git 이 바깥 저장소를 가리킨다)
  const args = ['status', '--porcelain=v1', '-z', '--untracked-files=all'];
  let r = git([...args, '--no-renames'], dir);
  if (r.status !== 0) r = git(args, dir);   // 오래된 git 은 --no-renames 를 모른다 → 이름 변경 항목(R/C)은 아래에서 두 경로로 풀어 읽는다
  if (r.status !== 0) return null;
  const here = depth ? base : realRoot();
  const m = new Map();
  const add = (file) => { const abs = path.join(base, file); m.set(path.relative(here, abs).split(path.sep).join('/'), sigOf(abs, depth)); };
  const parts = r.stdout.split('\0');
  for (let i = 0; i < parts.length; i++) {
    const e = parts[i];
    if (e.length < 4) continue;
    add(e.slice(3));
    if (/[RC]/.test(e.slice(0, 2)) && parts[i + 1]) add(parts[++i]);   // "R  새이름\0원래이름"
  }
  // `git status` 가 보지 않게 표시된 파일(소문자 = assume-unchanged, S = skip-worktree)도 넣는다 → 그런 파일을 고치거나, 고친 뒤에 그렇게 표시해도 서명으로 드러난다
  const hid = git(['ls-files', '-v', '-z', '--full-name', ':/'], dir);
  if (hid.status === 0) {
    const tracked = new Set();
    const dirs = new Set(['']);   // git 이 관리하는 파일이 있는 폴더들 ('' = 저장소 맨 위)
    for (const e of hid.stdout.split('\0')) {
      if (e.length < 3) continue;
      const file = e.slice(2);
      if (/^[a-zS] /.test(e)) add(file);
      tracked.add(file);
      for (let d = path.posix.dirname(file); d !== '.' && !dirs.has(d); d = path.posix.dirname(d)) dirs.add(d);
    }
    // 무시 목록 파일(.gitignore)이 자기 자신까지 무시하게 적혀 있으면, 그 파일도 그것이 가린 새 파일도 `git status` 에 나오지 않는다
    //   → git 이 관리하는 파일이 있는 폴더의, git 이 관리하지 않는 .gitignore 는 직접 찾아 목록에 넣는다.
    //   (통째로 새로 생긴 폴더 안의 것은 보지 않는다: 도구들이 캐시 폴더에 "전부 무시"하는 .gitignore 를 같이 만든다)
    for (const d of dirs) {
      const file = d ? `${d}/.gitignore` : '.gitignore';
      if (!tracked.has(file) && fs.existsSync(path.join(base, file))) add(file);
    }
  }
  const head = git(['rev-parse', '-q', '--verify', 'HEAD^{commit}'], dir);
  m.head = head.status === 0 ? head.stdout.trim() : '';   // 아직 커밋이 없으면 빈 문자열
  m.add = add;
  return m;
}
// 작업자가 커밋까지 하면 바꾼 파일이 `git status` 에서 사라진다 → 실행 전후의 커밋이 다르면 그 사이에 달라진 파일도 "실행 뒤 목록"에 넣는다.
//   (실행 전부터 고쳐져 있던 파일을 커밋만 한 것은 서명이 그대로다 → changedOutside 가 넘긴다)
// 반환: 확인했으면 true, git 이 답하지 못했으면 false
function addCommitted(before, after) {
  if (!after.head || after.head === before.head) return true;   // 커밋이 없는 상태가 됐다면 파일은 전부 `git status` 에 나온다
  const r = before.head ? git(['diff', '--name-only', '-z', '--no-renames', '--no-ext-diff', '--no-textconv', before.head, after.head])
    : git(['ls-tree', '-r', '-z', '--name-only', '--full-tree', after.head]);
  if (r.status !== 0) return false;
  for (const file of r.stdout.split('\0')) if (file) after.add(file);
  return true;
}
// 작업자 실행 전후의 목록을 비교해, 범위 밖에서 바뀐 파일을 돌려준다.
//   · 실행 전 목록에 있던 파일: 지금 다시 재서 그때와 다르면 바뀐 것 (git 의 목록에서 사라졌는지는 보지 않는다 —
//     작업자가 커밋만 해도 목록에서 사라지지만 파일은 그대로다. 반대로 내용을 되돌렸으면 서명이 달라진다)
//   · 실행 뒤 목록에 새로 나타난 파일: 실행 전에는 깨끗했다는 뜻이므로 바뀐 것
function changedOutside(before, after, scope) {
  const res = scope.map((g) => L.globToRe(g));
  const here = realRoot();
  const out = [];
  for (const p of new Set([...before.keys(), ...after.keys()])) {
    const abs = path.resolve(here, p);
    if (before.has(p) && before.get(p) === sigOf(abs)) continue;
    if (p.startsWith(`${L.DIR}/`) && !/\/(config|router)\.json$/.test(p)) continue;   // 하네스가 실행 중에 쓰는 파일
    const names = isRepoDir(abs) ? [p, `${p}/`] : [p];   // 저장소인 폴더는 한 덩어리 → 범위가 그 폴더 전체(예: vendor/lib/**)를 덮으면 범위 안
    if (!p.startsWith('../') && names.some((q) => res.some((re) => re.test(q)))) continue;
    out.push(p);
  }
  return out.sort();
}
// 분리된 실행 프로세스 본체: `harness.cjs _exec <run>:<seq>` — 검증된 프로그램을 결정적으로 실행하고 결과를 상태에 남긴다
function execProgram(key) {
  const [run, seqStr] = String(key).split(':');
  const seq = Number(seqStr);
  const live = () => { const c = L.load(root); return c.state && c.state.run === run && c.state.seq === seq && c.state.status === 'running' ? c : null; };
  const start = live();
  if (!start) return;
  const flow = start.flow;
  const reg = L.registry(root);
  const cfg = L.config(root);
  const doneWhen = (flow.actions.program.program || {}).done_when || [];
  const ABORT = new Error('aborted');
  const halt = (msg) => Object.assign(new Error(msg), { halt: true });   // 사람에게 그대로 전할 중단 사유
  let known = start.state;   // 이 프로세스가 마지막으로 확인한 정상 상태 (상태 파일이 위조됐을 때 여기서 되살린다)
  const record = (h) => L.withLock(root, () => {   // 단계마다 history 에 남긴다 → check 가 한 줄씩 보여준다
    const c = live(); if (!c) throw ABORT;
    const histN = (c.state.histN || 0) + 1;
    known = { ...c.state, histN, history: [...(c.state.history || []), { seq, n: histN, at: new Date().toISOString(), ...h }].slice(-30) };
    L.saveState(root, known);
  });
  const setScope = (scope) => L.withLock(root, () => {   // 작업자의 hook 이 지킬 쓰기 범위
    const c = live(); if (!c) throw ABORT;
    const f = c.flow;
    if (scope) f.actions.program.write_scope = scope; else delete f.actions.program.write_scope;
    L.writeJson(L.sp(root, 'flow.json'), f);
  });
  const reportFile = (name) => `${L.DIR}/reports/${String(name).replace(/[^\w.-]/g, '_')}.txt`;
  // 작업자가 도는 동안 바뀌면 안 되는 파일들 (설정·규칙·흐름·프로그램, hook 등록, 플러그인 코드). 이 동안 이 파일들을 쓰는 것은 이 프로세스뿐이다
  //   git 의 hook 과 설정도 포함한다: .git 안은 `git status` 에 보이지 않지만, 거기 심은 hook 은 나중에 사용자의 git 명령에서 실행된다
  //   (경로를 묻는 것뿐이라 사용자 설정을 그대로 읽는다 → core.hooksPath 로 옮겨 둔 hook 폴더도 찾는다. rev-parse 는 설정의 명령을 실행하지 않는다)
  if (!GIT_BIN) GIT_BIN = findGit();   // 작업자를 돌리기 전에 정해 둔다
  const gitPath = (name) => { const r = spawnSync(GIT_BIN, ['-c', 'core.fsmonitor=false', 'rev-parse', '--git-path', name], { cwd: root, encoding: 'utf8' }); return r.status === 0 && r.stdout.trim() ? path.resolve(root, r.stdout.trim()) : null; };
  const gitHooks = gitPath('hooks'), gitConfig = gitPath('config');
  //   git 이 읽는 그 밖의 파일: 설정을 다른 곳에서 읽게 하는 것(commondir · config.worktree), 필터를 붙이는 것(info/attributes), 파일을 목록에서 숨기는 것(info/exclude · 전역 무시 목록)
  const expand = (p) => (p.startsWith('~/') ? path.join(require('os').homedir(), p.slice(2)) : p);
  const gitFiles = gitConfig ? ['commondir', 'config.worktree', 'info/attributes', 'info/exclude'].map(gitPath).filter(Boolean) : [];
  const ignoreFiles = gitConfig ? [path.join(process.env.XDG_CONFIG_HOME || path.join(require('os').homedir(), '.config'), 'git', 'ignore')]
    .concat(gitFlags().filter((x) => x.startsWith('core.excludesFile=')).map((x) => expand(x.slice('core.excludesFile='.length)))) : [];
  const listDir = (dir) => { try { return fs.readdirSync(dir).map((f) => path.join(dir, f)); } catch { return []; } };
  const guarded = () => [L.sp(root, 'config.json'), L.sp(root, 'router.json'), L.sp(root, 'flow.json'), L.sp(root, 'program.ts'), path.join(root, '.devin', 'hooks.v1.json'),
    path.join(L.PLUGIN_DIR, 'hooks.json'), path.join(L.PLUGIN_DIR, 'router.json'), ...listDir(path.join(L.PLUGIN_DIR, 'scripts')).filter((f) => f.endsWith('.cjs')),
    ...(gitConfig ? [gitConfig] : []), ...(gitHooks ? listDir(gitHooks) : []), ...gitFiles, ...ignoreFiles];
  const digest = () => new Map(guarded().map((f) => { try { return [f, crypto.createHash('sha1').update(fs.readFileSync(f)).digest('hex') + ':' + fs.statSync(f).mode]; } catch { return [f, '-']; } }));
  // 이 프로세스가 끝맺기 전에 흐름이 "완료"나 "중단"으로 바뀌어 있다면 상태 파일이 직접 고쳐진 것이다.
  //   완료: 이 프로세스만 남긴다 (사람의 proceed 는 handoff 뒤에만 가능하고, handoff 가 되면 이 프로세스는 정리된다).
  //   중단: 사람이 멈추면 멈춘 쪽이 곧바로 이 프로세스를 정리한다. 잠깐 기다려도 살아 있다면 정리하려는 시도가 없었던 것이다.
  // → run·seq 가 무엇으로 바뀌어 있든, 이 프로세스가 기억하는 정상 상태에서 "사람에게 넘김"으로 되돌린다.
  //   (handoff · 새 시도(running)로 바뀐 것은 hook 과 사람이 만드는 정상 경로이므로 건드리지 않는다)
  const ended = (st) => !st || st.status === 'done' || st.status === 'stopped';
  const tampered = () => {
    let st = L.readJson(L.sp(root, 'state.json'), null);
    if (st && st.status === 'stopped') { L.sleep(1500); st = L.readJson(L.sp(root, 'state.json'), null); }
    if (!ended(st)) return;
    L.withLock(root, () => {
      const cur = L.readJson(L.sp(root, 'state.json'), null);
      if (!ended(cur)) return;
      const f = { ...flow, actions: { program: { ...flow.actions.program } } };
      delete f.actions.program.write_scope;
      L.writeJson(L.sp(root, 'flow.json'), f);
      const turn = cur && typeof cur.lastPromptId === 'string' ? cur.lastPromptId : known.lastPromptId;   // "같은 턴에는 읽기만" 규칙이 지금 턴에 걸리게
      const s = F.handoff(f, { ...known, lastPromptId: turn, status: 'running', action: 'program' }, `실행 중에 상태 파일이 직접 수정됨 (${cur ? `"${cur.status}" 로 바뀌어 있었음` : '지워져 있었음'})`);
      L.saveState(root, { ...s, exec: null });
      L.log(root, { ev: 'program-end', status: 'handoff', why: 'state-tampered', found: cur ? cur.status : null });
    });
  };
  // 선택(config.worker_sandbox): 작업자의 프로세스 트리 전체를 OS 샌드박스에 넣는다 (macOS 의 sandbox-exec).
  //   하네스 상태 폴더 · 플러그인 폴더 · hook 등록 파일 · git 의 hook·설정에 쓸 수 없다. 샌드박스는 자식에게 물려지므로,
  //   작업자가 분리해 띄운 프로세스가 나중에 상태 파일을 고치는 것도 막힌다 (hook 의 검사와 실행 뒤 검사는 그대로 한다).
  //   규칙은 경로 기준이다 → 보호 대상의 상위 폴더 이름을 바꿨다가 되돌리는 식으로 피해 가지 못하게, 상위 폴더들 자체의 변경(이름 바꾸기·삭제)도 막는다.
  //   반환: 프로필 문자열 | null(끔) | undefined(켰지만 이 OS 에서는 쓸 수 없음)
  const sandboxProfile = () => {
    if (!cfg.worker_sandbox) return null;
    if (process.platform !== 'darwin' || !fs.existsSync('/usr/bin/sandbox-exec')) return undefined;
    // 실제 경로 (샌드박스 규칙은 심볼릭 링크를 푼 경로로 맞춰 본다). 아직 없는 경로는, 있는 데까지 풀고 나머지를 붙인다
    const real = (p) => {
      const rest = [];
      for (let d = path.resolve(p); ; d = path.dirname(d)) {
        try { return path.join(fs.realpathSync(d), ...rest); } catch { if (path.dirname(d) === d) return path.resolve(p); rest.unshift(path.basename(d)); }
      }
    };
    const q = (p) => JSON.stringify(p);
    const rr = real(root);
    try { fs.mkdirSync(path.join(rr, '.devin'), { recursive: true }); } catch { /* 있으면 그대로 */ }   // 없는 폴더는 "이름 바꿔 끼워 넣기"를 막을 수 없다 → 미리 만들어 둔다
    const dirs = [path.join(rr, L.DIR), real(L.PLUGIN_DIR)].concat(gitHooks ? [real(gitHooks)] : []);
    // 메인 세션(샌드박스 밖)이 읽고 그 안의 명령을 실행하는 프로젝트 설정: hook 등록, Devin 설정, MCP 서버 목록
    const files = ['hooks.v1.json', 'config.json', 'config.local.json', 'mcp_config.json', 'mcp_config.local.json'].map((f) => path.join(rr, '.devin', f))
      .concat([path.join(rr, '.mcp.json'), path.join(rr, 'mcp.json')], gitConfig ? [real(gitConfig)] : [], gitFiles.map(real), ignoreFiles.map(real));
    // 하네스 자신의 진입점(hook · CLI · MCP 서버)은 샌드박스 밖에서 `node …` 로 시작된다 → 그 `node` 가 무엇을 가리키는지를 작업자가 바꾸지 못하게 한다:
    //   PATH 의 폴더마다 `node` 라는 이름(그 폴더에 새로 심는 것 · 있는 것을 바꾸는 것), 지금의 node 실행 파일, 셸이 시작할 때 읽는 파일
    const home = require('os').homedir();
    const pathDirs = String(process.env.PATH || '').split(path.delimiter).map((d) => (path.isAbsolute(d) ? d : path.join(rr, d)));
    const nodes = pathDirs.flatMap((d) => [path.join(real(d), 'node'), real(path.join(d, 'node'))]).concat([real(process.execPath)]);
    const rc = ['.zshenv', '.zprofile', '.zshrc', '.zlogin', '.bash_profile', '.bash_login', '.bashrc', '.profile'];
    const shellFiles = [home, process.env.ZDOTDIR].filter(Boolean).flatMap((d) => rc.flatMap((n) => [path.join(real(d), n), real(path.join(d, n))]));
    const all = [...new Set([...files, ...nodes, ...shellFiles])];
    const above = new Set();
    for (const p of [...dirs, ...all]) for (let d = path.dirname(p); path.dirname(d) !== d; d = path.dirname(d)) above.add(d);
    const rules = [...dirs.map((p) => `(subpath ${q(p)})`), ...all.map((p) => `(literal ${q(p)})`), ...[...above].filter((p) => !all.includes(p)).map((p) => `(literal ${q(p)})`)];
    return `(version 1)(allow default)(deny file-write* ${rules.join(' ')})`;
  };
  // 작업자가 끝났는데도 남아 있는 그 작업자의 프로세스(백그라운드로 띄운 것)를 정리한다. 남겨 두면 검사가 끝난 뒤에 파일을 바꿀 수 있다.
  //   · 이 실행 프로세스와 같은 프로세스 그룹에 남은 것 (셸에서 `… &` 로 띄운 것은 여기에 든다)
  //   · 이 단계의 표식(환경변수)을 물려받은 것 — 환경변수를 읽을 수 있는 곳(Linux 의 /proc)에서만. macOS 는 다른 프로세스의 환경변수를 보여주지 않는다
  const sweep = () => {
    const left = new Set(J.markedPids(`STEP_HARNESS_WORKER=${run}:${seq}`));
    try {
      const r = spawnSync(J.PS, ['-axo', 'pid=,pgid='], { encoding: 'utf8', maxBuffer: 16 << 20 });
      for (const line of String(r.stdout || '').split('\n')) {
        const [pid, pgid] = line.trim().split(/\s+/).map(Number);
        if (pid && pgid === process.pid && pid !== process.pid && pid !== r.pid) left.add(pid);
      }
    } catch { /* ps 없음 */ }
    left.delete(process.pid);
    let n = 0;
    for (const pid of left) { try { process.kill(pid, 'SIGKILL'); n++; } catch { /* 이미 끝남 */ } }
    return n;
  };
  // 작업자와 게이트의 명령을 샌드박스로 감싼다 (게이트는 작업자가 쓴 코드를 실행한다 → 같은 제한 안에서 돌아야 한다)
  let profile = sandboxProfile();   // 문자열 | null(끔) | undefined(켰지만 쓸 수 없음 → 아래에서 멈춘다)
  if (profile === undefined) profile = false;
  if (profile) GIT_BOX = profile;   // 하네스가 돌리는 git 도 같은 샌드박스 안에서
  const boxed = (line) => {
    if (profile === false) throw halt('config.json 의 worker_sandbox 가 켜져 있지만 이 환경에서는 쓸 수 없음 (macOS 의 /usr/bin/sandbox-exec 필요). 끄거나 macOS 에서 실행');
    return profile ? `/usr/bin/sandbox-exec -p ${L.shq(profile)} ${J.SHELL} -c ${L.shq(line)}` : line;
  };
  const passed = new Set();   // 마지막 작업 이후에 하네스가 직접 돌려 통과를 확인한 게이트
  let n = 0;
  const host = {
    maxSteps: flow.max_steps,
    check(name) {
      if (!live()) throw ABORT;
      const cmd = Object.prototype.hasOwnProperty.call(reg.gates, name) ? L.gateCmd(reg.gates[name]) : '';
      if (!cmd) throw halt(`게이트 "${name}" 가 ${L.DIR}/config.json 에 없음 (실행 중에 설정이 바뀜)`);   // 빈 명령은 exit 0 이다 → 통과로 치면 안 된다
      const gateLine = boxed(cmd);
      const rel = reportFile(name);
      const file = path.join(root, rel);
      fs.mkdirSync(path.dirname(file), { recursive: true });
      const fd = fs.openSync(file, 'w');
      const r = spawnSync(J.SHELL, ['-c', gateLine], { cwd: root, stdio: ['ignore', fd, fd], timeout: flow.check_timeout_sec * 1000, killSignal: 'SIGKILL',
        env: { ...process.env, STEP_HARNESS: '1', STEP_HARNESS_FLOW: 'program', STEP_HARNESS_ACTION: name } });
      fs.closeSync(fd);
      const timedOut = !!(r.error && r.error.code === 'ETIMEDOUT');
      const exit = timedOut ? 124 : r.status == null ? 1 : r.status;
      if (timedOut) fs.appendFileSync(file, `\n[step-harness] gate timed out after ${flow.check_timeout_sec}s\n`);
      const text = fs.readFileSync(file, 'utf8').slice(-65536);
      const m = [...text.matchAll(/^HARNESS_ROUTE=([\w.:\/-]+)[ \t]*$/gm)].pop();
      try { fs.copyFileSync(file, L.sp(root, 'last-report.txt')); } catch { /* 무시 */ }
      const v = { pass: exit === 0, route: m ? m[1] : null, report: rel, exit };
      if (v.pass) passed.add(name); else passed.delete(name);
      record({ action: `check:${name}`, pass: v.pass, route: v.route, report: rel });
      return v;
    },
    skill(name, args, scope) { return worker('skill', name, [`Use the skill "${name}"` + (args ? ` with these arguments: ${args}` : '') + '. Follow it exactly and completely.'], scope); },
    agent(name, task, scope) { return worker('agent', name, [task], scope); },
  };
  function worker(kind, name, lines, scope) {
    if (!live()) throw ABORT;
    n += 1;
    passed.clear();   // 파일이 바뀔 수 있다 → 앞서 통과한 게이트도 다시 확인 대상
    const before = cfg.scope_check === false ? null : gitSnapshot();
    setScope(scope);
    const pf = L.sp(root, `prompt-${n}.txt`);
    fs.writeFileSync(pf, [...lines, `You may only write files under: ${scope.join(', ')}.`, 'Do not ask questions. When you are finished, stop.'].join('\n') + '\n');
    const line = boxed(reg.worker.replace(/\{prompt_file\}/g, L.shq(pf)).replace(/\{agent\}/g, kind === 'agent' ? L.shq(name) : "''").replace(/\{action\}/g, `${kind}-${n}`));
    const rel = `${L.DIR}/reports/worker-${n}.txt`;
    const file = path.join(root, rel);
    fs.mkdirSync(path.dirname(file), { recursive: true });
    const fd = fs.openSync(file, 'w');
    const limit = cfg.worker_timeout_sec || 3600;
    const sealed = digest();
    const r = spawnSync(J.SHELL, ['-c', line], { cwd: root, stdio: ['ignore', fd, fd], timeout: limit * 1000, killSignal: 'SIGKILL',
      env: { ...process.env, STEP_HARNESS_WORKER: `${run}:${seq}` } });
    fs.closeSync(fd);
    const stray = sweep();
    if (stray) fs.appendFileSync(file, `\n[step-harness] ${stray} process(es) left running by the worker were stopped\n`);
    const now = digest();
    const touched = [...new Set([...sealed.keys(), ...now.keys()])].filter((f) => sealed.get(f) !== now.get(f)).map((f) => path.relative(root, f));   // 새로 생긴 파일(hook 추가)도 포함
    if (touched.length) {   // 어떤 방법으로 고쳤든(셸 포함) 결과로 판단한다
      fs.appendFileSync(file, `\n[step-harness] protected files changed while the worker ran:\n${touched.map((p) => `  ${p}`).join('\n')}\n`);
      throw halt(`작업자(${kind}:${name})가 도는 동안 보호 대상 파일이 바뀜: ${touched.slice(0, 5).join(', ')} — 자세한 내용: ${rel}`);
    }
    setScope(null);
    if (r.error) fs.appendFileSync(file, `\n[step-harness] ${r.error.code === 'ETIMEDOUT' ? `worker timed out after ${limit}s` : `worker could not be started: ${r.error.message}`}\n`);
    const after = before && gitSnapshot();
    if (before && !(after && addCommitted(before, after))) {   // 확인할 수 없으면 통과로 치지 않는다 (색인을 망가뜨려 검사를 건너뛰게 하지 못하도록)
      fs.appendFileSync(file, '\n[step-harness] git could not report what changed after the worker ran (git status / git diff failed)\n');
      record({ action: `${kind}:${name}`, pass: false, route: 'scope-unknown', report: rel });
      throw halt(`작업자(${kind}:${name})가 돈 뒤에 git 으로 변경을 확인할 수 없음 — 범위 밖을 바꿨는지 알 수 없어 멈춤. 자세한 내용: ${rel}`);
    }
    const outside = after ? changedOutside(before, after, scope) : [];
    if (outside.length) {
      fs.appendFileSync(file, `\n[step-harness] files changed outside the scope (${scope.join(', ')}):\n${outside.map((p) => `  ${p}`).join('\n')}\n`);
      record({ action: `${kind}:${name}`, pass: false, route: 'out-of-scope', report: rel });
      throw halt(`작업자(${kind}:${name})가 허용 범위(${scope.join(', ')}) 밖의 파일을 바꿈: ${outside.slice(0, 5).join(', ')}${outside.length > 5 ? ` 외 ${outside.length - 5}개` : ''} — 자세한 내용: ${rel}`);
    }
    const v = { ok: r.status === 0, exit: r.status == null ? 1 : r.status };
    record({ action: `${kind}:${name}`, pass: v.ok, route: null, report: rel });
    return v;
  }
  let result;
  let failed = null;   // h.done() 뒤에 하네스가 직접 돌린 게이트가 실패했을 때: { gate, report }
  try {
    const { ast, errors } = P.compile(fs.readFileSync(L.sp(root, 'program.ts'), 'utf8'), reg);
    if (errors.length) throw new Error(errors.join('; '));   // 실행 사이에 등록부가 바뀐 경우
    const lost = doneWhen.filter((g) => !Object.prototype.hasOwnProperty.call(reg.gates, g) || !L.gateCmd(reg.gates[g]));
    if (lost.length) throw halt(`완료 조건의 게이트가 ${L.DIR}/config.json 에 없음: ${lost.join(', ')}`);
    result = P.run(ast, host);
    if (result.status === 'done') {   // "끝났다"는 프로그램의 주장일 뿐이다 → 정해진 게이트는 하네스가 직접 확인한다
      for (const g of doneWhen) {
        if (passed.has(g)) continue;
        const v = host.check(g);
        if (!v.pass) { failed = { gate: g, report: v.report }; break; }
      }
    }
  } catch (e) {
    if (e === ABORT) return tampered();
    result = { status: 'handoff', message: e.halt ? e.message : `프로그램 실행 오류: ${e.message}` };
  }
  if (!live()) return tampered();
  L.withLock(root, () => {
    const c = live(); if (!c) return;
    const f = c.flow;
    if (f.actions.program.write_scope) delete f.actions.program.write_scope;
    let s;
    if (failed) {   // 다시 프로그램을 내게 한다 (시도 횟수 +1, 한도를 넘으면 사람에게)
      L.writeJson(L.sp(root, 'flow.json'), f);
      s = F.enter(f, c.state, 'program');
      if (s.status === 'running') s.notDone = failed;
      else if (s.status === 'handoff') s.handoff.reason = `프로그램은 완료를 선언했지만 게이트 "${failed.gate}" 가 통과하지 못함 (${f.max_visits}회 시도) — ${failed.report}`;
    } else if (result.status === 'done') {
      f.done = result.message || f.done;
      L.writeJson(L.sp(root, 'flow.json'), f);
      s = F.enter(f, c.state, 'done');
    } else {
      L.writeJson(L.sp(root, 'flow.json'), f);
      s = F.handoff(f, c.state, result.message || '프로그램이 사람의 결정을 요청함');
    }
    L.saveState(root, { ...s, exec: null });
    L.log(root, { ev: 'program-end', status: s.status, message: result.message, failed });
  });
}

// 하네스가 띄운 작업자 안에서는 읽기 전용 명령만 쓸 수 있다 (작업자가 reset·resume·execute 로 흐름을 직접 바꾸지 못하게)
if (process.env.STEP_HARNESS_WORKER && cmd && !['next', 'status', 'search'].includes(cmd)) {
  out(`[step-harness] "${cmd}" is not available inside a harness worker (STEP_HARNESS_WORKER is set). Only the human or the main session can run it.`);
  process.exit(1);
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
  case 'search': search(); break;
  case 'execute': execute(); break;
  case '_exec': execProgram(argv[1]); break;
  case '_judge': J.runJudge(root, argv[1]); break;
  case 'install': case 'uninstall': case 'probe': case 'doctor': require('./doctor.cjs')[cmd](root, { argv, has, out }); break;
  default:
    out('usage: harness.cjs next | check [--wait N] | status | search [q] | execute \'<program>\' (or a quoted heredoc on stdin)\n       harness.cjs start <flow> k=v.. [--force] | lint <flow> | reset | resume [--proceed]\n' +
      '       harness.cjs run <flow> k=v.. --worker "<cmd with {prompt_file}>"\n       harness.cjs install [--fail-closed] | uninstall | probe on|off | doctor [--apply]');
    process.exit(cmd ? 1 : 0);
}
