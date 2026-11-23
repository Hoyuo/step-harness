'use strict';
// flow 정의(JSON/YAML) 로드 · 검사 · 컴파일 · 상태 전이.
// flow = 액션 상태머신. 액션은 세 종류:
//   judge — check 만 있음. 하네스가 명령을 돌려 exit code 로 판정 (실패 분기는 명령이 찍는 HARNESS_ROUTE=<키>)
//   call  — tool + params. 모델은 그 도구를 그 params 로 정확히 1번 호출
//   work  — work 지시문. 메인 세션이 직접 작업 (allow / write_scope / exec_allow 로 범위 제한)
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const L = require('./lib.cjs');

const TOP_KEYS = new Set(['flow', 'description', 'args', 'start', 'actions', 'done', 'passive', 'max_visits', 'max_steps', 'max_blocks',
  'max_idle_calls', 'max_stop_blocks', 'check_timeout_sec', 'check_wait_sec', 'inflight_ttl_sec', 'handoff_question', 'worker']);
const ACTION_KEYS = new Set(['tool', 'params', 'rewrite', 'work', 'allow', 'deny', 'write_scope', 'exec_allow', 'check', 'on', 'prompt', 'note']);
const RESERVED = new Set(['done', 'handoff']);
const BUILTINS = { last_report: `${L.DIR}/last-report.txt` };
const DEFAULTS = { max_visits: 3, max_steps: 40, max_blocks: 5, max_idle_calls: 15, max_stop_blocks: 3,
  check_timeout_sec: 900, check_wait_sec: 30, inflight_ttl_sec: 3600 };

function loadFile(file) {
  const text = fs.readFileSync(file, 'utf8');
  if (!/\.ya?ml$/i.test(file)) return JSON.parse(text);
  for (const mod of ['yaml', 'js-yaml']) {   // 설치돼 있으면 정식 파서, 없으면 내장 부분집합 파서
    try { const y = require(mod); return mod === 'yaml' ? y.parse(text) : y.load(text); } catch (e) { if (e.code !== 'MODULE_NOT_FOUND') throw e; }
  }
  return require('./yaml.cjs').parse(text);
}

function refs(v, out = []) {
  if (typeof v === 'string') for (const m of v.matchAll(/\{(\w+)\}/g)) out.push(m[1]);
  else if (v && typeof v === 'object') for (const x of Object.values(v)) refs(x, out);
  return out;
}

