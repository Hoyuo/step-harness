'use strict';
// 프로그램 모드 (Code Mode): 모델이 한 걸음씩 도구를 부르는 대신, 좁은 API `h` 에 대한 TS 부분집합 프로그램을 낸다.
// 하네스는 실행 전에 정적으로 검증하고(문법 자체가 좁다 + 규칙 검사), 검증된 프로그램만 결정적으로 실행한다.
//
//   async (h) => {
//     for (const attempt of h.retries(3)) {
//       const r = await h.check("code-complete");
//       if (r.pass) return h.done("code complete");
//       if (r.route === "unit-test") await h.skill("eats-write-unit-test", r.report, { scope: ["lib/**", "test/**"] });
//       else await h.agent("fixer", `Fix every failure in ${r.report}`, { scope: ["lib/**", "test/**"] });
//     }
//     return h.handoff("3회 시도 후에도 실패");
//   }
//
// 허용 문법: const · if/else · for (const x of h.retries(N)) · break · continue · return · await
//            h.<메서드>(…) 호출 · 멤버 접근 · === !== && || ! · 문자열/템플릿/숫자/true/false/null · 배열/객체 리터럴
// 그 외(대입, while, 함수 정의, 임의 호출, import …)는 파서가 받지 않는다.
const path = require('path');

const gateCmd = (g) => (typeof g === 'string' ? g : (g && typeof g.cmd === 'string' ? g.cmd : '')).trim();
const MAX_RETRIES = 10;
const MAX_ITERATIONS = 1000;   // 겹친 h.retries 반복 횟수의 곱 상한 (정적)
const MAX_OPS = 100000;        // 실행 중 문장·반복 횟수 상한 (동적. 일을 하지 않는 반복이 프로세스를 붙잡지 못하게)
const MAX_SOURCE = 20000;      // 프로그램 길이 상한 (문자)
const BAD_PROPS = new Set(['__proto__', 'constructor', 'prototype']);
const WORK_CALLS = new Set(['check', 'work', 'skill', 'agent']);

// ───────── 토크나이저
function tokenize(src) {
  const T = [];
  let i = 0, line = 1, col = 1;
  const err = (msg) => { const e = new Error(`${line}:${col} ${msg}`); e.syntax = true; throw e; };
  const adv = (n) => { for (let k = 0; k < n; k++) { if (src[i] === '\n') { line++; col = 1; } else col++; i++; } };
  const PUNCT = ['===', '!==', '==', '!=', '=>', '&&', '||', '?.', '(', ')', '{', '}', '[', ']', ',', ';', '.', ':', '!', '='];
  const HINT = { '?': 'no ternary — use if/else', '+': 'no + — build strings with a template literal `…${x}…`', '-': 'no arithmetic', '*': 'no arithmetic', '/': 'no arithmetic',
    '<': 'only === and !== comparisons', '>': 'only === and !== comparisons', '|': 'use ||', '&': 'use &&', '#': 'not allowed', '@': 'not allowed' };
  while (i < src.length) {
    const c = src[i];
    if (/\s/.test(c)) { adv(1); continue; }
    if (src.startsWith('//', i)) { while (i < src.length && src[i] !== '\n') adv(1); continue; }
    if (src.startsWith('/*', i)) { const e = src.indexOf('*/', i + 2); if (e < 0) err('unterminated comment'); adv(e + 2 - i); continue; }
    const at = { line, col };
    if (/[A-Za-z_$]/.test(c)) { const m = /^[A-Za-z_$][\w$]*/.exec(src.slice(i))[0]; T.push({ t: 'id', v: m, ...at }); adv(m.length); continue; }
    if (/\d/.test(c)) { const m = /^\d+(?:\.\d+)?/.exec(src.slice(i))[0]; T.push({ t: 'num', v: Number(m), ...at }); adv(m.length); continue; }
    if (c === '"' || c === "'") {
      let j = i + 1, s = '';
      while (j < src.length && src[j] !== c) {
        if (src[j] === '\n') err('newline in string');
        if (src[j] === '\\') { const n = src[j + 1]; s += n === 'n' ? '\n' : n === 't' ? '\t' : n; j += 2; } else s += src[j++];
      }
      if (j >= src.length) err('unterminated string');
      T.push({ t: 'str', v: s, ...at }); adv(j + 1 - i); continue;
    }
    if (c === '`') {   // 템플릿: 문자열 조각과 ${식} 조각
      const parts = [];
      let j = i + 1, s = '';
      for (;;) {
        if (j >= src.length) err('unterminated template');
        if (src[j] === '`') break;
        if (src[j] === '\\') { const n = src[j + 1]; s += n === 'n' ? '\n' : n === 't' ? '\t' : n; j += 2; continue; }
        if (src[j] === '$' && src[j + 1] === '{') {
          parts.push(s); s = '';
          let depth = 1, k = j + 2;
          while (k < src.length && depth) {
            const ch = src[k];
            if (ch === '"' || ch === "'") {   // 문자열 안의 중괄호는 세지 않는다
              k++;
              while (k < src.length && src[k] !== ch) k += src[k] === '\\' ? 2 : 1;
              k++; continue;
            }
            if (ch === '{') depth++; else if (ch === '}') depth--;
            if (depth) k++;
          }
          if (depth) err('unterminated ${ in template');
          parts.push({ expr: src.slice(j + 2, k) });
          j = k + 1; continue;
        }
        s += src[j++];
      }
      parts.push(s);
      T.push({ t: 'tpl', v: parts, ...at }); adv(j + 1 - i); continue;
    }
    const p = PUNCT.find((x) => src.startsWith(x, i));
    if (!p) { T.push({ t: 'bad', v: c, msg: `unsupported character "${c}"` + (HINT[c] ? ` (${HINT[c]})` : ''), ...at }); adv(1); continue; }
    if (p === '==' || p === '!=') { T.push({ t: 'bad', v: p, msg: `"${p}" is not supported (use ${p}=)`, ...at }); adv(p.length); continue; }
    T.push({ t: 'p', v: p, ...at }); adv(p.length);
  }
  T.push({ t: 'eof', v: '', line, col });
  return T;
}

