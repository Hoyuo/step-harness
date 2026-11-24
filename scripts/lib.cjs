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
  'web_search', 'tool_search', 'task_note', 'lsp',   // 다른 호스트에만 있는 읽기·기록용 도구 (아래 ALIASES)
]);
// 다른 호스트(Claude Code)의 도구 이름 → 여기서 쓰는 이름. hook 은 이 이름으로 판단하므로 호스트가 달라도 규칙은 같다
const ALIASES = { Read: 'read', Write: 'write', Edit: 'edit', MultiEdit: 'edit', NotebookEdit: 'notebook_edit', NotebookRead: 'notebook_read', Grep: 'grep', Glob: 'glob',
  Bash: 'exec', BashOutput: 'get_output', TaskOutput: 'get_output', KillShell: 'kill_shell', Task: 'run_subagent', Agent: 'run_subagent', Skill: 'skill',
  WebFetch: 'webfetch', WebSearch: 'web_search', TodoWrite: 'todo_write', AskUserQuestion: 'ask_user_question', ToolSearch: 'tool_search', LSP: 'lsp',
  ExitPlanMode: 'exit_plan_mode', EnterPlanMode: 'exit_plan_mode',
  TaskCreate: 'task_note', TaskUpdate: 'task_note', TaskList: 'task_note', TaskGet: 'task_note',
  ListMcpResourcesTool: 'mcp_list_tools', ReadMcpResourceTool: 'mcp_read_resource' };
const normTool = (t) => ALIASES[t] || t;
const isKnownTool = (t) => DEVIN_TOOLS.has(t) || /^mcp__\w+__[\w-]+$/.test(t);

const FILE_MUTATORS = new Set(['edit', 'write', 'apply_patch', 'notebook_edit']);
const NEVER_PASSIVE = new Set([...FILE_MUTATORS, 'exec', 'write_to_process', 'kill_shell', 'skill', 'run_subagent', 'mcp_call_tool']);
const DEFAULT_PASSIVE = ['read', 'grep', 'glob', 'notebook_read', 'get_output', 'read_subagent', 'todo_write', 'tool_search', 'task_note', 'lsp'];
// plan: 'always' = 이 프로젝트에서는 무엇이든 바꾸려면 먼저 계획(프로그램)을 내야 한다 / 'prefix' = "프로그램: …" 처럼 규칙에 맞는 프롬프트에서만
const DEFAULT_CFG = { subagent_hooks: 'auto', auto_approve_cli: false, assume_done_on_stop: false, check_wait_sec: 30, wait: { prompt: 5, post: 8, stop: 20 }, plan: 'always' };

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
  const me = `${process.pid}:${Date.now()}:${Math.random().toString(36).slice(2, 8)}`;   // 내 락임을 확인할 표식 (맨 앞은 pid)
  let held = false;
  try { fs.mkdirSync(path.dirname(f), { recursive: true }); } catch { /* 아래에서 락 없이 진행 */ }
  const deadline = Date.now() + 3000;
  while (Date.now() < deadline) {
    try { fs.writeFileSync(f, me, { flag: 'wx' }); held = true; break; } catch (e) {
      if (e.code !== 'EEXIST') break;
      try {
        const seen = fs.readFileSync(f, 'utf8');
        if (Date.now() - fs.statSync(f).mtimeMs > 10000 || !alive(parseInt(seen, 10))) {
          // 죽은 락을 치운다. 여러 프로세스가 동시에 치우려 할 수 있다 → 이름을 바꿔 가져온 뒤, 방금 본 바로 그 락일 때만 버린다
          const grave = `${f}.${process.pid}.stale`;
          fs.renameSync(f, grave);
          if (fs.readFileSync(grave, 'utf8') !== seen) { try { fs.linkSync(grave, f); } catch { /* 그 사이 새 락이 생겼다 */ } }   // 남의 새 락을 집었다 → 되돌린다
          try { fs.unlinkSync(grave); } catch { /* 무시 */ }
          continue;
        }
      } catch { continue; }
      sleep(12);
    }
  }
  try { return fn(); } finally {
    if (held) { try { if (fs.readFileSync(f, 'utf8') === me) fs.unlinkSync(f); } catch { /* 무시 */ } }   // 내 락일 때만 푼다 (너무 오래 걸려 빼앗겼다면 남의 락이다)
  }
}