function lint(f) {
  if (!f || typeof f !== 'object' || Array.isArray(f)) return ['flow 파일은 객체여야 함'];
  const E = [];
  if (typeof f.flow !== 'string' || !/^[\w.-]+$/.test(f.flow)) E.push('"flow": 이름 필요 (영문·숫자·_ . -)');
  for (const k of Object.keys(f)) if (!TOP_KEYS.has(k)) E.push(`알 수 없는 최상위 키 "${k}"`);
  const acts = f.actions && typeof f.actions === 'object' && !Array.isArray(f.actions) ? f.actions : {};
  const ids = Object.keys(acts);
  if (!ids.length) E.push('"actions" 가 비었음');
  if (!f.start || !acts[f.start]) E.push(`"start" 가 actions 에 없음: ${f.start}`);
  if (f.args != null && !Array.isArray(f.args)) E.push('"args" 는 배열');
  const args = new Set([...(Array.isArray(f.args) ? f.args : []), ...Object.keys(BUILTINS)]);
  for (const t of f.passive || []) {
    if (!L.isKnownTool(t)) E.push(`passive: 알 수 없는 도구 ${t}`);
    else if (L.NEVER_PASSIVE.has(t)) E.push(`passive: ${t} 는 passive 에 둘 수 없음 (work 액션의 allow 로)`);
  }
  for (const k of Object.keys(DEFAULTS)) if (f[k] != null && !(Number.isInteger(f[k]) && f[k] > 0)) E.push(`${k} 는 양의 정수`);
  const target = (at, v) => { if (typeof v !== 'string' || (!acts[v] && !RESERVED.has(v))) E.push(`${at}: 없는 액션 "${v}"`); };

  for (const id of ids) {
    const a = acts[id];
    const at = `actions.${id}`;
    if (RESERVED.has(id)) E.push(`${at}: "${id}" 는 예약어`);
    if (!a || typeof a !== 'object' || Array.isArray(a)) { E.push(`${at}: 객체여야 함`); continue; }
    for (const k of Object.keys(a)) if (!ACTION_KEYS.has(k)) E.push(`${at}: 알 수 없는 키 "${k}"`);
    if (a.tool && a.work) E.push(`${at}: tool 과 work 는 함께 쓸 수 없음`);
    if (!a.tool && !a.work && !a.check) E.push(`${at}: tool / work / check 중 하나 필요`);
    if (a.tool != null && !L.isKnownTool(a.tool)) E.push(`${at}: 알 수 없는 도구 "${a.tool}" (Devin 도구 이름 그대로)`);
    if (a.params != null && (typeof a.params !== 'object' || Array.isArray(a.params))) E.push(`${at}: params 는 객체`);
    if (a.params != null && !a.tool) E.push(`${at}: params 는 tool 이 있을 때만`);
    if (a.rewrite != null) {
      if (!Array.isArray(a.rewrite)) E.push(`${at}: rewrite 는 배열`);
      else for (const k of a.rewrite) if (!a.params || !(k in a.params)) E.push(`${at}.rewrite: params 에 없는 키 "${k}"`);
    }
    if (a.work != null && typeof a.work !== 'string') E.push(`${at}: work 는 문자열`);
    if (a.allow != null && !a.work) E.push(`${at}: allow 는 work 액션 전용`);
    for (const k of ['allow', 'deny', 'write_scope', 'exec_allow']) if (a[k] != null && !Array.isArray(a[k])) E.push(`${at}: ${k} 는 배열`);
    for (const k of ['allow', 'deny']) for (const t of Array.isArray(a[k]) ? a[k] : []) if (!L.isKnownTool(t)) E.push(`${at}.${k}: 알 수 없는 도구 ${t}`);
    if (a.tool && Array.isArray(a.deny) && a.deny.includes(a.tool)) E.push(`${at}: 자기 tool(${a.tool})을 deny 할 수 없음`);
    for (const re of Array.isArray(a.exec_allow) ? a.exec_allow : []) { try { new RegExp(re); } catch { E.push(`${at}.exec_allow: 잘못된 정규식 ${re}`); } }
    if (a.check != null && typeof a.check !== 'string') E.push(`${at}: check 는 셸 명령 문자열`);
    for (const r of refs([a.params, a.check, a.work, a.write_scope, a.prompt])) if (!args.has(r)) E.push(`${at}: args 에 없는 인자 {${r}}`);
    const on = a.on;
    if (!on || typeof on !== 'object' || !on.pass) { E.push(`${at}: on.pass 필요`); continue; }
    for (const [k, v] of Object.entries(on)) {
      if (!['pass', 'fail', 'exhausted'].includes(k)) E.push(`${at}.on: 알 수 없는 키 ${k}`);
      else if (k === 'fail' && v && typeof v === 'object') for (const [r, t] of Object.entries(v)) target(`${at}.on.fail.${r}`, t);
      else target(`${at}.on.${k}`, v);
    }
  }
  return E;
}

function sub(v, args, shell, untrusted) {
  if (typeof v === 'string') {
    return v.replace(/\{(\w+)\}/g, (all, k) => {
      if (!(k in args)) return all;
      return shell && untrusted.has(k) ? L.shq(args[k]) : String(args[k]);   // 프롬프트에서 뽑은 값이 셸로 갈 때는 따옴표 처리
    });
  }
  if (Array.isArray(v)) return v.map((x) => sub(x, args, shell, untrusted));
  if (v && typeof v === 'object') return Object.fromEntries(Object.entries(v).map(([k, x]) => [k, sub(x, args, shell, untrusted)]));
  return v;
}
function compile(f, given = {}, untrusted = new Set()) {
  const args = { ...BUILTINS, ...given };
  const s = (v, shell) => sub(v, args, !!shell, untrusted);
  const actions = {};
  for (const [id, a] of Object.entries(f.actions)) {
    const c = { id, on: { ...a.on } };
    if (a.tool) { c.tool = a.tool; c.params = s(a.params || {}); if (a.rewrite && a.rewrite.length) c.rewrite = a.rewrite; }
    if (a.work) { c.work = s(a.work); c.allow = a.allow || []; }
    if (a.deny) c.deny = a.deny;
    if (a.write_scope) c.write_scope = s(a.write_scope);
    if (a.exec_allow) c.exec_allow = a.exec_allow;
    if (a.check) c.check = s(a.check, true);
    if (a.prompt) c.prompt = s(a.prompt);
    actions[id] = c;
  }
  const flow = { flow: f.flow, args: given, start: f.start, actions, done: f.done ? s(f.done) : null };
  for (const [k, d] of Object.entries(DEFAULTS)) flow[k] = f[k] || d;
  for (const k of ['passive', 'handoff_question', 'worker']) if (f[k] != null) flow[k] = f[k];
  return flow;
}