// ───────── 파서 (허용 문법만)
const KEYWORDS = new Set(['const', 'if', 'else', 'for', 'of', 'return', 'break', 'continue', 'await', 'async', 'true', 'false', 'null']);
const FORBIDDEN = new Set(['let', 'var', 'while', 'do', 'function', 'class', 'new', 'import', 'export', 'require', 'eval', 'try', 'throw', 'switch', 'with', 'delete', 'yield', 'this', 'globalThis', 'process']);
const forbidden = (w) => `"${w}" is not allowed in a harness program` + ({ let: ' (use const)', var: ' (use const)', while: ' (use for (const i of h.retries(N)))', function: ' (write the whole program as one async (h) => { … })' }[w] || '');
function parse(src) {
  const T = tokenize(String(src));
  let p = 0;
  const peek = (o = 0) => T[p + o];
  const err = (msg, tk = peek()) => { const e = new Error(`${tk.line}:${tk.col} ${tk.t === 'bad' ? tk.msg : msg}`); e.syntax = true; throw e; };
  const is = (t, v, o = 0) => peek(o).t === t && (v === undefined || peek(o).v === v);
  const eat = (t, v) => { if (!is(t, v)) err(`expected ${v || t}, got "${peek().v || peek().t}"`); return T[p++]; };
  const opt = (t, v) => (is(t, v) ? T[p++] : null);
  const ident = () => {
    const tk = eat('id');
    if (FORBIDDEN.has(tk.v)) err(forbidden(tk.v), tk);
    if (KEYWORDS.has(tk.v)) err(`unexpected keyword "${tk.v}"`, tk);
    return tk;
  };
  const semi = () => opt('p', ';');
  // 타입 표기를 건너뛴다: 괄호 깊이 0 에서 stop 토큰을 만날 때까지 (타입 안의 < > 같은 문자는 여기서 소비되어 오류가 되지 않는다)
  const skipType = (stop) => {
    let depth = 0;
    for (;;) {
      const tk = peek();
      if (tk.t === 'eof') err('unterminated type annotation');
      if (!depth && tk.t === 'p' && tk.v === stop) return;
      if ((tk.t === 'p' && '([{'.includes(tk.v)) || tk.v === '<') depth++;
      else if ((tk.t === 'p' && ')]}'.includes(tk.v)) || tk.v === '>') depth = Math.max(0, depth - 1);
      p++;
    }
  };

  function program() {
    opt('p', '(');   // (async (h) => {...}) 처럼 괄호로 감싸도 된다
    const wrapped = T[p - 1] && T[p - 1].v === '(' && p === 1;
    eat('id', 'async');
    eat('p', '(');
    const param = ident();
    if (opt('p', ':')) skipType(')');   // (h: H) 같은 타입 표기는 받고 무시한다
    eat('p', ')');
    if (opt('p', ':')) skipType('=>');  // ): Promise<void> => 도 마찬가지
    eat('p', '=>');
    const body = block();
    if (wrapped) eat('p', ')');
    semi();
    if (!is('eof')) err('only one async arrow function is allowed');
    return { type: 'Program', param: param.v, body };
  }
  function block() {
    const at = eat('p', '{');
    const body = [];
    while (!is('p', '}')) { if (is('eof')) err('unterminated block', at); body.push(stmt()); }
    eat('p', '}');
    return { type: 'Block', body, at };
  }
  const stmtOrBlock = () => (is('p', '{') ? block() : { type: 'Block', body: [stmt()], at: peek() });
  function stmt() {
    const at = peek();
    if (at.t === 'id' && FORBIDDEN.has(at.v)) err(forbidden(at.v));
    if (opt('id', 'const')) {
      if (is('p', '{') || is('p', '[')) err('destructuring is not supported (write "const r = …;" and then r.pass, r.route, …)');
      const name = ident();
      if (opt('p', ':')) skipType('=');
      eat('p', '=');
      const init = expr();
      semi();
      return { type: 'Const', name: name.v, init, at };
    }
    if (opt('id', 'if')) {
      eat('p', '('); const test = expr(); eat('p', ')');
      const then = stmtOrBlock();
      const els = opt('id', 'else') ? stmtOrBlock() : null;
      return { type: 'If', test, then, els, at };
    }
    if (opt('id', 'for')) {
      const LOOP = 'the only loop is "for (const i of h.retries(N))"';
      eat('p', '(');
      if (!is('id', 'const')) err(LOOP);
      eat('id', 'const'); const name = ident();
      if (!is('id', 'of')) err(LOOP);
      eat('id', 'of'); const iter = expr(); eat('p', ')');
      return { type: 'For', name: name.v, iter, body: stmtOrBlock(), at };
    }
    if (opt('id', 'return')) {
      const arg = is('p', ';') || is('p', '}') ? null : expr();
      semi();
      return { type: 'Return', arg, at };
    }
    if (opt('id', 'break')) { semi(); return { type: 'Break', at }; }
    if (opt('id', 'continue')) { semi(); return { type: 'Continue', at }; }
    const e = expr();
    semi();
    return { type: 'Expr', expr: e, at };
  }
  function expr() { return or(); }
  function bin(next, ops) {
    return () => {
      let l = next();
      while (peek().t === 'p' && ops.includes(peek().v)) { const op = T[p++]; l = { type: 'Bin', op: op.v, l, r: next(), at: op }; }
      return l;
    };
  }
  const eq = bin(unary, ['===', '!==']);
  const and = bin(eq, ['&&']);
  const or = bin(and, ['||']);
  function unary() {
    const at = peek();
    if (opt('p', '!')) return { type: 'Not', arg: unary(), at };
    if (opt('id', 'await')) return { type: 'Await', arg: unary(), at };
    return postfix();
  }
  function postfix() {
    let e = primary();
    for (;;) {
      const at = peek();
      if (is('p', '.') || is('p', '?.')) {   // r.route / r?.route (Opus 가 습관적으로 쓰는 ?. 도 받는다: 둘 다 없으면 undefined)
        const optional = T[p++].v === '?.';
        const name = eat('id');
        if (BAD_PROPS.has(name.v)) err(`property "${name.v}" is not allowed`, name);
        e = { type: 'Member', obj: e, prop: name.v, optional, at };
      } else if (opt('p', '(')) {
        const args = [];
        while (!is('p', ')')) { args.push(expr()); if (!opt('p', ',')) break; }
        eat('p', ')');
        e = { type: 'Call', callee: e, args, at };
      } else {
        if (is('p', '=>')) err(forbidden('function'));
        return e;
      }
    }
  }
  function primary() {
    const tk = peek();
    if (tk.t === 'str') { p++; return { type: 'Lit', v: tk.v, at: tk }; }
    if (tk.t === 'num') { p++; return { type: 'Lit', v: tk.v, at: tk }; }
    if (tk.t === 'tpl') {
      p++;
      return { type: 'Tpl', parts: tk.v.map((x) => (typeof x === 'string' ? x : subExpr(x.expr, tk))), at: tk };
    }
    if (tk.t === 'id' && ['true', 'false', 'null'].includes(tk.v)) { p++; return { type: 'Lit', v: tk.v === 'null' ? null : tk.v === 'true', at: tk }; }
    if (tk.t === 'id') { ident(); return { type: 'Id', name: tk.v, at: tk }; }
    if (opt('p', '(')) {
      if (is('p', ')') && is('p', '=>', 1)) err(forbidden('function'));
      const e = expr(); eat('p', ')'); return e;
    }
    if (opt('p', '[')) {
      const items = [];
      while (!is('p', ']')) { items.push(expr()); if (!opt('p', ',')) break; }
      eat('p', ']');
      return { type: 'Arr', items, at: tk };
    }
    if (opt('p', '{')) {
      const props = [];
      const seen = new Set();
      while (!is('p', '}')) {
        const k = is('str') ? T[p++] : eat('id');
        if (BAD_PROPS.has(k.v)) err(`property "${k.v}" is not allowed`, k);
        if (seen.has(k.v)) err(`duplicate key "${k.v}"`, k);
        seen.add(k.v);
        eat('p', ':');
        props.push([k.v, expr()]);
        if (!opt('p', ',')) break;
      }
      eat('p', '}');
      return { type: 'Obj', props, at: tk };
    }
    return err(`unexpected "${tk.v || tk.t}"`);
  }
  function subExpr(code, tk) {   // 템플릿 안의 ${식}: 같은 문법으로 따로 파싱
    const inner = tokenize(code);
    const save = { T: T.slice(), p };
    T.length = 0; T.push(...inner.map((x) => ({ ...x, line: tk.line, col: tk.col })));
    p = 0;
    const e = expr();
    if (!is('eof')) err('unexpected token in template expression');
    T.length = 0; T.push(...save.T); p = save.p;
    return e;
  }
  return program();
}

