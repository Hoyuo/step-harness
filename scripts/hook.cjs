#!/usr/bin/env node
'use strict';
// 단일 hook 엔트리. hook_event_name 으로 분기한다.
//   PreToolUse       — NEXT_ACTION(도구+params 정확 일치)·읽기 전용 도구·하네스 CLI 만 통과. 나머지 차단
//   PostToolUse      — receipt 를 hook 이 기록(모델의 자가 보고 없음)하고, 갈 수 있는 데까지 자동 진행
//   UserPromptSubmit — 라우터(자연어 → flow, LLM 없음) · 매 턴 NEXT_ACTION 주입 · handoff 답 처리
//   Stop             — 흐름이 끝나기 전에는 종료 불가. 판정이 끝나길 잠깐 기다렸다가 직접 다음 단계로 넘김
//   SessionStart     — 세션 재개 시 NEXT_ACTION 재주입
// 다른 dispatcher 에서 쓰려면: require('./hook.cjs').handle(eventPayload, process.env) → { code, o, err }
const fs = require('fs');
const path = require('path');
const L = require('./lib.cjs');
const F = require('./flow.cjs');
const J = require('./judge.cjs');

const fresh = (state, x) => !!x && x.seq === state.seq;
const live = (flow, state) => !!(flow && state && (state.status === 'running' || state.status === 'handoff'));
// 하네스가 띄운 작업자(러너·프로그램 모드)의 hook: 환경변수 STEP_HARNESS_WORKER=<run>:<seq> 를 물려받는다
//   그 실행(run)의 그 단계(seq)가 아직 돌고 있을 때만 "작업자"로 인정한다
const isWorker = (C, state) => !!(C.worker && state && state.status === 'running' && C.worker === `${state.run}:${state.seq}`);
const isForeign = (state, ev) => !!(state.mainSession && ev.session_id && ev.session_id !== state.mainSession);

// ───────── 출력
function ctxOut(C, text) {
  if (text) C.R.o.hookSpecificOutput = { ...(C.R.o.hookSpecificOutput || {}), hookEventName: C.ev.hook_event_name, additionalContext: text };
}
function blockTool(C, reason) { Object.assign(C.R.o, { decision: 'block', reason }); C.R.err = reason; C.R.code = 2; }
function blockStop(C, reason) { Object.assign(C.R.o, { decision: 'block', reason }); }
function endTurn(C, reason) {   // 턴을 코드로 끝낸다 (Devin: stop / Claude 형식: continue=false)
  if (C.devin) C.R.o.stop = reason; else Object.assign(C.R.o, { continue: false, stopReason: reason });
}
// handoff 가 생겼으면 사람에게 알리고 턴을 끝낸다 (exit 0 경로에서 한 번만)
function announce(C) {
  if (C.R.code !== 0) return;
  L.withLock(C.root, () => {
    const { flow, state } = L.load(C.root);
    if (!flow || !state || state.status !== 'handoff' || !state.handoff || state.mode === 'runner') return;
    if (isForeign(state, C.ev)) return;   // 서브에이전트의 이벤트로는 턴을 끝내지 않는다
    const sameTurn = !C.ev.prompt_id || C.ev.prompt_id === state.handoff.promptId;
    if (!sameTurn) return;                // 다음 턴부터는 사람이 주도한다
    if (!state.handoff.announced) { state.handoff.announced = true; L.saveState(C.root, state); }
    endTurn(C, L.handoffQuestion(flow, state));
  });
}