// ───────── 상태 전이
function handoff(flow, state, reason) {
  return { ...state, status: 'handoff', seq: state.seq + 1, receipt: null, inFlight: null, workDone: false,
    handoff: { from: state.action, reason, promptId: state.lastPromptId || null, announced: false } };
}
function enter(flow, state, target, reason) {
  const s = { ...state, receipt: null, inFlight: null, workDone: false, blocks: 0, idle: 0, stopBlocks: 0 };
  if (target === 'done') return { ...s, status: 'done', action: null, seq: s.seq + 1 };
  if (target === 'handoff') return handoff(flow, s, reason || `${state.action}: flow 정의에 따라 사람에게 넘김`);
  const a = flow.actions[target];
  const steps = (s.steps || 0) + 1;
  if (steps > flow.max_steps) return handoff(flow, s, `max_steps(${flow.max_steps}) 초과 — 흐름이 끝나지 않음`);
  const visits = { ...(s.visits || {}) };
  if (L.kind(a) !== 'judge') {   // 재시도 한도는 "고치는" 액션에만. 게이트는 몇 번이든 다시 돈다
    visits[target] = (visits[target] || 0) + 1;
    if (visits[target] > flow.max_visits) {
      const why = `${target} 을(를) ${flow.max_visits}회 시도했지만 통과하지 못함`;
      const ex = a.on.exhausted || 'handoff';
      return ex === 'handoff' ? handoff(flow, s, why) : enter(flow, { ...s, steps }, ex, why);
    }
  }
  return { ...s, status: 'running', action: target, seq: s.seq + 1, steps, visits, handoff: null };
}
function advance(flow, state, outcome) {
  const a = flow.actions[state.action];
  let target;
  if (outcome.pass) target = a.on.pass;
  else {
    const f = a.on.fail;
    if (typeof f === 'string') target = f;
    else if (f && typeof f === 'object') target = (outcome.route && f[outcome.route]) || f['*'] || 'handoff';
    else target = L.kind(a) === 'judge' ? 'handoff' : a.id;
  }
  const reason = outcome.pass ? null : `${a.id} 실패` + (outcome.route ? ` (route=${outcome.route})` : '') + (outcome.why ? ` — ${outcome.why}` : '');
  return enter(flow, state, target, reason);
}
// handoff 에 대한 사람의 답
function answer(flow, state, kind) {
  if (kind === 'stop') return { ...state, status: 'stopped' };
  const from = state.handoff.from;
  const base = { ...state, handoff: null, visits: {}, steps: 0, action: from };
  return enter(flow, base, kind === 'proceed' ? flow.actions[from].on.pass : from);
}

function start(root, file, given = {}, opts = {}) {
  let raw;
  try { raw = loadFile(file); } catch (e) { return { error: `cannot read flow (${file}): ${e.message}` }; }
  const errors = lint(raw);
  if (errors.length) return { error: 'flow errors:\n' + errors.join('\n') };
  const missing = (raw.args || []).filter((k) => !(k in given));
  if (missing.length) return { error: 'missing args: ' + missing.join(', ') };
  const flow = compile(raw, given, new Set(opts.untrusted || []));
  let state = { v: 3, run: crypto.randomBytes(4).toString('hex'), status: 'running', mode: opts.mode || 'session', action: null, seq: 0, steps: 0,
    visits: {}, receipt: null, inFlight: null, workDone: false, blocks: 0, idle: 0, stopBlocks: 0, history: [], handoff: null,
    mainSession: opts.session || null, lastPromptId: opts.promptId || null, startedAt: new Date().toISOString() };
  state = enter(flow, state, flow.start);
  L.writeJson(L.sp(root, 'flow.json'), flow);
  L.saveState(root, state);
  const gi = L.sp(root, '.gitignore');   // 실행 상태는 커밋 대상이 아니다 (규칙·설정 파일만 공유)
  if (!fs.existsSync(gi)) { try { fs.writeFileSync(gi, '*\n!.gitignore\n!router.json\n!config.json\n'); } catch { /* 무시 */ } }
  L.log(root, { ev: 'start', flow: flow.flow, run: state.run, args: given, file });
  return { flow, state };
}
function resolveFlowPath(root, p) {
  for (const base of [root, L.PLUGIN_DIR]) { const f = path.resolve(base, p); if (fs.existsSync(f)) return f; }
  return path.resolve(root, p);
}

module.exports = { loadFile, lint, compile, start, enter, advance, handoff, answer, resolveFlowPath, DEFAULTS, BUILTINS };
