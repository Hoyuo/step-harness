#!/usr/bin/env node
'use strict';
// step-harness MCP 서버 (stdio, 의존성 없음) — Code Mode 형태: 도구는 search / execute (+ 실행이 길 때 이어서 기다리는 check).
// 각 도구는 harness.cjs CLI 를 그대로 부른다. 검증·실행·상태는 전부 CLI 쪽에 있다.
//   등록 예 (Devin/Claude 의 MCP 설정):  { "step-harness": { "command": "node", "args": ["<plugin>/scripts/mcp.cjs"] } }
const { spawnSync } = require('child_process');
const fs = require('fs');
const path = require('path');
const L = require('./lib.cjs');

const TOOLS = [
  { name: 'search', description: 'Show the typed harness API (TypeScript declaration) and the registered gates, skills and agents. Optional query filters them.',
    inputSchema: { type: 'object', properties: { query: { type: 'string', description: 'filter by name or description' } } } },
  { name: 'execute', description: 'Verify and run ONE harness program: an `async (h) => { … }` TypeScript-subset function against the API from search. Rejected programs are not run; the errors say what to fix.',
    inputSchema: { type: 'object', properties: { code: { type: 'string', description: 'async (h) => { … }' } }, required: ['code'] } },
  { name: 'check', description: 'Wait for the running program and print each step and the result. Call again while it prints STILL RUNNING.',
    inputSchema: { type: 'object', properties: {} } },
];

// 어느 프로젝트의 흐름인가: 환경변수 → 클라이언트가 알려준 작업 폴더(MCP roots) → 서버의 cwd.
// cwd 는 믿을 수 없는 값이다 (클라이언트가 서버를 플러그인 폴더나 홈 폴더에서 띄울 수 있다). 그래서
//   · 플러그인 폴더는 어떤 경우에도 쓰지 않고
//   · 환경변수도 roots 도 없으면, cwd 가 프로젝트로 보일 때만(.step-harness 나 .git 이 그 위에 있음, 홈·루트 폴더 아님) 쓴다.
// 확인하지 못하면 실행하지 않고 exec 형태를 안내한다 (엉뚱한 폴더에 상태를 만들고 작업자를 돌리는 것보다 낫다).
let clientRoot = null;
function looksLikeProject(dir) {
  if (dir === require('os').homedir() || path.dirname(dir) === dir) return false;
  for (let d = dir; ; d = path.dirname(d)) {
    if (fs.existsSync(path.join(d, L.DIR)) || fs.existsSync(path.join(d, '.git'))) return true;
    if (path.dirname(d) === d) return false;
  }
}
function root() {
  const env = process.env.STEP_HARNESS_ROOT || process.env.DEVIN_PROJECT_DIR || process.env.CLAUDE_PROJECT_DIR;
  const r = L.findRoot(env || clientRoot || process.cwd());
  if (L.inside(r, L.PLUGIN_DIR, r)) return null;
  if (!env && !clientRoot && !looksLikeProject(r)) return null;
  return r;
}
function cli(args, input) {
  const dir = root();
  if (!dir) {
    return { isError: true, text: '[step-harness] This MCP server cannot tell which project the session works on (no project directory was given and its own working directory is not a project). ' +
      `Use the exec form instead: ${L.cli(args[0] === 'execute' ? "execute <<'EOF'\n<program>\nEOF" : args.join(' '))}` };
  }
  const r = spawnSync(process.execPath, [L.HARNESS_CLI, ...args], { cwd: dir, input: input || '', encoding: 'utf8', maxBuffer: 8 << 20,
    env: { ...process.env, STEP_HARNESS_ROOT: dir } });
  return { text: ((r.stdout || '') + (r.stderr || '')).trim() || '(no output)', isError: r.status !== 0 };
}
function call(name, a = {}) {
  if (name === 'search') return cli(['search', ...(a.query ? [String(a.query)] : [])]);
  if (name === 'execute') return cli(['execute'], String(a.code || ''));   // 프로그램은 stdin 으로 (따옴표 문제 없음)
  if (name === 'check') return cli(['check', '--wait', '50']);
  return { text: `unknown tool ${name}`, isError: true };
}

function reply(id, result, error) {
  process.stdout.write(JSON.stringify(error ? { jsonrpc: '2.0', id, error } : { jsonrpc: '2.0', id, result }) + '\n');
}
let wantRoots = false;
let asking = false;        // roots/list 를 보내고 답을 기다리는 중
const held = [];           // 그동안 들어온 도구 호출 (답이 오거나 2초가 지나면 처리)
let askTimer = null;
function rootsSettled() { if (!asking) return; asking = false; clearTimeout(askTimer); for (const run of held.splice(0)) run(); }
function onMessage(msg) {
  if (!msg || typeof msg !== 'object' || Array.isArray(msg)) return reply(null, null, { code: -32600, message: 'invalid request (one JSON-RPC object per line; batches are not supported)' });
  const { id, method, params } = msg;
  if (method === undefined) {   // 우리가 보낸 요청(roots/list)에 대한 응답
    if (id !== 'step-harness-roots') return;
    if (msg.result && Array.isArray(msg.result.roots)) {
      const uri = (msg.result.roots.find((r) => r && /^file:\/\//.test(String(r.uri))) || {}).uri;
      try { if (uri) clientRoot = require('url').fileURLToPath(uri); } catch { /* 해석할 수 없는 URI */ }
    }
    return rootsSettled();
  }
  if (id === undefined) {   // 알림
    const env = process.env.STEP_HARNESS_ROOT || process.env.DEVIN_PROJECT_DIR || process.env.CLAUDE_PROJECT_DIR;
    if (method === 'notifications/initialized' && wantRoots && !env && !asking && !clientRoot) {
      asking = true;
      process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id: 'step-harness-roots', method: 'roots/list' }) + '\n');
      askTimer = setTimeout(rootsSettled, 2000);
    }
    return;
  }
  if (method === 'initialize') {
    wantRoots = !!(params && params.capabilities && params.capabilities.roots);
    return reply(id, { protocolVersion: (params && params.protocolVersion) || '2025-06-18', capabilities: { tools: {} },
      serverInfo: { name: 'step-harness', version: require(path.join(L.PLUGIN_DIR, '.devin-plugin', 'plugin.json')).version } });
  }
  if (method === 'ping') return reply(id, {});
  if (method === 'tools/list') return reply(id, { tools: TOOLS });
  if (method === 'tools/call') {
    const run = () => { const r = call(params && params.name, params && params.arguments); reply(id, { content: [{ type: 'text', text: r.text }], isError: r.isError }); };
    return asking ? held.push(run) : run();   // 작업 폴더를 묻는 중이면 답을 받은 뒤에 실행한다
  }
  return reply(id, null, { code: -32601, message: `method not found: ${method}` });
}

let buf = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (chunk) => {
  buf += chunk;
  let i;
  while ((i = buf.indexOf('\n')) >= 0) {
    const line = buf.slice(0, i).trim();
    buf = buf.slice(i + 1);
    if (!line) continue;
    let msg;
    try { msg = JSON.parse(line); } catch { reply(null, null, { code: -32700, message: 'parse error' }); continue; }
    try { onMessage(msg); } catch (e) { reply(msg && typeof msg === 'object' && msg.id !== undefined ? msg.id : null, null, { code: -32603, message: e.message }); }
  }
});
process.stdin.on('end', rootsSettled);   // 입력이 끝났으면 기다리던 호출을 마저 처리한다