// ───────── PreToolUse
const CLI_FORM = 'the harness command must be written exactly as shown — one command, nothing before or after it (no cd, no pipe, no second line), and a heredoc must end with a line that is only EOF.';
function preToolUse(C) {
  const { ev, root, tool, input } = C;
  const { flow, state } = L.load(root);
  const active = live(flow, state);
  const cliSub = tool === 'exec' ? L.harnessCmd(root, input.command) : null;
  const base = { ev: 'PreToolUse', sid: ev.session_id, pid: ev.prompt_id, tool, action: state ? state.action : null };
  const deny = (why, msg) => { L.log(root, { ...base, decision: 'block', why }); blockTool(C, msg); };
  const allow = (why) => { if (active) L.log(root, { ...base, decision: 'allow', why }); };

  // 하네스 명령을 쓰긴 했는데 허용 형태가 아닌 경우(앞에 cd, 뒤에 다른 명령 …): 차단은 같고, 무엇이 틀렸는지를 알려준다
  const nearMiss = !cliSub && tool === 'exec' && /harness\.cjs["']?[ \t]+(next|check|status|search|execute)\b/.test(String(input.command || ''));
  if (!cliSub && L.touchesHarness(root, tool, input, active)) {
    return deny('protected', `[step-harness] BLOCKED ${tool}: ` + (nearMiss ? CLI_FORM : `harness files (${L.DIR}/ and the plugin) are read-only for you.`) + (active ? `\n${L.renderNext(flow, state)}` : ''));
  }
  // 하네스가 띄운 작업자(러너·프로그램 모드): 순서는 스크립트가 쥐고 있다. 여기서는 쓰기 범위만 지킨다
  const workerScope = () => {
    const cur = flow.actions[state.action];
    let v = L.scopeViolation(root, cur, tool, input);
    if (!v && L.kind(cur) === 'program' && !cur.write_scope && L.FILE_MUTATORS.has(tool)) v = { why: 'write-scope', detail: 'no worker step with a write scope is running.' };
    return v ? deny(v.why, `[step-harness] BLOCKED ${tool}: ${v.detail}`) : allow('worker');
  };
  if (C.worker) {
    if (isWorker(C, state)) return workerScope();
    // 그 실행은 끝났거나 멈췄다 (사람에게 넘어감 · 중단 · 다른 실행) → 남아 있는 작업자는 읽기만 할 수 있다
    if (!state || L.DEFAULT_PASSIVE.includes(tool)) return;   // 이 프로젝트에 실행 기록이 아예 없으면 관여하지 않는다
    return deny('stale-worker', `[step-harness] BLOCKED ${tool}: the harness run that started this worker has ended. Do not change anything. Stop now. ` +
      '(This process carries STEP_HARNESS_WORKER from that run; a normal session must be started without that variable.)');
  }
  if (!active) return;
  if (state.mode === 'runner') return state.status === 'running' ? workerScope() : allow('worker');

  let dirty = false;
  const dup = L.isDup(state, ev, C.src); dirty = true;
  if (!state.mainSession && cliSub && ev.session_id) state.mainSession = ev.session_id;
  const foreign = isForeign(state, ev);
  if (!foreign && ev.prompt_id) state.lastPromptId = ev.prompt_id;   // handoff 가 "어느 턴에서 났는지" 판단하는 기준
  const save = () => { if (dirty) L.saveState(root, state); };
  const pass = (why) => { if (!dup) state.lastEvent.allowed = true; save(); allow(why); };
  if (dup && state.lastEvent.allowed === true) return pass('duplicate-hook');   // 다른 설치본이 방금 통과시킨 바로 그 호출

  if (cliSub) return pass('harness-cli');
  const passiveBase = new Set(flow.passive || L.DEFAULT_PASSIVE);

  if (state.status === 'handoff') {   // 사람 차례. handoff 가 난 그 턴에는 읽기 외 금지 (넘기는 척하고 계속 고치는 것 방지)
    const sameTurn = !ev.prompt_id || ev.prompt_id === state.handoff.promptId;
    save();
    if (sameTurn && !passiveBase.has(tool) && tool !== 'ask_user_question') {
      endTurn(C, L.handoffQuestion(flow, state));
      return deny('handoff', `[step-harness] BLOCKED ${tool}: the flow is paused for a human decision.\n${L.renderNext(flow, state)}`);
    }
    return allow('handoff');
  }

  const a = flow.actions[state.action];
  const k = L.kind(a);
  let inFlight = fresh(state, state.inFlight);
  if (inFlight && k !== 'program' && (Date.now() - Date.parse(state.inFlight.since)) / 1000 > flow.inflight_ttl_sec) { state.inFlight = null; inFlight = false; }
  const mode = L.subagentMode(root);
  if (foreign && inFlight && mode === 'same' && !(L.readJson(L.sp(root, 'caps.json'), {}) || {}).foreign_seen) {
    L.learn(root, { foreign_seen: new Date().toISOString() });   // 관측만 기록 (doctor 가 알려준다)
  }

  const block = (why, detail, worker, redo) => {
    if (!dup) { state.lastEvent.allowed = false; state.blocks = (state.blocks || 0) + 1; }
    if (state.blocks > flow.max_blocks) {   // 막힌 호출만 반복 → 토큰을 태우지 말고 사람에게
      const next = F.handoff(flow, { ...state, lastPromptId: ev.prompt_id || state.lastPromptId }, `허용되지 않은 호출을 ${flow.max_blocks}회 넘게 반복함 (액션 ${state.action})`);
      L.saveState(root, next);
      endTurn(C, L.handoffQuestion(flow, next));
      return deny('block-limit', `[step-harness] BLOCKED ${tool}: too many blocked calls.\n${L.renderNext(flow, next)}`);
    }
    save();
    return deny(why, `[step-harness] BLOCKED ${tool}: ${detail}` + (worker ? ' Stay inside the allowed scope and continue your own task.'
      : `${redo ? '' : ' Do not retry it and do not work around it.'}\n${L.renderNext(flow, state)}`));
  };
  const scoped = (why, worker) => {   // 범위(write_scope / exec_allow) 안에서만 허용
    const v = L.scopeViolation(root, a, tool, input);
    return v ? block(v.why, v.detail, worker) : pass(why);
  };

  if (foreign && k !== 'program') {   // 메인이 아닌 세션 = 위임된 작업자(서브에이전트) 또는 같은 폴더의 다른 세션
    if (inFlight) return scoped('worker', true);
    if (passiveBase.has(tool)) return pass('foreign-passive');
    return block('locked', 'the workspace is locked by a running flow that belongs to another session.', true);
  }

  if (k === 'program' && !inFlight && L.isHarnessMcp(tool)) return pass('program-mcp');
  if (k === 'program' && inFlight && /__check$/.test(tool) && L.isHarnessMcp(tool)) return pass('program-mcp');
  if (k === 'call') {
    if (tool === a.tool && !inFlight && !fresh(state, state.receipt)) {
      const bad = L.paramsMismatch(a.params, input, a.rewrite);
      if (bad.length) return block('params', `params differ from the NEXT_ACTION (${bad.join(', ')}). Copy the params exactly.`);
      Object.assign(state, { inFlight: { seq: state.seq, since: new Date().toISOString(), tool }, blocks: 0, idle: 0 });
      if (a.rewrite) {   // 이 키들은 모델이 뭐라고 넘겼든 flow 의 값으로 덮어쓴다
        C.R.o.hookSpecificOutput = { hookEventName: 'PreToolUse', updatedInput: Object.fromEntries(a.rewrite.map((key) => [key, a.params[key]])) };
      }
      return pass('next-action');
    }
    // NEXT_ACTION 실행 중: 서브에이전트 호출이 메인과 같은 session_id 로 보이는 환경에서만 구분 없이 통과시킨다
    if (inFlight && mode === 'same') return scoped('worker-same-session', true);
  } else if (k === 'work' && !state.workDone && (a.allow || []).includes(tool)) {
    state.idle = 0;
    return scoped('work', false);
  }

  if (L.effectivePassive(flow, a).has(tool)) {
    if (!dup) state.idle = (state.idle || 0) + 1;
    if (state.idle > flow.max_idle_calls) return block('idle-limit', `too many read-only calls (${flow.max_idle_calls}) without doing the NEXT_ACTION.`);
    return pass('passive');
  }
  if (tool === 'ask_user_question') return pass('ask-user');
  if (nearMiss) return block('cli-form', CLI_FORM, false, true);
  const why = (a.deny || []).includes(tool) ? 'deny' : 'not-next-action';
  return block(why, k === 'work' && !state.workDone ? 'this tool is not allowed for the current WORK.' : 'only the NEXT_ACTION is allowed right now.');
}

// ───────── PostToolUse: receipt 는 모델이 아니라 hook 이 쓴다
function postToolUse(C) {
  const { ev, root, tool, input } = C;
  let got = false;
  L.withLock(root, () => {
    const { flow, state } = L.load(root);
    if (!flow || !state || state.status !== 'running' || state.mode === 'runner' || isForeign(state, ev)) return;
    const a = flow.actions[state.action];
    const k = L.kind(a);
    const r = ev.tool_response || {};
    const ok = r.success !== false && !r.error;
    if (k === 'call' && tool === a.tool && fresh(state, state.inFlight) && !fresh(state, state.receipt) && !L.paramsMismatch(a.params, input, a.rewrite).length) {
      Object.assign(state, { receipt: { seq: state.seq, ok, tool, at: new Date().toISOString() }, inFlight: null, lastPromptId: ev.prompt_id || state.lastPromptId });
      L.saveState(root, state);
      L.append(root, 'receipts.jsonl', { flow: flow.flow, run: state.run, action: a.id, attempt: (state.visits || {})[a.id], tool, ok,
        sid: ev.session_id, pid: ev.prompt_id, input, error: r.error || null, output_tail: String(r.output || '').slice(-400) });
      L.log(root, { ev: 'PostToolUse', tool, action: a.id, receipt: ok });
      got = true;
    } else if (k === 'work' && !state.workDone && ok && (a.allow || []).includes(tool)) {
      const rc = fresh(state, state.receipt) ? state.receipt : { seq: state.seq, ok: true, tool: 'work', mutations: 0, at: new Date().toISOString() };
      rc.mutations += 1;
      state.receipt = rc;
      L.saveState(root, state);
    }
  });
  if (!got) return;
  J.settle(root, { trigger: 'post', waitMs: L.config(root).wait.post * 1000 });
  const { flow, state } = L.load(root);
  ctxOut(C, L.renderNext(flow, state));
}

// ───────── UserPromptSubmit
const ANSWERS = [[/^(retry|재시도|다시|다시\s*해|다시\s*시도)$/i, 'retry'], [/^(proceed|진행|진행해|통과|넘어가)$/i, 'proceed'], [/^(stop|중단|그만|취소)$/i, 'stop']];
function userPromptSubmit(C) {
  const { ev, root } = C;
  const prompt = String(ev.prompt || '').trim();
  const word = prompt.replace(/^["'\s]+|["'\s.!~]+$/g, '');
  let { flow, state } = L.load(root);
  const active = live(flow, state);
  const wait = L.config(root).wait.prompt * 1000;
  const inject = () => { ({ flow, state } = L.load(root)); ctxOut(C, L.renderNext(flow, state)); };

  // 사람용 명령: "harness stop" / "harness status"
  const cmd = prompt.match(/^\/?(?:harness|하네스)\s+(stop|reset|중단|status|상태)\s*$/i);
  if (cmd) {
    if (/status|상태/i.test(cmd[1])) return ctxOut(C, active ? L.renderNext(flow, state) : '[step-harness] No flow is active. Tell the user so.');
    if (active) {
      L.withLock(root, () => { const s = L.load(root).state; L.saveState(root, { ...s, status: 'stopped' }); });
      J.killJudge(root);
      L.log(root, { ev: 'user-stop' });
    }
    return ctxOut(C, '[step-harness] The user stopped the flow. Harness restrictions are lifted. Acknowledge in one sentence.');
  }
  if (active && state.mode === 'runner') return;

  if (active && state.status === 'handoff') {
    const hit = ANSWERS.find(([re]) => re.test(word));
    if (!hit) {
      return ctxOut(C, `[step-harness] flow=${flow.flow} is paused: ${state.handoff.reason}. The user is in control now — follow the user's message. ` +
        'If the user has not been told yet, also tell them they can reply "retry", "proceed" or "stop" to resume the flow.');
    }
    L.withLock(root, () => {
      const cur = L.load(root);
      const next = F.answer(cur.flow, cur.state, hit[1]);
      L.saveState(root, { ...next, mainSession: ev.session_id || next.mainSession, lastPromptId: ev.prompt_id || null });
    });
    L.log(root, { ev: 'handoff-answer', answer: hit[1] });
    if (hit[1] === 'stop') return ctxOut(C, '[step-harness] The user stopped the flow. Harness restrictions are lifted. Acknowledge in one sentence.');
    J.settle(root, { trigger: 'prompt', waitMs: wait });
    return inject();
  }
  if (active) {
    // NEXT_ACTION 실행 중에 다른 session_id 로 온 프롬프트는 서브에이전트의 것일 수 있다 → 끼어들지 않는다.
    // 그 외에 다른 세션에서 온 프롬프트는 사람이 새 세션으로 돌아온 것 → 그 세션을 메인으로 삼는다.
    //   (프로그램 모드에는 서브에이전트가 없다. 작업자는 별도 프로세스이고 그 이벤트는 handle() 에서 걸러진다)
    const prog = state.status === 'running' && L.kind(flow.actions[state.action]) === 'program';
    if (!prog && isForeign(state, ev) && fresh(state, state.inFlight)) return;
    L.withLock(root, () => {
      const cur = L.load(root);   // 메인의 새 턴 = 이전 턴의 도구 호출은 끝났다 → PostToolUse 없이 남은 실행 구간을 닫는다
      const s = cur.state;          // (프로그램 실행 구간은 예외: 분리된 프로세스가 아직 돌고 있을 수 있다)
      if (s.status !== 'running') return;
      const keep = L.kind(cur.flow.actions[s.action]) === 'program';
      L.saveState(root, { ...s, inFlight: keep ? s.inFlight : null, mainSession: ev.session_id || s.mainSession, lastPromptId: ev.prompt_id || s.lastPromptId });
    });
    J.settle(root, { trigger: 'prompt', waitMs: wait });
    return inject();
  }

  // 라우터: 자연어 → flow (정규식 규칙. 판단은 코드가 한다)
  // 프로젝트 규칙이 먼저: 프로젝트 규칙에 맞는 게 있으면 플러그인 기본 규칙은 보지 않는다
  let hits = [];
  for (const f of [L.sp(root, 'router.json'), path.join(L.PLUGIN_DIR, 'router.json')]) {
    const rj = L.readJson(f, null);
    for (const r of (rj && Array.isArray(rj.routes) ? rj.routes : [])) {
      let m = null;
      try { m = prompt.match(new RegExp(r.when, 'i')); } catch { /* 잘못된 정규식은 건너뜀 */ }
      if (m) hits.push({ r, m });
    }
    if (hits.length) break;
  }
  if (!hits.length) return;
  if (hits.length > 1) {
    L.log(root, { ev: 'route', ambiguous: hits.map((h) => h.r.name || h.r.flow) });
    return ctxOut(C, `[step-harness] The request matches more than one flow (${hits.map((h) => h.r.name || h.r.flow).join(' / ')}). ` +
      'Do nothing else: ask the user which one they mean, then stop.');
  }
  const { r, m } = hits[0];
  const untrusted = [];
  const args = {};
  for (const [key, v] of Object.entries(r.args || {})) {
    if (/\$\d/.test(String(v))) untrusted.push(key);   // 프롬프트에서 뽑은 값 → 셸로 갈 때 따옴표 처리 대상
    args[key] = String(v).replace(/\$(\d)/g, (_, i) => m[Number(i)] || '');
  }
  const res = r.program
    ? F.startProgram(root, { task: String(r.program.task || prompt).replace(/\$(\d)/g, (_, i) => m[Number(i)] || ''), doneWhen: r.program.done_when, session: ev.session_id, promptId: ev.prompt_id })
    : F.start(root, F.resolveFlowPath(root, r.flow), args, { session: ev.session_id, promptId: ev.prompt_id, untrusted });
  L.log(root, { ev: 'route', flow: r.program ? 'program' : r.flow, args, ok: !res.error });
  if (res.error) return ctxOut(C, `[step-harness] Could not start the flow: ${res.error}\nTell the user this error and stop.`);
  J.settle(root, { trigger: 'prompt', waitMs: wait });
  ({ flow, state } = L.load(root));
  ctxOut(C, `[step-harness] RESOLVED_ACTION: flow=${flow.flow} args=${JSON.stringify(args)}\n${L.renderNext(flow, state)}`);
}

// ───────── Stop
function stop(C) {
  const { ev, root } = C;
  let { flow, state } = L.load(root);
  if (!live(flow, state) || state.mode === 'runner' || isForeign(state, ev)) return;
  const tellHuman = () => {   // handoff: 아직 알리지 않았다면 한 번만 막고 사람에게 전하게 한다
    let first = false;
    L.withLock(root, () => {
      const s = L.load(root).state;
      if (s.status === 'handoff' && !s.handoff.announced) { s.handoff.announced = true; if (!s.handoff.promptId) s.handoff.promptId = ev.prompt_id || null; L.saveState(root, s); first = true; state = s; }
    });
    if (first) blockStop(C, L.renderNext(flow, state));
  };
  if (state.status === 'handoff') return tellHuman();

  const cfg = L.config(root);
  let midFlight = false;
  L.withLock(root, () => {
    const s = L.load(root).state;
    if (s.status !== 'running') return;
    const prog = L.kind(flow.actions[s.action]) === 'program';   // 프로그램 실행 중: 아래 settle 로 가서 기다린다 (실행 구간은 건드리지 않는다)
    if (fresh(s, s.inFlight) && !prog) {
      // NEXT_ACTION 실행 구간 중의 Stop. 서브에이전트의 종료일 수도, PostToolUse 없이 끝난(취소 등) 메인의 종료일 수도 있다.
      //   기본: 건드리지 않는다 (종료 허용). 메인이었다면 다음 프롬프트에서 실행 구간을 닫고 NEXT_ACTION 을 다시 준다.
      //   PostToolUse 가 원래 안 오는 환경이면 config.assume_done_on_stop 으로 "호출됨"으로 친다 (성공 여부는 어차피 check 가 판정).
      if (!cfg.assume_done_on_stop) { midFlight = true; return; }
      if (!fresh(s, s.receipt)) s.receipt = { seq: s.seq, ok: true, tool: s.inFlight.tool, assumed: true, at: new Date().toISOString() };
      s.inFlight = null;
    }
    if (ev.prompt_id) s.lastPromptId = ev.prompt_id;
    L.saveState(root, s);
  });
  if (midFlight) { L.log(root, { ev: 'Stop', decision: 'allow', why: 'in-flight' }); return; }
  const settled = J.settle(root, { trigger: 'stop', waitMs: cfg.wait.stop * 1000 });   // 판정이 곧 끝나면 기다렸다가 직접 다음 단계로
  ({ flow, state } = L.load(root));
  if (settled === 'pending' && state.status === 'running') {   // 판정이 아직 도는 중 — 횟수는 세지 않는다 (판정에는 자체 시간 제한이 있다)
    L.log(root, { ev: 'Stop', decision: 'block', why: 'verifying' });
    const what = L.kind(flow.actions[state.action]) === 'program' ? 'program' : 'verification';
    return blockStop(C, `[step-harness] You cannot stop yet: the ${what} is still running.\n${L.renderNext(flow, state)}`);
  }
  if (state.status === 'done') {   // 이 Stop 안에서 흐름이 끝났다 → 결과를 사용자에게 전하도록 한 번만 붙잡는다 (다음 Stop 은 통과)
    L.log(root, { ev: 'Stop', decision: 'block', why: 'report-done' });
    return blockStop(C, L.renderNext(flow, state));
  }
  if (state.status === 'handoff') return tellHuman();
  if (state.status !== 'running') return;

  let over = false;
  L.withLock(root, () => {
    const s = L.load(root).state;
    if (s.status !== 'running') { state = s; return; }
    if (!L.isDup(s, ev, C.src)) s.stopBlocks = (s.stopBlocks || 0) + 1;
    if (s.stopBlocks > flow.max_stop_blocks) {
      const next = F.handoff(flow, { ...s, lastPromptId: ev.prompt_id || s.lastPromptId }, `모델이 ${s.action} 을(를) 끝내지 않은 채 ${flow.max_stop_blocks}회 넘게 멈추려 함`);
      next.handoff.announced = true;
      L.saveState(root, next); state = next; over = true;
    } else { L.saveState(root, s); state = s; }
  });
  if (over) {   // 무한 루프 방지: 종료를 허용하고 사유를 화면에 남긴다
    L.log(root, { ev: 'Stop', decision: 'allow', why: 'stop-limit→handoff' });
    return endTurn(C, L.handoffQuestion(flow, state));
  }
  if (state.status !== 'running') return;
  L.log(root, { ev: 'Stop', decision: 'block', n: state.stopBlocks });
  blockStop(C, `[step-harness] You cannot stop yet (${state.stopBlocks}/${flow.max_stop_blocks}).\n${L.renderNext(flow, state)}`);
}

function sessionStart(C) {
  const { flow, state } = L.load(C.root);
  if (!live(flow, state) || state.mode === 'runner') return;
  const prog = state.status === 'running' && L.kind(flow.actions[state.action]) === 'program';
  if (prog || !fresh(state, state.inFlight)) ctxOut(C, L.renderNext(flow, state));
}
function permissionRequest(C) {   // 선택 기능: 하네스 CLI 호출의 승인 프롬프트 생략 (config.auto_approve_cli)
  if (C.tool === 'exec' && L.harnessCmd(C.root, C.input.command) && L.config(C.root).auto_approve_cli) C.R.o.decision = 'approve';
}

// probe 모드: .step-harness/probe 파일이 있으면 모든 이벤트의 형태를 기록 (실환경 스키마 확인용 → `harness.cjs doctor`)
function probe(C) {
  if (!fs.existsSync(L.sp(C.root, 'probe'))) return;
  const { ev, env } = C;
  const clip = (v) => JSON.parse(JSON.stringify(v || null, (k, x) => (typeof x === 'string' && x.length > 200 ? x.slice(0, 200) + '…' : x)));
  L.append(C.root, 'probe.jsonl', { ev: ev.hook_event_name, sid: ev.session_id || null, pid: ev.prompt_id || null, tool: ev.tool_name || null,
    payload_keys: Object.keys(ev), input: clip(ev.tool_input), response_keys: Object.keys(ev.tool_response || {}), provenance: clip(ev.tool_provenance),
    env: Object.fromEntries(['DEVIN_PLUGIN_ROOT', 'PLUGIN_ROOT', 'PLUGIN_DATA', 'CLAUDE_PLUGIN_ROOT', 'DEVIN_PROJECT_DIR', 'CLAUDE_PROJECT_DIR'].map((key) => [key, env[key] || null])) });
}

// hook 내부 오류: 흐름이 살아 있으면 읽기 전용이 아닌 호출은 막는다 (조용히 풀리는 것 방지)
function failClosed(C, e) {
  const msg = (e && e.message) || String(e);
  C.R.o = {};
  C.R.err = `[step-harness] hook error: ${msg}`;
  C.R.code = 1;
  if (C.ev.hook_event_name !== 'PreToolUse') return;
  let alive = true;   // 상태를 읽지 못하면 살아 있다고 본다
  try { const { flow, state } = L.load(C.root); alive = live(flow, state); } catch { /* 그대로 true */ }
  let isCli = false;
  try { isCli = C.tool === 'exec' && !!L.harnessCmd(C.root, C.input.command); } catch { /* false */ }
  if (alive && !L.DEFAULT_PASSIVE.includes(C.tool) && !isCli) {
    blockTool(C, `[step-harness] BLOCKED ${C.tool}: internal harness error (${msg}). Do not continue. Tell the user to run: ${L.cli('reset')}`);
  }
}

// 상태 폴더가 없는 프로젝트라도, 프롬프트가 플러그인 기본 규칙(예: "프로그램: …")에 맞으면 그 자리에서 시작한다
function optIn(ev) {
  if (ev.hook_event_name !== 'UserPromptSubmit') return false;
  const r = L.readJson(path.join(L.PLUGIN_DIR, 'router.json'), null);
  const prompt = String(ev.prompt || '').trim();
  return !!(r && Array.isArray(r.routes) && r.routes.some((x) => { try { return new RegExp(x.when, 'i').test(prompt); } catch { return false; } }));
}
function handle(ev, env = process.env) {
  const R = { code: 0, o: {}, err: '' };
  const root = L.findRoot(env.DEVIN_PROJECT_DIR || env.CLAUDE_PROJECT_DIR || ev.cwd);
  if (!fs.existsSync(path.join(root, L.DIR)) && !optIn(ev)) return R;   // 이 프로젝트는 하네스를 쓰지 않는다
  const C = { ev, env, root, R, tool: L.normTool(ev.tool_name || ''), input: ev.tool_input || {}, devin: !!(env.DEVIN_PROJECT_DIR || env.DEVIN_PLUGIN_ROOT),
    src: env.STEP_HARNESS_HOOK ? 'project' : 'plugin', worker: env.STEP_HARNESS_WORKER || null };   // 어느 설치본이 부른 hook 인가 (중복 설치 판별용)
  try {
    probe(C);
    // 작업자의 Stop·프롬프트·결과는 흐름에 끼어들지 않는다 (판정은 프로그램이 한다. 끝난 실행의 작업자도 마찬가지)
    if (C.worker && ev.hook_event_name !== 'PreToolUse' && ev.hook_event_name !== 'PermissionRequest') return R;
    switch (ev.hook_event_name) {
      case 'PreToolUse': L.withLock(root, () => preToolUse(C)); announce(C); break;
      case 'PostToolUse': postToolUse(C); announce(C); break;
      case 'UserPromptSubmit': userPromptSubmit(C); break;
      case 'Stop': stop(C); break;
      case 'SessionStart': sessionStart(C); break;
      case 'PermissionRequest': permissionRequest(C); break;
      default: break;
    }
  } catch (e) { failClosed(C, e); }
  // 흐름이 사람에게 넘어갔거나 멈췄는데 프로그램이 아직 돌고 있으면 정리 (여기서 난 오류가 위의 판정을 바꾸지 않게 따로 감싼다)
  if (!C.worker) { try { J.reapExec(root); } catch { /* 다음 이벤트에서 다시 시도 */ } }
  return R;
}

if (require.main === module) {
  let ev = {};
  try { ev = JSON.parse(fs.readFileSync(0, 'utf8') || '{}'); } catch { /* 빈 입력 */ }
  const R = handle(ev);
  try { if (Object.keys(R.o).length) fs.writeSync(1, JSON.stringify(R.o)); } catch { /* 닫힌 파이프 */ }
  try { if (R.err) fs.writeSync(2, R.err + '\n'); } catch { /* 닫힌 파이프 */ }
  process.exitCode = R.code;
}
module.exports = { handle };