// 쓰기 범위(glob) 하나가 받아들일 만한가. 문제가 있으면 이유(문자열), 없으면 null
//   writable 목록이 있으면: 그 목록에 있는 것만 (관리자가 정한 범위)
//   없으면: 첫 경로 조각이 와일드카드 없는 이름이어야 하고("src/**"), 숨김 경로(.git · .devin · .github …)는 안 된다
function scopeError(g, writable) {
  if (typeof g === 'string' && g.split('/').some((seg) => seg.startsWith('-'))) return 'a path segment may not start with "-" (it would look like a command option)';
  if (typeof g !== 'string' || !g.trim()) return 'empty';
  if (/[<>]/.test(g)) return 'replace the placeholder with a real path';
  if (path.isAbsolute(g) || g.includes('\\') || g.split('/').includes('..')) return 'only relative paths inside the project';
  if (g.toLowerCase().includes('.step-harness')) return 'harness files cannot be written';
  if (Array.isArray(writable)) return writable.includes(g) ? null : `not in the writable list (${writable.join(', ')})`;
  const first = g.replace(/^(?:\.\/)+/, '').split('/')[0];
  if (!first || /[*?]/.test(first)) return 'too broad; start with a directory or file name (e.g. "src/**")';
  if (first.startsWith('.')) return 'hidden paths (starting with ".") can be written only if config.json "writable" lists them';
  return null;
}

