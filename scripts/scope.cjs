'use strict';
// 작업 단계가 끝났을 때 "허용 범위 밖의 파일이 바뀌었는가"를 git 으로 확인한다.
// hook 은 파일 도구의 경로만 본다. 셸 명령이 바꾼 파일은 여기서(단계 전후의 비교로) 잡힌다.
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { spawnSync } = require('child_process');
const L = require('./lib.cjs');

// 하네스가 직접 돌리는 git. git 은 설정에 적힌 명령을 대신 실행한다 (예: core.fsmonitor 는 `git status` 때마다 실행된다).
// 에이전트가 쓸 수 있는 설정(~/.gitconfig 등)을 통해 하네스 프로세스가 엉뚱한 명령을 실행하지 않도록:
//   · 사용자·시스템 설정은 읽지 않는다 · fsmonitor 는 끈다 · 색인을 고쳐 쓰지 않는다
//   · 실행 파일은 PATH 에서 그때그때 찾지 않고 처음에 정한 절대 경로를 쓴다 (PATH 앞쪽의 사용자 폴더에 심은 `git` 을 실행하지 않도록)
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
let GIT_BIN = null;
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
function git(cwd, args) {
  if (!GIT_BIN) GIT_BIN = findGit();
  return spawnSync(GIT_BIN, [...gitFlags(), ...args], { cwd, encoding: 'utf8', maxBuffer: 64 << 20, env: { ...process.env, ...GIT_ENV } });
}
const real = (p) => { try { return fs.realpathSync(p); } catch { return p; } };
const onDisk = (p) => { try { return (fs.realpathSync.native || fs.realpathSync)(p); } catch { return p; } };
// 파일 하나의 서명: 크기·수정 시각·ctime·모드 (없으면 gone). ctime 은 내용을 바꾸고 크기·수정 시각을 되돌려도 달라진다.
const fileSig = (abs) => { try { const st = fs.lstatSync(abs); return `${st.size}:${st.mtimeMs}:${st.ctimeMs}:${st.mode}`; } catch { return 'gone'; } };
// 폴더가 그 자체로 git 저장소(하위 모듈 · 안에 따로 만든 저장소)면 한 덩어리로 본다: 그 저장소의 커밋과 "깨끗하지 않은 파일" 전부가 서명이다.
//   (바깥 저장소의 `git status` 는 그 폴더가 달라졌다는 것만 알려준다 → 이미 달라져 있던 폴더 안을 또 고친 것은 이 서명으로 잡는다)
const isRepoDir = (abs) => { try { return fs.lstatSync(abs).isDirectory() && fs.existsSync(path.join(abs, '.git')); } catch { return false; } };
function sigOf(abs, depth = 0) {
  const inner = depth < 3 && isRepoDir(abs) ? snapshot(abs, abs, depth + 1) : null;
  return inner ? `repo:${inner.head}:${crypto.createHash('sha1').update(JSON.stringify([...inner].sort())).digest('hex')}` : fileSig(abs);
}
// 반환: Map<root 기준 상대경로, 서명> — git 이 "깨끗하지 않다"고 보는 파일 전부(변경·추가·삭제·미추적)와,
//   git 이 보지 않게 표시해 둔 파일(assume-unchanged · skip-worktree), git 이 관리하는 폴더에 있는 관리 밖의 .gitignore.
//   지금의 커밋은 .head 에 둔다. git 저장소가 아니거나 git 이 답하지 못하면 null.
function snapshot(root, dir = root, depth = 0) {
  const top = git(dir, ['rev-parse', '--show-toplevel']);
  if (top.status !== 0 || !top.stdout.trim()) return null;
  const base = real(top.stdout.trim());
  if (depth && onDisk(base) !== onDisk(dir)) return null;   // .git 이 있지만 저장소가 아닌 폴더 (git 이 바깥 저장소를 가리킨다)
  const args = ['status', '--porcelain=v1', '-z', '--untracked-files=all'];
  let r = git(dir, [...args, '--no-renames']);
  if (r.status !== 0) r = git(dir, args);   // 오래된 git 은 --no-renames 를 모른다 → 이름 변경 항목(R/C)은 아래에서 두 경로로 풀어 읽는다
  if (r.status !== 0) return null;
  const here = depth ? base : real(root);
  const m = new Map();
  const add = (file) => { const abs = path.join(base, file); m.set(path.relative(here, abs).split(path.sep).join('/'), sigOf(abs, depth)); };
  const parts = r.stdout.split('\0');
  for (let i = 0; i < parts.length; i++) {
    const e = parts[i];
    if (e.length < 4) continue;
    add(e.slice(3));
    if (/[RC]/.test(e.slice(0, 2)) && parts[i + 1]) add(parts[++i]);   // "R  새이름\0원래이름"
  }
  const hid = git(dir, ['ls-files', '-v', '-z', '--full-name', ':/']);
  if (hid.status === 0) {
    const tracked = new Set();
    const dirs = new Set(['']);   // git 이 관리하는 파일이 있는 폴더들 ('' = 저장소 맨 위)
    for (const e of hid.stdout.split('\0')) {
      if (e.length < 3) continue;
      const file = e.slice(2);
      if (/^[a-zS] /.test(e)) add(file);   // `git status` 가 보지 않게 표시된 파일(소문자 = assume-unchanged, S = skip-worktree)
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
  const head = git(dir, ['rev-parse', '-q', '--verify', 'HEAD^{commit}']);
  m.head = head.status === 0 ? head.stdout.trim() : '';   // 아직 커밋이 없으면 빈 문자열
  m.add = add;
  return m;
}
// 단계 도중에 커밋까지 하면 바꾼 파일이 `git status` 에서 사라진다 → 전후의 커밋이 다르면 그 사이에 달라진 파일도 "뒤 목록"에 넣는다.
//   (전부터 고쳐져 있던 파일을 커밋만 한 것은 서명이 그대로다 → changedOutside 가 넘긴다)
// 반환: 확인했으면 true, git 이 답하지 못했으면 false
function addCommitted(root, before, after) {
  if (!after.head || after.head === before.head) return true;   // 커밋이 없는 상태가 됐다면 파일은 전부 `git status` 에 나온다
  const r = before.head ? git(root, ['diff', '--name-only', '-z', '--no-renames', '--no-ext-diff', '--no-textconv', before.head, after.head])
    : git(root, ['ls-tree', '-r', '-z', '--name-only', '--full-tree', after.head]);
  if (r.status !== 0) return false;
  for (const file of r.stdout.split('\0')) if (file) after.add(file);
  return true;
}
// 전후의 목록을 비교해, 범위 밖에서 바뀐 파일을 돌려준다.
//   · 앞 목록에 있던 파일: 지금 다시 재서 그때와 다르면 바뀐 것 (git 의 목록에서 사라졌는지는 보지 않는다 —
//     커밋만 해도 목록에서 사라지지만 파일은 그대로다. 반대로 내용을 되돌렸으면 서명이 달라진다)
//   · 뒤 목록에 새로 나타난 파일: 앞에서는 깨끗했다는 뜻이므로 바뀐 것
function changedOutside(root, before, after, scope) {
  const res = scope.map((g) => L.globToRe(g));
  const here = real(root);
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

// ───────── 단계 전후 (hook·CLI 는 호출마다 다른 프로세스다 → 앞 목록은 파일에 둔다)
const FILE = 'scope-before.json';
// 단계에 들어갈 때: 지금의 목록을 남긴다. git 저장소가 아니면(또는 scope_check=false) 남기지 않는다 → 그 단계는 검사하지 않는다
function begin(root, seq) {
  const f = L.sp(root, FILE);
  const snap = L.config(root).scope_check === false ? null : snapshot(root);
  if (!snap) { try { fs.unlinkSync(f); } catch { /* 없음 */ } return false; }
  L.writeJson(f, { seq, head: snap.head, files: [...snap] });
  return true;
}
// 단계가 끝났을 때. 반환: null(검사 안 함) | { unknown: true }(git 이 답하지 못함) | { outside: [경로…] }
function end(root, seq, scope) {
  const saved = L.readJson(L.sp(root, FILE), null);
  if (!saved || saved.seq !== seq) return null;
  const before = new Map(saved.files);
  before.head = saved.head;
  const after = snapshot(root);
  if (!after || !addCommitted(root, before, after)) return { unknown: true };   // 확인할 수 없으면 통과로 치지 않는다 (색인을 망가뜨려 검사를 건너뛰게 하지 못하도록)
  return { outside: changedOutside(root, before, after, scope) };
}

module.exports = { snapshot, addCommitted, changedOutside, begin, end };
