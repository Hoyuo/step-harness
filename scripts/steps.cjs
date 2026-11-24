'use strict';
// 프로그램 흐름의 실행기. 모델이 낸 프로그램(.step-harness/program.ts)에서 "다음 한 걸음"을 뽑아 엔진의 액션으로 만든다.
//   h.check  → judge 액션  (하네스가 등록된 명령을 직접 돌려 판정)
//   h.work   → work 액션   (프롬프트를 받은 그 세션이 범위 안에서 직접 작업)
//   h.skill  → call 액션   (그 세션이 그 스킬을 정확히 한 번 호출)
//   h.agent  → call 액션   (그 세션이 그 서브에이전트를 정확히 한 번 시작)
// 한 걸음이 끝나면 결과를 기록(state.trace)하고, 프로그램을 처음부터 되짚어 다음 걸음을 구한다 (program.cjs 의 next).
// 순서·분기·반복은 프로그램과 판정 결과가 정한다. 모델은 그때그때 주어진 한 걸음만 할 수 있다 (hook 이 나머지를 막는다).
const fs = require('fs');
const L = require('./lib.cjs');
const F = require('./flow.cjs');
const P = require('./program.cjs');
const scope = require('./scope.cjs');

const isProgramFlow = (flow) => !!(flow && flow.actions && flow.actions.program && flow.actions.program.program);
const FILE_TOOLS = ['edit', 'write', 'apply_patch', 'notebook_edit'];
const SHELL_TOOLS = ['exec', 'write_to_process', 'kill_shell'];
const CHANGES = new Set(['work', 'skill', 'agent']);   // 파일을 바꿀 수 있는 걸음 → 끝날 때 범위 밖 변경을 확인한다

const label = (step) => (step.op === 'work' ? 'work' : step.op === 'done-check' ? `check:${step.args[0]} (required to finish)` : `${step.op}:${step.args[0]}`);
// 한 걸음 → 엔진의 액션 (hook 이 그대로 강제할 수 있는 모양)
function actionFor(root, step, id) {
  const cfg = L.config(root);
  const reg = L.registry(root);
  const [a0, a1, a2] = step.args;
  const base = { id, step: { op: step.op, key: step.key || null, n: step.n, name: step.op === 'work' ? null : a0, label: label(step) }, on: { pass: '@program', fail: '@program' } };
  if (step.op === 'check' || step.op === 'done-check') {
    const cmd = Object.prototype.hasOwnProperty.call(reg.gates, a0) ? L.gateCmd(reg.gates[a0]) : '';
    if (!cmd) throw new Error(`게이트 "${a0}" 가 ${L.DIR}/config.json 에 없음 (실행 중에 설정이 바뀜)`);   // 빈 명령은 exit 0 이다 → 통과로 치면 안 된다
    return { ...base, check: cmd };
  }
  if (step.op === 'work') {
    return { ...base, work: a0, write_scope: a1, allow: [...FILE_TOOLS, ...(cfg.work_shell === false ? [] : SHELL_TOOLS)], allow_mcp: cfg.work_mcp !== false,
      ...(Array.isArray(cfg.exec_allow) ? { exec_allow: cfg.exec_allow } : {}) };
  }
  if (step.op === 'skill') return { ...base, tool: 'skill', params: a1 ? { skill: a0, args: a1 } : { skill: a0 }, write_scope: a2 };
  return { ...base, tool: 'run_subagent', params: { profile: a0, task: a1 }, write_scope: a2 };
}

// 마지막으로 파일이 바뀔 수 있었던 걸음 뒤에, 이 게이트가 통과한 기록이 있는가 (있으면 완료 조건으로 다시 돌리지 않는다)
function passedSinceLastChange(state, gate) {
  if ((state.doneChecked || []).includes(gate)) return true;
  const t = state.trace || [];
  let lastChange = -1;
  t.forEach((e, i) => { if (CHANGES.has(e.op)) lastChange = i; });
  return t.some((e, i) => i > lastChange && e.op === 'check' && e.name === gate && e.result && e.result.pass);
}
const planAgain = (flow, state, why) => F.handoff(flow, { ...state, action: 'program' }, why);   // 사람이 retry 하면 새 프로그램을 받는다