// ───────── 정적 검증
// reg: { gates: {name: cmd|{cmd,about}}, skills?: {name: about}, agents?: {name: about}, writable?: [glob] }
function verify(ast, reg = {}) {
  const E = [];
  const at = (n) => (n && n.at ? `${n.at.line}:${n.at.col} ` : '');
  const h = ast.param;
  const gates = reg.gates || {};
  const hcall = (n) => n && n.type === 'Call' && n.callee.type === 'Member' && n.callee.obj.type === 'Id' && n.callee.obj.name === h ? n.callee.prop : null;
  const unwrap = (n) => (n && n.type === 'Await' ? n.arg : n);
  const strLit = (n) => n && n.type === 'Lit' && typeof n.v === 'string';
  let workCalls = 0;

  function checkScope(call, opts) {
    if (!opts || opts.type !== 'Obj') return E.push(`${at(call)}h.${hcall(call)}: the last argument must be { scope: ["glob", …] }`);
    for (const [k] of opts.props) if (k !== 'scope') E.push(`${at(opts)}unknown option "${k}" (only scope)`);
    if (opts.props.filter(([k]) => k === 'scope').length > 1) return E.push(`${at(opts)}scope is given more than once`);
    const sc = (opts.props.find(([k]) => k === 'scope') || [])[1];
    if (!sc || sc.type !== 'Arr' || !sc.items.length || !sc.items.every(strLit)) return E.push(`${at(call)}h.${hcall(call)}: scope must be a non-empty array of string literals`);
    for (const g of sc.items.map((x) => x.v)) {
      const why = scopeError(g, reg.writable);
      if (why) E.push(`${at(sc)}scope "${g}": ${why}`);
    }
  }
  function callRules(n, ctx) {
    const m = hcall(n);
    if (!m) return E.push(`${at(n)}only h.<method>(…) can be called`);
    const a = n.args;
    const known = ['check', 'work', 'skill', 'agent', 'done', 'handoff', 'retries'];
    if (!known.includes(m)) return E.push(`${at(n)}h.${m} does not exist (h.${known.join(', h.')})`);
    if ((m === 'done' || m === 'handoff') && ctx !== 'return') E.push(`${at(n)}h.${m}() must be used as "return h.${m}(…)"`);
    if (m === 'retries' && ctx !== 'for') E.push(`${at(n)}h.retries() is only allowed as "for (const x of h.retries(N))"`);
    if (WORK_CALLS.has(m) && ctx === 'return') E.push(`${at(n)}return h.done(…) or h.handoff(…), not h.${m}`);
    if (WORK_CALLS.has(m)) workCalls++;
    if (m === 'check') {
      if (a.length !== 1 || !strLit(a[0])) E.push(`${at(n)}h.check takes one gate name as a string literal`);
      else if (!Object.prototype.hasOwnProperty.call(gates, a[0].v)) E.push(`${at(n)}unknown gate "${a[0].v}" (known: ${Object.keys(gates).join(', ') || 'none — register gates in config.json'})`);
      else if (!gateCmd(gates[a[0].v])) E.push(`${at(n)}gate "${a[0].v}" has no command in config.json`);
    }
    if (m === 'work') {
      if (a.length !== 2) E.push(`${at(n)}h.work(task: string, { scope: [...] })`);
      checkScope(n, a[a.length - 1]);
    }
    if (m === 'skill' || m === 'agent') {
      const sect = (m === 'skill' ? reg.skills : reg.agents) || {};
      const names = Object.keys(sect);
      if (!names.length) E.push(`${at(n)}h.${m} is not available: no ${m}s are registered in config.json "${m}s" — use h.work`);
      else if (a.length !== 3 || !strLit(a[0])) E.push(`${at(n)}h.${m}(name: string literal, ${m === 'skill' ? 'args' : 'task'}: string, { scope: [...] })`);
      else if (!Object.prototype.hasOwnProperty.call(sect, a[0].v)) E.push(`${at(n)}unknown ${m} "${a[0].v}" (known: ${names.join(', ')})`);
      checkScope(n, a[a.length - 1]);
    }
    if (m === 'retries' && (a.length !== 1 || a[0].type !== 'Lit' || !Number.isInteger(a[0].v) || a[0].v < 1 || a[0].v > MAX_RETRIES)) {
      E.push(`${at(n)}h.retries(N): N must be an integer literal 1..${MAX_RETRIES}`);
    }
    if ((m === 'done' || m === 'handoff') && a.length > 1) E.push(`${at(n)}h.${m} takes at most one message`);
    if (m !== 'check' && m !== 'retries') for (const x of a) walkExpr(x, scopeOf(n));
  }
  let scopes = [new Set([h])];
  let iterations = 1;
  const scopeOf = () => scopes[scopes.length - 1];
  function walkExpr(n, vars, ctx) {
    if (!n) return;
    switch (n.type) {
      case 'Lit': return;
      case 'Tpl': n.parts.forEach((x) => typeof x !== 'string' && walkExpr(x, vars)); return;
      case 'Id':
        if (n.name === h) E.push(`${at(n)}"${h}" can only be used as ${h}.<method>(…)`);
        else if (!scopes.some((s) => s.has(n.name))) E.push(`${at(n)}"${n.name}" is not defined`);
        return;
      case 'Member':
        if (n.obj.type === 'Id' && n.obj.name === h) return E.push(`${at(n)}h.${n.prop} must be called`);
        return walkExpr(n.obj, vars);
      case 'Call': return callRules(n, ctx);
      case 'Await': return walkExpr(n.arg, vars, ctx);
      case 'Not': return walkExpr(n.arg, vars);
      case 'Bin': walkExpr(n.l, vars); walkExpr(n.r, vars); return;
      case 'Arr': n.items.forEach((x) => walkExpr(x, vars)); return;
      case 'Obj': n.props.forEach(([, x]) => walkExpr(x, vars)); return;
      default: E.push(`${at(n)}unsupported expression`);
    }
  }
  // 반환값: 이 문장 목록이 항상 return 으로 끝나는가
  function walkBlock(b, inLoop) {
    scopes.push(new Set());
    let ends = false;
    b.body.forEach((s, i) => {
      if (ends) E.push(`${at(s)}unreachable statement`);
      const t = walkStmt(s, inLoop);
      if (t && i === b.body.length - 1) ends = true;
      else if (t) ends = true;
    });
    scopes.pop();
    return ends;
  }
  function walkStmt(s, inLoop) {
    switch (s.type) {
      case 'Const':
        if (s.name === h) E.push(`${at(s)}cannot redeclare ${h}`);
        else if (scopes.some((x) => x.has(s.name))) E.push(`${at(s)}"${s.name}" is already defined`);
        walkExpr(s.init, scopeOf());
        scopeOf().add(s.name);
        return false;
      case 'If': {
        walkExpr(s.test, scopeOf());
        const a = walkBlock(s.then, inLoop);
        const b = s.els ? walkBlock(s.els, inLoop) : false;
        return a && b;
      }
      case 'For': {
        const it = unwrap(s.iter);
        if (hcall(it) !== 'retries') E.push(`${at(s)}for-of only over h.retries(N)`);
        else walkExpr(it, scopeOf(), 'for');
        if (s.name === h) E.push(`${at(s)}cannot redeclare ${h}`);
        else if (scopes.some((x) => x.has(s.name))) E.push(`${at(s)}"${s.name}" is already defined`);
        const n = it && it.args && it.args[0] && Number.isInteger(it.args[0].v) ? it.args[0].v : 1;
        const outer = iterations;
        iterations *= n;
        if (iterations > MAX_ITERATIONS && outer <= MAX_ITERATIONS) E.push(`${at(s)}nested h.retries loops multiply to more than ${MAX_ITERATIONS} iterations`);
        scopes.push(new Set([s.name]));
        walkBlock(s.body, true);
        scopes.pop();
        iterations = outer;
        return false;   // 반복이 다 돌 수 있으므로 끝난 것으로 치지 않는다
      }
      case 'Return': {
        const c = unwrap(s.arg);
        const m = hcall(c);
        if (m !== 'done' && m !== 'handoff') E.push(`${at(s)}return must be "return h.done(…)" or "return h.handoff(…)"`);
        if (c) walkExpr(c, scopeOf(), 'return');
        return true;
      }
      case 'Break': case 'Continue':
        if (!inLoop) E.push(`${at(s)}${s.type.toLowerCase()} outside a loop`);
        return true;   // 같은 블록의 다음 문장은 도달 불가
      case 'Expr': {
        const c = unwrap(s.expr);
        if (!hcall(c) || !WORK_CALLS.has(hcall(c))) E.push(`${at(s)}a statement must be a call to h.check / h.work / h.skill / h.agent`);
        walkExpr(s.expr, scopeOf(), 'stmt');
        return false;
      }
      default: E.push(`${at(s)}unsupported statement`); return false;
    }
  }
  const ends = walkBlock(ast.body, false);
  if (!ends) E.push('every path must end with "return h.done(…)" or "return h.handoff(…)" (the end of the function is reachable)');
  if (!workCalls) E.push('the program never calls h.check / h.work / h.skill / h.agent');
  return E;
}

