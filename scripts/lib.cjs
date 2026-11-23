'use strict';
// step-harness 공통 모듈 — 경로, 상태 파일, 락, 범위 검사, 모델에게 보여줄 문구.
// hook 은 도구 호출마다 실행된다. 여기 있는 것은 전부 "파일 몇 개 읽고 끝"이어야 한다.
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const DIR = '.step-harness';
const PLUGIN_DIR = path.resolve(__dirname, '..');
const HARNESS_CLI = path.join(PLUGIN_DIR, 'scripts', 'harness.cjs');

// Devin 내장 도구 이름 (docs: hooks/lifecycle-hooks "Using the Matcher")
const DEVIN_TOOLS = new Set([
  'read', 'write', 'edit', 'apply_patch', 'notebook_read', 'notebook_edit', 'grep', 'glob',
  'exec', 'get_output', 'write_to_process', 'kill_shell', 'webfetch', 'todo_write', 'exit_plan_mode',
  'skill', 'run_subagent', 'read_subagent', 'request_scope', 'ask_user_question',
  'mcp_list_servers', 'mcp_list_tools', 'mcp_call_tool', 'mcp_read_resource',
]);
// 같은 플러그인을 Claude Code 에서 쓸 때의 도구 이름
const ALIASES = { Read: 'read', Write: 'write', Edit: 'edit', MultiEdit: 'edit', NotebookEdit: 'notebook_edit', Grep: 'grep', Glob: 'glob',
  Bash: 'exec', BashOutput: 'get_output', KillShell: 'kill_shell', Task: 'run_subagent', Agent: 'run_subagent', Skill: 'skill',
  WebFetch: 'webfetch', TodoWrite: 'todo_write', AskUserQuestion: 'ask_user_question' };
const normTool = (t) => ALIASES[t] || t;
const isKnownTool = (t) => DEVIN_TOOLS.has(t) || /^mcp__\w+__[\w-]+$/.test(t);

const FILE_MUTATORS = new Set(['edit', 'write', 'apply_patch', 'notebook_edit']);
const NEVER_PASSIVE = new Set([...FILE_MUTATORS, 'exec', 'write_to_process', 'kill_shell', 'skill', 'run_subagent', 'mcp_call_tool']);
const DEFAULT_PASSIVE = ['read', 'grep', 'glob', 'notebook_read', 'get_output', 'read_subagent', 'todo_write'];
const DEFAULT_CFG = { subagent_hooks: 'auto', auto_approve_cli: false, assume_done_on_stop: false, check_wait_sec: 30, wait: { prompt: 5, post: 8, stop: 20 } };