function enterStep(root, flow, state, step) {
  const stepN = (state.stepN || 0) + 1;
  const id = `step${stepN}`;
  let action;
  try { action = actionFor(root, step, id); } catch (e) { return planAgain(flow, state, e.message); }
  flow.actions[id] = action;
  L.writeJson(L.sp(root, 'flow.json'), flow);
  const next = { ...F.enter(flow, { ...state, action: 'program' }, id), stepN };
  if (next.status === 'running' && next.action === id && CHANGES.has(step.op)) scope.begin(root, next.seq);   // 이 걸음 전의 파일 상태를 남겨 둔다
  return next;
}
// 기록(state.trace)까지 진행한 프로그램의 다음 걸음으로 들어간다
function go(root, flow, state) {
  let nx;
  try {
    const { ast, errors } = P.compile(fs.readFileSync(L.sp(root, 'program.ts'), 'utf8'), L.registry(root));
    if (errors.length) throw new Error(errors.join('; '));   // 실행 중에 등록부나 프로그램 파일이 바뀐 경우
    nx = P.next(ast, state.trace || [], flow.max_steps);
  } catch (e) { return planAgain(flow, state, `프로그램을 이어서 실행할 수 없음: ${e.message}`); }
  if (nx.step) return enterStep(root, flow, state, nx.step);
  if (nx.end === 'handoff') return planAgain(flow, state, nx.message || '프로그램이 사람의 결정을 요청함');
  // h.done() 은 프로그램의 주장일 뿐이다 → 완료 조건으로 정해 둔 게이트는 하네스가 직접 돌려 확인한다
  const need = (flow.actions.program.program.done_when || []).filter((g) => !passedSinceLastChange(state, g));
  if (need.length) return enterStep(root, flow, state, { op: 'done-check', args: [need[0]], n: (state.trace || []).length + 1 });
  flow.done = nx.message || flow.done;
  L.writeJson(L.sp(root, 'flow.json'), flow);
  return F.enter(flow, { ...state, action: 'program' }, 'done');
}

// 검증을 통과한 프로그램을 처음부터 시작한다 (락을 잡은 상태에서 호출)
function begin(root, flow, state) {
  return go(root, flow, { ...state, trace: [], doneChecked: [], stepN: 0, planned: true, rejects: 0, rejected: null, notDone: null });
}

// 지금의 걸음이 끝났다 → 결과를 기록하고 다음 걸음으로. 반환: { state, outcome? } (outcome = 기록에 남길 판정이 엔진의 것과 다를 때)
function advance(root, flow, state, outcome, report, opts = {}) {
  const a = flow.actions[state.action];
  const st = a.step;
  if (st.op === 'done-check') {
    if (outcome.pass) return { state: go(root, flow, { ...state, doneChecked: [...(state.doneChecked || []), st.name] }) };
    // 완료를 선언했지만 게이트가 실패 → 새 프로그램을 내게 한다 (시도 횟수 +1, 한도를 넘으면 사람에게)
    const next = F.enter(flow, { ...state, trace: [], doneChecked: [] }, 'program');
    if (next.status === 'running') next.notDone = { gate: st.name, report: report || '' };
    else if (next.status === 'handoff') next.handoff.reason = `프로그램은 완료를 선언했지만 게이트 "${st.name}" 가 통과하지 못함 (${flow.max_visits}회 시도)${report ? ` — ${report}` : ''}`;
    return { state: next };
  }
  let result;
  if (st.op === 'check') {
    result = { pass: !!outcome.pass, route: outcome.route || null, report: report || '', exit: typeof outcome.exit === 'number' ? outcome.exit : (outcome.pass ? 0 : 1) };
  } else {
    if (!opts.skipScope) {   // 범위 밖의 파일이 바뀌었으면(셸 명령 등 hook 이 경로를 볼 수 없는 방법으로) 여기서 멈추고 사람에게 넘긴다
      const v = scope.end(root, state.seq, a.write_scope || []);
      const where = (a.write_scope || []).join(', ');
      if (v && v.unknown) {
        return { state: F.handoff(flow, state, `${st.label} 단계 뒤에 git 으로 변경을 확인할 수 없음 — 범위(${where}) 밖을 바꿨는지 알 수 없어 멈춤`), outcome: { pass: false, route: 'scope-unknown' } };
      }
      if (v && v.outside.length) {
        const list = v.outside.slice(0, 5).join(', ') + (v.outside.length > 5 ? ` 외 ${v.outside.length - 5}개` : '');
        return { state: F.handoff(flow, state, `${st.label} 단계에서 허용 범위(${where}) 밖의 파일이 바뀜: ${list}`), outcome: { pass: false, route: 'out-of-scope' } };
      }
    }
    result = { ok: !!outcome.pass };
  }
  const trace = [...(state.trace || []), { key: st.key, op: st.op, name: st.name, result }];
  return { state: go(root, flow, { ...state, trace, doneChecked: [] }) };
}

// handoff 에 대한 사람의 답 (retry / proceed / stop)
function answer(root, flow, state, kind) {
  if (!isProgramFlow(flow) || kind === 'stop') return F.answer(flow, state, kind);
  const from = state.handoff.from;
  const base = { ...state, handoff: null, visits: {}, steps: 0, action: from };
  const a = flow.actions[from];
  if (!a || !a.step) {   // 계획 단계에서, 또는 프로그램 스스로 넘긴 경우: retry = 새 프로그램을 받는다 / proceed = 사람이 끝난 것으로 인정한다
    return kind === 'proceed' ? F.enter(flow, base, 'done') : F.enter(flow, { ...base, trace: [], doneChecked: [] }, 'program');
  }
  if (kind === 'retry') {   // 그 걸음을 다시 (지금의 파일 상태를 새 기준으로 삼는다)
    const next = F.enter(flow, base, from);
    if (next.status === 'running' && CHANGES.has(a.step.op)) scope.begin(root, next.seq);
    return next;
  }
  return advance(root, flow, base, { pass: true }, null, { skipScope: true }).state;   // proceed: 그 걸음을 통과한 것으로 치고 계속
}

module.exports = { isProgramFlow, begin, advance, answer };