// ───────── 타입 선언: 모델에게 보여주는 "SDK" (등록된 이름이 리터럴 유니언 타입으로 들어간다. 등록되지 않은 종류의 메서드는 보여주지 않는다)
function declaration(reg = {}, doneWhen = []) {
  const names = (o) => Object.keys(o || {});
  const u = (o) => names(o).map((x) => JSON.stringify(x)).join(' | ');
  const scope = Array.isArray(reg.writable) && reg.writable.length ? `(${reg.writable.map((x) => JSON.stringify(x)).join(' | ')})[]` : 'string[]';
  return [
    'type Verdict = { pass: boolean; route: string | null; report: string; exit: number };   // report = path of the check\'s output file',
    'type Result  = { ok: boolean };',
    'declare const h: {',
    ...(names(reg.gates).length ? [`  check(gate: ${u(reg.gates)}): Promise<Verdict>;   // the harness runs this registered check itself`] : []),
    `  work(task: string, opts: { scope: ${scope} }): Promise<Result>;   // YOU do this task when its step comes; you can write only inside scope`,
    ...(names(reg.skills).length ? [`  skill(name: ${u(reg.skills)}, args: string, opts: { scope: ${scope} }): Promise<Result>;   // when its step comes you invoke this skill, exactly once`] : []),
    ...(names(reg.agents).length ? [`  agent(profile: ${u(reg.agents)}, task: string, opts: { scope: ${scope} }): Promise<Result>;   // when its step comes you start this subagent with this task, exactly once`] : []),
    `  retries(n: 1..${MAX_RETRIES}): Iterable<number>;   // only in: for (const i of h.retries(n))`,
    '  done(message?: string): never;      // only in: return h.done(…)' + (doneWhen.length ? ` — accepted only if ${doneWhen.map((g) => JSON.stringify(g)).join(' and ')} pass${doneWhen.length > 1 ? '' : 'es'} (the harness runs ${doneWhen.length > 1 ? 'them' : 'it'} itself)` : ''),
    '  handoff(reason?: string): never;    // only in: return h.handoff(…) — asks the human',
    '};',
  ].join('\n');
}