// ───────── 파일
function findRoot(hint) {
  if (process.env.STEP_HARNESS_ROOT) return path.resolve(process.env.STEP_HARNESS_ROOT);
  const base = path.resolve(hint || process.cwd());
  for (let d = base; ; d = path.dirname(d)) {
    if (fs.existsSync(path.join(d, DIR))) return d;
    if (fs.existsSync(path.join(d, '.git')) || path.dirname(d) === d) return base;   // 저장소 루트 위의 상태 폴더는 쓰지 않는다
  }
}
const sp = (root, ...f) => path.join(root, DIR, ...f);
function readJson(file, fallback) { try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return fallback; } }
function readStrict(file) {   // 없으면 null, 깨졌으면 예외 (→ hook 은 fail-closed)
  let text;
  try { text = fs.readFileSync(file, 'utf8'); } catch (e) { if (e.code === 'ENOENT') return null; throw e; }
  try { return JSON.parse(text); } catch (e) { throw new Error(`${path.basename(file)} is corrupt: ${e.message}`); }
}
function writeJson(file, data) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const tmp = `${file}.${process.pid}.${Date.now() % 100000}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(data, null, 2));
  fs.renameSync(tmp, file);
}
function append(root, file, entry) {
  try {
    fs.mkdirSync(path.join(root, DIR), { recursive: true });
    fs.appendFileSync(sp(root, file), JSON.stringify({ t: new Date().toISOString(), ...entry }) + '\n');
  } catch { /* 기록 실패로 세션을 막지 않는다 */ }
}
const log = (root, e) => append(root, 'log.jsonl', e);
const load = (root) => ({ flow: readStrict(sp(root, 'flow.json')), state: readStrict(sp(root, 'state.json')) });
const saveState = (root, s) => writeJson(sp(root, 'state.json'), s);

function config(root) {
  const c = readJson(sp(root, 'config.json'), {}) || {};
  return { ...DEFAULT_CFG, ...c, wait: { ...DEFAULT_CFG.wait, ...(c.wait || {}) } };
}
// 서브에이전트 안의 도구 호출이 hook 에 어떻게 보이는가: foreign(다른 session_id) | same(같은 id) | none(hook 이 안 돎)
// 자동으로 추측하지 않는다 (같은 폴더의 다른 세션과 구분할 수 없다). `harness.cjs doctor --apply` 로 확인해서 정한다. 기본은 same.
function subagentMode(root) {
  const c = config(root).subagent_hooks;
  return c === 'foreign' || c === 'none' ? c : 'same';
}
function learn(root, patch) { writeJson(sp(root, 'caps.json'), { ...(readJson(sp(root, 'caps.json'), {}) || {}), ...patch }); }

// ───────── 락 (hook 여러 개 + CLI 가 동시에 상태를 고치지 않게)
function sleep(ms) { if (ms > 0) Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms); }
function alive(pid) { if (!pid) return false; try { process.kill(pid, 0); return true; } catch (e) { return e.code === 'EPERM'; } }
function withLock(root, fn) {
  const f = sp(root, 'lock');
  let held = false;
  try { fs.mkdirSync(path.dirname(f), { recursive: true }); } catch { /* 아래에서 락 없이 진행 */ }
  const deadline = Date.now() + 3000;
  while (Date.now() < deadline) {
    try { fs.writeFileSync(f, String(process.pid), { flag: 'wx' }); held = true; break; } catch (e) {
      if (e.code !== 'EEXIST') break;
      try {
        const old = Date.now() - fs.statSync(f).mtimeMs > 10000;
        if (old || !alive(+fs.readFileSync(f, 'utf8'))) { fs.unlinkSync(f); continue; }
      } catch { continue; }
      sleep(12);
    }
  }
  try { return fn(); } finally { if (held) { try { fs.unlinkSync(f); } catch { /* 무시 */ } } }
}

// ───────── 경로·범위
function canon(p) {   // 심볼릭 링크를 풀어 비교 (없는 경로는 존재하는 부모까지만)
  let cur = path.resolve(p);
  const rest = [];
  for (;;) {
    try { return path.join(fs.realpathSync(cur), ...rest); } catch { /* 부모로 */ }
    const up = path.dirname(cur);
    if (up === cur) return path.resolve(p);
    rest.unshift(path.basename(cur));
    cur = up;
  }
}
function inside(root, dir, p) {
  const r = path.relative(canon(dir), canon(path.resolve(root, p)));
  return r === '' || (!r.startsWith('..') && !path.isAbsolute(r));
}
function globToRe(glob) {
  let g = glob.replace(/^\.\//, '');
  if (g.endsWith('/')) g += '**';
  let re = '';
  for (let i = 0; i < g.length; i++) {
    const c = g[i];
    if (c === '*') {
      if (g[i + 1] === '*') { i++; if (g[i + 1] === '/') { i++; re += '(?:.*/)?'; } else re += '.*'; } else re += '[^/]*';
    } else if (c === '?') re += '[^/]';
    else re += c.replace(/[.+^${}()|[\]\\]/g, '\\$&');
  }
  return new RegExp('^' + re + '$');
}
function inScope(root, globs, p) {
  const rel = path.relative(canon(root), canon(path.resolve(root, p))).split(path.sep).join('/');
  if (rel.startsWith('..') || path.isAbsolute(rel)) return false;
  return globs.some((g) => globToRe(g).test(rel));
}
function strings(v, out = []) {
  if (typeof v === 'string') out.push(v);
  else if (v && typeof v === 'object') for (const x of Object.values(v)) strings(x, out);
  return out;
}
const PATH_KEYS = ['file_path', 'path', 'filePath', 'target_file', 'filename', 'file', 'notebook_path', 'absolute_path'];
function targetPaths(tool, input) {   // 파일 변경 도구가 건드리는 경로. 알 수 없으면 null
  if (tool === 'apply_patch') {
    const out = [];
    for (const s of strings(input)) {
      for (const m of s.matchAll(/^\*\*\* (?:Add|Update|Delete) File: (.+)$/gm)) out.push(m[1].trim());
      for (const m of s.matchAll(/^\*\*\* Move to: (.+)$/gm)) out.push(m[1].trim());
      for (const m of s.matchAll(/^\+\+\+ (?:b\/)?(\S+)/gm)) if (m[1] !== '/dev/null') out.push(m[1]);
    }
    return out.length ? out : null;
  }
  for (const k of PATH_KEYS) if (input && typeof input[k] === 'string' && input[k]) return [input[k]];
  return null;
}
const READ_ONLY_CMD = /^\s*(cat|head|tail|less|more|wc|ls|grep|rg|jq|stat|file)\b[^;&|<>`$]*$/;
// 하네스 자신의 파일(.step-harness/, 흐름 진행 중에는 플러그인 폴더도)을 고치려는 호출인가
function touchesHarness(root, tool, input, active) {
  const dirs = [path.join(root, DIR)].concat(active ? [PLUGIN_DIR] : []);
  if (FILE_MUTATORS.has(tool)) {
    const t = targetPaths(tool, input);
    if (t) return t.some((p) => dirs.some((d) => inside(root, d, p)));
    return strings(input).some((s) => s.length < 4096 && s.includes(DIR));
  }
  if (tool === 'exec' || tool === 'write_to_process') {
    const s = strings(input).join('\n');
    return (s.includes(DIR) || (active && s.includes(PLUGIN_DIR))) && !READ_ONLY_CMD.test(s);
  }
  return false;
}
// 모델이 부를 수 있는 하네스 CLI 인가: `node <이 플러그인의 harness.cjs> next|check|status` 단독 실행만
let cliReal = null;
function harnessCmd(root, cmd) {
  if (typeof cmd !== 'string') return null;
  const m = cmd.match(/^\s*node\s+(?:"([^"`$;&|<>]*harness\.cjs)"|'([^'`$;&|<>]*harness\.cjs)'|([^\s"'`$;&|<>]*harness\.cjs))\s+(next|check|status)(?:\s+--wait\s+\d{1,3})?\s*$/);
  if (!m) return null;
  try {
    cliReal = cliReal || fs.realpathSync(HARNESS_CLI);
    if (fs.realpathSync(path.resolve(root, m[1] || m[2] || m[3])) !== cliReal) return null;
  } catch { return null; }
  return m[4];
}
const SHELL_META = /[;&|<>`\n]|\$\(/;
function execAllowed(a, cmd) {
  if (!Array.isArray(a.exec_allow)) return true;
  if (typeof cmd !== 'string' || SHELL_META.test(cmd)) return false;
  return a.exec_allow.some((re) => new RegExp(re).test(cmd.trim()));
}
// 쓰기 범위·명령 범위 위반 여부. 위반이면 { why, detail }
function scopeViolation(root, a, tool, input) {
  if (FILE_MUTATORS.has(tool) && Array.isArray(a.write_scope)) {
    const t = targetPaths(tool, input);
    if (!t) return { why: 'scope-unknown', detail: `cannot determine which file ${tool} writes; writes are limited to ${a.write_scope.join(', ')}.` };
    const bad = t.find((p) => !inScope(root, a.write_scope, p));
    if (bad) return { why: 'write-scope', detail: `${bad} is outside the writable paths (${a.write_scope.join(', ')}).` };
  }
  if (tool === 'exec' && !execAllowed(a, input && input.command)) {
    return { why: 'exec-scope', detail: `this command is not in the allowed list (${a.exec_allow.join(' | ')}); run one plain command without ; & | > $( ).` };
  }
  return null;
}

// ───────── 파라미터 대조: 키가 있으면 그 값끼리, 없으면(실제 스키마의 키 이름이 다를 때) 아무 필드 값이라도 같으면 일치
function same(a, b) {
  if (typeof a === 'string' && typeof b === 'string') return a.trim() === b.trim();
  return JSON.stringify(a) === JSON.stringify(b);
}
function anyValue(obj, v) {
  if (same(obj, v)) return true;
  if (obj && typeof obj === 'object') return Object.values(obj).some((x) => anyValue(x, v));
  return false;
}
function paramsMismatch(expected, input, skip) {
  const bad = [];
  for (const [k, v] of Object.entries(expected || {})) {
    if (skip && skip.includes(k)) continue;
    const has = input && Object.prototype.hasOwnProperty.call(input, k);
    if (!(has ? same(input[k], v) : anyValue(input, v))) bad.push(k);
  }
  return bad;
}

const kind = (a) => (a.tool ? 'call' : a.work ? 'work' : 'judge');
function effectivePassive(flow, a) {
  const s = new Set(flow.passive || DEFAULT_PASSIVE);
  for (const t of a.deny || []) s.delete(t);
  return s;
}
function fingerprint(ev) {
  return crypto.createHash('sha1').update([ev.hook_event_name, ev.session_id, ev.prompt_id, ev.tool_name, JSON.stringify(ev.tool_input || null)].join('|')).digest('hex').slice(0, 16);
}
// hook 이 플러그인과 프로젝트 양쪽에 설치돼 있으면 같은 이벤트가 두 번 온다 (src 가 다른 두 벌).
// 그때만 "중복"으로 보고 직전 판정을 그대로 돌려준다. 같은 설치본이 같은 호출을 또 받은 것은 진짜 반복 호출이므로 새로 판정한다.
function isDup(state, ev, src) {
  const fp = fingerprint(ev);
  const prev = state.lastEvent;
  const dup = !!prev && prev.fp === fp && prev.seq === state.seq && prev.src !== src && Date.now() - prev.t < 1500;
  if (!dup) state.lastEvent = { fp, seq: state.seq, src, t: Date.now(), allowed: undefined };
  return dup;
}
const shq = (s) => `'${String(s).replace(/'/g, `'\\''`)}'`;

// ───────── 모델에게 보여줄 문구 (짧게, 매번 같은 형식, 할 일은 하나)
const cli = (sub) => `node "${HARNESS_CLI}" ${sub}`;
function handoffQuestion(flow, state) {
  const tpl = flow.handoff_question || '[{flow}] {reason}. 어떻게 할까요? "retry"(다시 시도) / "proceed"(통과로 처리하고 계속) / "stop"(중단) 중 하나로 답해 주세요.';
  return tpl.replace('{flow}', flow.flow).replace('{reason}', (state.handoff && state.handoff.reason) || '사람의 결정이 필요함');
}
function renderNext(flow, state) {
  if (!flow || !state) return '';
  const head = `[step-harness] flow=${flow.flow}`;
  if (state.status === 'done') return `${head} DONE: ${flow.done || 'all checks passed'}. Tell the user this result in one or two sentences, then stop.`;
  if (state.status === 'handoff') {
    return [`${head} PAUSED — a human decision is required.`,
      'Do not modify anything and do not run commands. Reply to the user with exactly this message, then stop:',
      `  ${handoffQuestion(flow, state)}`].join('\n');
  }
  if (state.status !== 'running') return '';
  const a = flow.actions[state.action];
  const k = kind(a);
  const fresh = (x) => !!x && x.seq === state.seq;
  const tag = `${head} action=${a.id}` + (k === 'judge' ? '' : ` (attempt ${(state.visits || {})[a.id] || 1}/${flow.max_visits})`);
  const checkCall = ['  tool: exec', `  params: ${JSON.stringify({ command: cli('check') })}`];
  const last = (state.history || []).slice(-1)[0];   // 왜 다시 하라는지 한 줄 (같은 지시가 반복돼 보이지 않게)
  const why = last && !last.pass ? [`The last verification FAILED (${last.action}${last.route ? `, route=${last.route}` : ''})${last.report ? `; details: ${last.report}` : ''}. So:`] : [];
  if (k === 'judge' || (k === 'call' && fresh(state.receipt)) || (k === 'work' && state.workDone)) {
    return [tag, 'NEXT_ACTION — call exactly this tool with exactly these params, now:', ...checkCall,
      'It prints the verdict and the next action. If it prints STILL RUNNING, call it again. Everything else is blocked.'].join('\n');
  }
  if (k === 'call') {
    if (fresh(state.inFlight)) return `${tag}\nThe NEXT_ACTION (${a.tool}) is in progress. Wait for it to return. Do not do its work yourself.`;
    return [tag, ...why, 'NEXT_ACTION — call exactly this tool with exactly these params, exactly once, now:',
      `  tool: ${a.tool}`, `  params: ${JSON.stringify(a.params || {})}`,
      'Everything else is blocked (read-only tools excepted). Do not edit files or run commands yourself. Do not judge the result yourself; the harness verifies it.'].join('\n');
  }
  const lim = [`Allowed tools: ${(a.allow || []).join(', ') || '(none)'} (+ read-only tools).`];
  if (a.write_scope) lim.push(`Writable paths: ${a.write_scope.join(', ')}.`);
  if (a.exec_allow) lim.push(`Allowed commands (regex): ${a.exec_allow.join(' | ')}.`);
  return [tag, ...why, 'WORK — do this yourself, now:', `  ${a.work}`, lim.join(' '),
    'When you are finished, call exactly this tool with exactly these params:', ...checkCall,
    'Do not judge the result yourself; the harness verifies it.'].join('\n');
}

module.exports = {
  DIR, PLUGIN_DIR, HARNESS_CLI, DEVIN_TOOLS, FILE_MUTATORS, NEVER_PASSIVE, DEFAULT_PASSIVE,
  normTool, isKnownTool, findRoot, sp, readJson, writeJson, append, log, load, saveState, config, subagentMode, learn,
  sleep, alive, withLock, inside, inScope, globToRe, targetPaths, touchesHarness, harnessCmd, scopeViolation,
  paramsMismatch, kind, effectivePassive, isDup, shq, cli, handoffQuestion, renderNext,
};