// ───────── 경로·범위
// 심볼릭 링크를 풀고, 디스크에 저장된 실제 대소문자로 맞춰 비교한다 (없는 경로는 존재하는 부모까지만).
// macOS·Windows 는 대소문자를 구분하지 않는다: ".STEP-HARNESS/state.json" 은 ".step-harness/state.json" 과 같은 파일이다.
// (JS 구현인 fs.realpathSync 는 입력한 대소문자를 그대로 돌려준다 → native 를 쓴다)
const realpath = fs.realpathSync.native || fs.realpathSync;
function canon(p) {
  let cur = path.resolve(p);
  const rest = [];
  for (;;) {
    try { return path.join(realpath(cur), ...rest); } catch { /* 부모로 */ }
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
// ───────── 읽기만 하는 셸 명령인가 (계획 없이 해도 되는 것 · 하네스 파일을 읽기만 하는 것)
// 셸이 읽는 대로 낱말을 나눈다: 따옴표와 백슬래시를 벗긴 뒤의 낱말로 판단해야 한다 (`find . "-exec" …` 는 셸에게 -exec 다).
// 읽기 전용으로 볼 수 없는 문법이 하나라도 있으면 null: 따옴표 밖의 ; & < > ( ) { } · 작은따옴표 밖의 $ 와 ` · 줄바꿈 · 닫히지 않은 따옴표.
// 반환: 파이프로 나뉜 명령들 [[낱말, …], …]
function shellWords(cmd) {
  const cmds = [[]];
  let cur = '', has = false, q = null;
  const push = () => { if (has) cmds[cmds.length - 1].push(cur); cur = ''; has = false; };
  for (let i = 0; i < cmd.length; i++) {
    const c = cmd[i];
    if (c === '\n' || c === '\r') return null;
    if (q === "'") { if (c === "'") q = null; else cur += c; continue; }
    if (c === '\\') {
      if (i + 1 >= cmd.length) return null;
      if (q === '"' && !'"\\$`'.includes(cmd[i + 1])) { cur += c; continue; }   // 큰따옴표 안에서는 이 넷 앞에서만 지워진다
      cur += cmd[++i]; has = true; continue;
    }
    if (c === '$' || c === '`') return null;
    if (q === '"') { if (c === '"') q = null; else cur += c; continue; }
    if (c === "'" || c === '"') { q = c; has = true; continue; }
    if (';&<>(){}'.includes(c)) return null;
    if (c === '|') { push(); if (!cmds[cmds.length - 1].length) return null; cmds.push([]); continue; }
    if (c === ' ' || c === '\t') { push(); continue; }
    if ('*?['.includes(c)) cmds[cmds.length - 1].glob = true;   // 따옴표 밖의 와일드카드: 셸이 파일 이름으로 바꿔 넣는다 (이름이 "-delete" 인 파일이면 옵션이 된다)
    cur += c; has = true;
  }
  if (q) return null;
  push();
  return cmds.every((w) => w.length) ? cmds : null;
}
// 목록에 없는 명령은 전부 "바꿀 수 있는 것"으로 본다 (모르는 것을 읽기 전용으로 치지 않는다).
// 옵션은 "그 글자들로 시작하는가"로 본다: 줄여 쓴 옵션(git 은 --outpu 도 --output 으로 받는다)을 놓치지 않도록.
const READ_PLAIN = new Set(['cat', 'head', 'tail', 'wc', 'ls', 'grep', 'jq', 'stat', 'pwd', 'which', 'cut', 'nl', 'diff', 'basename', 'dirname', 'realpath', 'echo']);
const GIT_READ = new Set(['status', 'log', 'diff', 'show', 'rev-parse', 'ls-files', 'blame', 'describe']);
const GIT_BRANCH_FLAGS = new Set(['-a', '-r', '-v', '-vv', '--list', '--show-current']);
function readOnlyCmd(w) {
  const args = w.slice(1);
  const any = (re) => args.some((x) => re.test(x));
  if (w.glob && !READ_PLAIN.has(w[0])) return false;   // 위험한 옵션이 있는 명령에는 와일드카드를 받지 않는다 (파일 이름이 그 옵션이 될 수 있다)
  switch (w[0]) {
    case 'sort': case 'uniq': return args.every((x) => /^-[a-np-zA-Z0-9]+$/.test(x));   // 입력을 걸러 내기만 (파일 인자나 -o 가 있으면 아니다)
    case 'date': return !any(/^(-s|--set)/);
    case 'file': return !any(/^(-[A-Za-z]*C|--comp)/);                  // -C 는 파일을 만든다
    case 'rg': return !any(/^--(pre|hostname-bin)/);                    // 다른 명령을 실행한다
    case 'find': return !any(/^-(exec|ok|delete|fprint|fls)/);          // 명령을 실행하거나 파일을 지우고 쓴다
    case 'git':
      if (any(/^--ou/)) return false;                                    // --output: 결과를 파일에 쓴다
      if (GIT_READ.has(w[1])) return true;
      if (w[1] === 'branch') return w.slice(2).every((x) => GIT_BRANCH_FLAGS.has(x));   // 이름을 주면 브랜치를 만든다
      if (w[1] === 'remote') return w.length === 2 || (w.length === 3 && w[2] === '-v');
      return false;
    default: return READ_PLAIN.has(w[0]);
  }
}
function readOnlyShell(cmd) {
  if (typeof cmd !== 'string') return false;
  const cmds = shellWords(cmd);
  return !!cmds && cmds.every(readOnlyCmd);
}
// 흐름이 없을 때("질문에는 그냥 답한다") 이 호출은 계획 없이 해도 되는가. 읽기만 한다고 아는 도구만 그렇다.
// 그 밖의 도구(파일 수정 · 셸 · 스킬 · 서브에이전트 · MCP 도구 · 모르는 도구)는 무언가를 바꿀 수 있다고 보고 계획을 요구한다.
const FREE_TOOLS = new Set([...DEFAULT_PASSIVE, 'webfetch', 'web_search', 'mcp_list_servers', 'mcp_list_tools', 'mcp_read_resource', 'ask_user_question', 'exit_plan_mode']);
function needsPlan(root, tool, input) {
  if (tool === 'exec') return !readOnlyShell(input && input.command);
  if (FREE_TOOLS.has(tool)) return false;
  const c = config(root);
  return ![].concat(c.explore_tools || [], c.passive_tools || []).includes(tool);
}
// 하네스 자신의 파일(.step-harness/, 흐름 진행 중에는 플러그인 폴더도)을 고치려는 호출인가
function touchesHarness(root, tool, input, active) {
  const dirs = [path.join(root, DIR)].concat(active ? [PLUGIN_DIR] : []);
  if (FILE_MUTATORS.has(tool)) {
    const t = targetPaths(tool, input);
    if (t) return t.some((p) => dirs.some((d) => inside(root, d, p)));
    return strings(input).some((s) => s.length < 4096 && s.toLowerCase().includes(DIR));
  }
  if (tool === 'exec' || tool === 'write_to_process') {   // 문자열 검사는 대소문자를 가리지 않는다 (위와 같은 이유)
    const s = strings(input).join('\n');
    const low = s.toLowerCase();
    return (low.includes(DIR) || (active && low.includes(PLUGIN_DIR.toLowerCase()))) && !(tool === 'exec' && readOnlyShell(input && input.command));
  }
  return false;
}
// 모델이 부를 수 있는 하네스 CLI 인가. 허용 형태 (그 외 셸 문법은 전부 거부):
//   node <이 플러그인의 harness.cjs> next|check|status|plan [--wait N]
//   node <…harness.cjs> search ['검색어']
//   node <…harness.cjs> execute '<프로그램>'          (작은따옴표 안은 셸이 해석하지 않는다)
//   node <…harness.cjs> execute <<'EOF' … EOF          (따옴표 친 heredoc. 본문에 종료 줄이 또 있으면 거부)
// 낱말 사이는 공백·탭만 받는다. 줄바꿈을 받으면 셸에서는 다음 줄이 별개의 명령이 된다 (`… search\nmake` → make 실행).
let cliReal = null;
const SP = '[ \\t]+';
const CLI_PATH = String.raw`node${SP}(?:"([^"\`$;&|<>\\\n]*harness\.cjs)"|'([^'\`$;&|<>\n]*harness\.cjs)'|([^\s"'\`$;&|<>\\*?~(){}\[\]#!]*harness\.cjs))`;
const PAD = '[ \\t\\n]*';   // 명령 앞뒤: 공백·탭·빈 줄만
const RE_SIMPLE = new RegExp(String.raw`^${PAD}${CLI_PATH}${SP}(next|check|status|plan)(?:${SP}--wait${SP}\d{1,3})?${PAD}$`);
const RE_SEARCH = new RegExp(String.raw`^${PAD}${CLI_PATH}${SP}(search)(?:${SP}'[^'\n]*'|${SP}[\w.-]+)?${PAD}$`);
const RE_EXEC_ARG = new RegExp(String.raw`^${PAD}${CLI_PATH}${SP}(execute)${SP}'[^']*'${PAD}$`);
// heredoc 종료 줄은 종료어만 있어야 한다 (뒤에 공백이 붙으면 셸은 그 줄에서 끝내지 않는다 → 본문에 섞여 들어간다)
const RE_EXEC_DOC = new RegExp(String.raw`^${PAD}${CLI_PATH}${SP}(execute)[ \t]*<<[ \t]*'(\w+)'[ \t]*\n([\s\S]*)\n\5\n*$`);
function harnessCmd(root, cmd) {
  if (typeof cmd !== 'string') return null;
  let m = cmd.match(RE_SIMPLE) || cmd.match(RE_SEARCH) || cmd.match(RE_EXEC_ARG);
  if (!m) {
    m = cmd.match(RE_EXEC_DOC);
    if (m && m[6].split('\n').some((l) => l === m[5])) m = null;   // 본문 중간의 종료 줄 = heredoc 뒤에 다른 명령이 붙는다
  }
  if (!m) return null;
  const file = m[1] || m[2] || m[3];
  if (!path.isAbsolute(file)) return null;   // 상대 경로: hook 은 프로젝트 루트 기준으로, 셸은 그때의 작업 폴더 기준으로 푼다 → 다른 파일이 실행될 수 있다
  try {
    cliReal = cliReal || fs.realpathSync(HARNESS_CLI);
    if (fs.realpathSync(file) !== cliReal) return null;
  } catch { return null; }
  return m[4];
}
// 이 플러그인의 MCP 서버 도구인가 (scripts/mcp.cjs — 서버 이름 step-harness / step_harness. Devin 의 도구 이름은 mcp__<서버>__<도구>.
// 플러그인이 띄운 서버에 접두사를 붙이는 클라이언트(mcp__plugin_<플러그인>_<서버>__<도구>)도 받는다)
const isHarnessMcp = (tool) => /^mcp__(?:plugin_[\w-]+?_)?step[-_]?harness__(plan|search|execute|check)$/.test(String(tool));
const SHELL_META = /[;&|<>`\n]|\$\(/;
function execAllowed(a, cmd) {
  if (!Array.isArray(a.exec_allow)) return true;
  if (typeof cmd !== 'string' || SHELL_META.test(cmd)) return false;
  return a.exec_allow.some((re) => new RegExp(`^(?:${re})`).test(cmd.trim()));   // 명령의 처음부터 맞아야 한다 ("rm -rf x #허용된 명령" 같은 꼬리로는 통과하지 못한다)
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

const kind = (a) => (a.program ? 'program' : a.tool ? 'call' : a.work ? 'work' : 'judge');
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
// 도구 이름은 호스트마다 다르다 (Devin: exec · skill · run_subagent / Claude Code: Bash · Skill · Agent). 지시문에는 둘 다 적는다
const OTHER_NAMES = Object.entries(ALIASES).reduce((m, [alias, t]) => { (m[t] = m[t] || []).push(alias); return m; }, {});
const toolName = (t) => (OTHER_NAMES[t] ? `${t} (${OTHER_NAMES[t].join(' / ')} on some hosts)` : t);
const runCheck = () => ['NEXT_ACTION — run exactly this shell command, now (one command, nothing before or after it):', `  ${cli('check')}`];
// 계획 단계의 프롬프트: 자연어 지시 대신 "타입이 있는 API + 제출 형식" (Code Mode)
function renderProgram(flow, state, tag, why) {
  const P = require('./program.cjs');
  const a = flow.actions[state.action];
  const reg = registry(flow.root || process.cwd());
  const doneWhen = a.program.done_when || [];
  const has = (o) => Object.keys(o || {}).length > 0;
  const rej = state.rejected ? [`Your last program was REJECTED (${state.rejects}/${flow.max_visits}):`, ...state.rejected.map((e) => `  - ${e}`), 'Fix these and submit the whole program again.'] : [];
  const nd = state.notDone ? [`Your last program returned h.done(), but the required check "${state.notDone.gate}" FAILED (details: ${state.notDone.report}). The task is not finished — submit a new program that fixes it.`] : [];
  return [tag, ...(nd.length ? nd : why), ...rej,
    `TASK: ${a.program.task || '(see the user message)'}`,
    'PLAN FIRST — do not change anything yet. Write ONE program against this API. The harness checks it, then takes you through it one step at a time (each step arrives as a NEXT_ACTION; nothing else is allowed while it runs):',
    '```ts', P.declaration(reg, doneWhen), '```',
    'h.work(task, { scope }) = a piece of work you do yourself when its step comes. Split the task into a few steps and write each one as a full instruction. scope = the files that step may write' +
      (Array.isArray(reg.writable) ? '.' : ' (relative globs that start with a real directory or file name of this project, e.g. "lib/**").'),
    ...(has(reg.gates) ? ['h.check(gate) = the harness runs that registered check and returns r.pass · r.route · r.report (path of its output file). Use it to verify your work.'] : []),
    ...(has(reg.skills) || has(reg.agents) ? ['h.skill / h.agent = when the step comes you invoke that skill / start that subagent exactly once; it may write only inside scope. It cannot see this conversation: put everything it needs into its args/task.'] : []),
    'Grammar: exactly one `async (h) => { … }`. Only const · if/else · for (const i of h.retries(N)) · break/continue · return · await h.<method>(…) · === !== && || ! · template literals.',
    'Every path must end with `return h.done("…")` or `return h.handoff("…")`. No let/while/functions/imports/other calls, no ternary, no + or < >.',
    'Shape (adapt it; names and scopes must fit the API above):',
    '```ts', P.example(reg, doneWhen), '```',
    'NEXT_ACTION — submit it by running exactly this shell command, now (the program goes between the EOF lines; one command, nothing before or after it):',
    `  node "${HARNESS_CLI}" execute <<'EOF'`, '  <program>', '  EOF',
    ...(has(reg.gates) || has(reg.skills) || has(reg.agents) ? [`Optional, before that: ${cli('search')} lists what is registered, with descriptions.`] : []),
    'Until a program is accepted, everything except read-only tools is blocked.',
  ].join('\n');
}
// 프로그램 API 에 노출할 등록부 (.step-harness/config.json): gates · skills · agents · writable
function registry(root) {
  const c = config(root);
  return { gates: c.gates || {}, skills: c.skills, agents: c.agents, writable: c.writable };
}
const gateCmd = (g) => (typeof g === 'string' ? g : (g && typeof g.cmd === 'string' ? g.cmd : '')).trim();
function renderNext(flow, state) {
  if (!flow || !state) return '';
  const head = `[step-harness] flow=${flow.flow}`;
  if (state.status === 'done') return `${head} DONE: ${String(flow.done || 'all checks passed').replace(/[\s.。]+$/, '')}. Tell the user this result in one or two sentences, then stop.`;
  if (state.status === 'handoff') {
    return [`${head} PAUSED — a human decision is required.`,
      'Do not modify anything and do not run commands. Reply to the user with exactly this message, then stop:',
      `  ${handoffQuestion(flow, state)}`].join('\n');
  }
  if (state.status !== 'running') return '';
  const a = flow.actions[state.action];
  const k = kind(a);
  const fresh = (x) => !!x && x.seq === state.seq;
  const tag = a.step ? `${head} step ${a.step.n}: ${a.step.label}`
    : `${head} action=${a.id}` + (k === 'judge' ? '' : ` (attempt ${(state.visits || {})[a.id] || 1}/${flow.max_visits})`);
  const last = (state.history || []).slice(-1)[0];   // 왜 다시 하라는지 한 줄 (같은 지시가 반복돼 보이지 않게)
  const why = last && !last.pass ? [`The last verification FAILED (${last.action}${last.route ? `, route=${last.route}` : ''})${last.report ? `; details: ${last.report}` : ''}. So:`] : [];
  if (k === 'program') return renderProgram(flow, state, tag, why);
  if (k === 'judge' || (k === 'call' && fresh(state.receipt)) || (k === 'work' && state.workDone)) {
    return [tag, ...runCheck(), 'It prints the verdict and the next action. If it prints STILL RUNNING, run it again. Everything else is blocked.'].join('\n');
  }
  if (k === 'call') {
    if (fresh(state.inFlight)) return `${tag}\nThe NEXT_ACTION (${a.tool}) is in progress. Wait for it to return. Do not do its work yourself.`;
    return [tag, ...why, 'NEXT_ACTION — call exactly this tool with exactly these values, exactly once, now:',
      `  tool: ${toolName(a.tool)}`, `  params: ${JSON.stringify(a.params || {})}`,
      'If your tool names these parameters differently, pass the same values under its own names.',
      'Everything else is blocked (read-only tools excepted). Do not edit files or run commands yourself. Do not judge the result yourself; the harness verifies it.'].join('\n');
  }
  // 프로그램의 작업 걸음은 도구 이름 대신 할 수 있는 일로 적는다 (도구 이름은 호스트마다 다르다)
  const can = a.allow || [];
  const lim = [a.step ? `You may edit files${can.includes('exec') ? ' and run shell commands' : ' (shell commands are not allowed in this step)'}; read-only tools are always allowed.`
    : `Allowed tools: ${can.join(', ') || '(none)'} (+ read-only tools).`];
  if (a.write_scope) lim.push(`Writable paths: ${a.write_scope.join(', ')}${a.step ? ' — changes anywhere else stop the run' : ''}.`);
  if (a.exec_allow) lim.push(`Allowed commands (regex): ${a.exec_allow.join(' | ')}.`);
  return [tag, ...why, 'WORK — do this yourself, now:', `  ${a.work}`, lim.join(' '),
    'When you are finished, run exactly this shell command (one command, nothing before or after it):', `  ${cli('check')}`,
    'Do not judge the result yourself; the harness verifies it.'].join('\n');
}

module.exports = {
  DIR, PLUGIN_DIR, HARNESS_CLI, DEVIN_TOOLS, FILE_MUTATORS, NEVER_PASSIVE, DEFAULT_PASSIVE,
  normTool, isKnownTool, findRoot, sp, readJson, writeJson, append, log, load, saveState, config, subagentMode, learn,
  sleep, alive, withLock, inside, inScope, globToRe, targetPaths, touchesHarness, harnessCmd, scopeViolation,
  paramsMismatch, kind, effectivePassive, isDup, shq, cli, handoffQuestion, renderNext, isHarnessMcp, registry, gateCmd, readOnlyShell, needsPlan,
};