// 프롬프트에 넣는 예시 한 개 (등록된 이름으로 만든다. 범위 자리표시만 채우면 검증을 통과하는 모양)
function example(reg = {}, doneWhen = []) {
  const q = (x) => JSON.stringify(x);
  const gate = doneWhen[0] || Object.keys(reg.gates || {})[0];
  const scope = Array.isArray(reg.writable) && reg.writable.length ? `[${reg.writable.slice(0, 2).map(q).join(', ')}]` : '["<dir>/**"]';
  if (gate) {
    return ['async (h) => {', `  await h.work("<what to change, in full sentences>", { scope: ${scope} });`, '  for (const attempt of h.retries(3)) {', `    const r = await h.check(${q(gate)});`,
      '    if (r.pass) return h.done("<what is now true>");', `    await h.work(\`Fix every failure listed in \${r.report}\`, { scope: ${scope} });`, '  }',
      '  return h.handoff("still failing after 3 attempts");', '}'].join('\n');
  }
  return ['async (h) => {', `  await h.work("<what to change, in full sentences>", { scope: ${scope} });`, '  return h.done("<what was done>");', '}'].join('\n');
}

// ───────── 실행 (검증된 AST 만). host: { check(name), work(task,scope), skill(name,args,scope), agent(name,task,scope), maxSteps }
const BREAK = Symbol('break'), CONTINUE = Symbol('continue');
function run(ast, host) {
  const h = ast.param;
  let steps = 0;
  let ops = host.maxOps || MAX_OPS;
  const tick = () => { if (--ops < 0) throw new Error('the program ran too long without finishing (operation budget exceeded)'); };
  const trace = [];
  const env = [new Map()];
  const get = (name) => { for (let i = env.length - 1; i >= 0; i--) if (env[i].has(name)) return env[i].get(name); throw new Error(`"${name}" is not defined`); };
  const str = (v) => (v == null ? '' : typeof v === 'object' ? JSON.stringify(v) : String(v));
  function ev(n) {
    switch (n.type) {
      case 'Lit': return n.v;
      case 'Tpl': return n.parts.map((x) => (typeof x === 'string' ? x : str(ev(x)))).join('');
      case 'Id': return get(n.name);
      case 'Member': {
        const o = ev(n.obj);
        if (o == null && n.optional) return undefined;
        if (o == null || typeof o !== 'object') throw new Error(`${n.at.line}:${n.at.col} cannot read "${n.prop}" of ${str(o) || o}`);
        return Object.prototype.hasOwnProperty.call(o, n.prop) ? o[n.prop] : undefined;
      }
      case 'Await': return ev(n.arg);
      case 'Not': return !ev(n.arg);
      case 'Bin': {
        if (n.op === '&&') { const l = ev(n.l); return l ? ev(n.r) : l; }
        if (n.op === '||') { const l = ev(n.l); return l ? l : ev(n.r); }
        const l = ev(n.l), r = ev(n.r);
        return n.op === '===' ? l === r : l !== r;
      }
      case 'Arr': return n.items.map(ev);
      case 'Obj': return Object.fromEntries(n.props.map(([k, x]) => [k, ev(x)]));
      case 'Call': {
        const m = n.callee.prop;
        const a = n.args.map(ev);
        if (m === 'retries') return Array.from({ length: a[0] }, (_, i) => i + 1);
        if (m === 'done' || m === 'handoff') return { $end: m, message: a[0] == null ? '' : str(a[0]) };
        if (++steps > host.maxSteps) throw new Error(`step budget exceeded (${host.maxSteps})`);
        let r;
        if (m === 'check') r = host.check(a[0]);
        else if (m === 'work') r = host.work(str(a[0]), a[1].scope);
        else if (m === 'skill') r = host.skill(a[0], str(a[1]), a[2].scope);
        else r = host.agent(a[0], str(a[1]), a[2].scope);
        trace.push({ call: `${m}:${a[0]}`, ...r });
        return r;
      }
      default: throw new Error('unsupported expression');
    }
  }
  function exec(b) {
    env.push(new Map());
    try {
      for (const s of b.body) {
        tick();
        if (s.type === 'Const') env[env.length - 1].set(s.name, ev(s.init));
        else if (s.type === 'Expr') ev(s.expr);
        else if (s.type === 'Return') return ev(s.arg);
        else if (s.type === 'Break') return BREAK;
        else if (s.type === 'Continue') return CONTINUE;
        else if (s.type === 'If') { const r = ev(s.test) ? exec(s.then) : s.els ? exec(s.els) : undefined; if (r !== undefined) return r; }
        else if (s.type === 'For') {
          for (const x of ev(s.iter)) {
            tick();
            env.push(new Map([[s.name, x]]));
            const r = exec(s.body);
            env.pop();
            if (r === BREAK) break;
            if (r === CONTINUE) continue;
            if (r !== undefined) return r;
          }
        }
      }
      return undefined;
    } finally { env.pop(); }
  }
  env[0].set(h, null);
  const r = exec(ast.body);
  if (!r || !r.$end) throw new Error('program ended without h.done / h.handoff');
  return { status: r.$end === 'done' ? 'done' : 'handoff', message: r.message, trace };
}

// ───────── 한 걸음씩: 기록(trace)을 되짚어 "다음에 할 한 걸음"을 구한다.
// 프로그램은 같은 결과를 받으면 같은 길로 간다 → 처음부터 다시 돌리면서 기록된 결과를 차례로 돌려주고, 기록이 끝난 자리의 호출이 다음 걸음이다.
//   trace: [{ key, result }] (key = 그 호출의 종류와 인자)
//   반환: { step: { op, args, key, n } } | { end: 'done' | 'handoff', message }
const PENDING = Symbol('pending');
function next(ast, trace, maxSteps) {
  let i = 0;
  const take = (op, args) => {
    const key = JSON.stringify([op, ...args]);
    if (i < trace.length) {
      const t = trace[i++];
      if (t.key !== key) throw new Error(`the recorded steps do not match the program (step ${i}: recorded ${t.key}, the program asks for ${key})`);
      return t.result;
    }
    throw Object.assign(new Error('pending'), { [PENDING]: { op, args, key, n: i + 1 } });
  };
  const host = { maxSteps, check: (g) => take('check', [g]), work: (task, scope) => take('work', [task, scope]),
    skill: (name, args, scope) => take('skill', [name, args, scope]), agent: (name, task, scope) => take('agent', [name, task, scope]) };
  try { const r = run(ast, host); return { end: r.status, message: r.message }; } catch (e) { if (e && e[PENDING]) return { step: e[PENDING] }; throw e; }
}

// 파싱 + 검증을 한 번에. { ast, errors }
function compile(code, reg) {
  // 모델이 습관적으로 붙이는 ```ts … ``` 울타리는 떼고 본다 (줄 번호가 밀리지 않게 빈 줄로 둔다)
  const src = String(code == null ? '' : code).replace(/^(\s*)```[\w-]*[ \t]*(?=\r?\n)/, '$1').replace(/\n[ \t]*```[ \t]*\s*$/, '\n');
  if (!src.trim()) return { errors: ['the program is empty — submit one `async (h) => { … }`'] };
  if (src.length > MAX_SOURCE) return { errors: [`the program is too long (${src.length} characters, max ${MAX_SOURCE})`] };
  const deep = (e) => { if (e instanceof RangeError) return { errors: ['syntax: the program is nested too deeply'] }; throw e; };
  let ast;
  try { ast = parse(src); } catch (e) { if (e.syntax) return { errors: [`syntax: ${e.message}`] }; return deep(e); }
  try { return { ast, errors: verify(ast, reg) }; } catch (e) { return deep(e); }
}

module.exports = { tokenize, parse, verify, declaration, example, run, next, compile, scopeError, MAX_RETRIES, MAX_ITERATIONS, MAX_OPS };
