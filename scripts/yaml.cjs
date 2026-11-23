'use strict';
// YAML 부분집합 파서 — 의존성 없이 flow 파일을 읽기 위한 것. (`yaml` 또는 `js-yaml` 패키지가 설치돼 있으면 그쪽을 쓴다)
// 지원: 블록 맵/시퀀스, flow 컬렉션 {..} [..] (여러 줄 가능), 따옴표 문자열, 숫자/불리언/null, 주석, 블록 스칼라(| >)
// 미지원: 앵커/별칭, 태그, 여러 문서, 여러 줄 plain 스칼라, 탭 들여쓰기 → 만나면 줄 번호와 함께 오류

function parse(text) {
  const lines = String(text).replace(/\r\n?/g, '\n').split('\n');
  let i = 0;
  const fail = (msg, n) => { throw new Error(`YAML ${n + 1}행: ${msg}`); };
  const blank = (s) => /^\s*(#.*)?$/.test(s);
  const ind = (s, n) => { const m = s.match(/^[ \t]*/)[0]; if (m.includes('\t')) fail('탭 들여쓰기는 지원하지 않음', n); return m.length; };
  const peek = () => { while (i < lines.length && blank(lines[i])) i++; return i < lines.length ? lines[i] : null; };
  const quoteStart = (s, k) => (s[k] === '"' || s[k] === "'") && (k === 0 || /[\s[{,:]/.test(s[k - 1]));

  function stripComment(s) {
    let q = null;
    for (let k = 0; k < s.length; k++) {
      const c = s[k];
      if (q) { if (c === '\\' && q === '"') k++; else if (c === q) q = null; } else if (quoteStart(s, k)) q = c;
      else if (c === '#' && (k === 0 || /\s/.test(s[k - 1]))) return s.slice(0, k);
    }
    return s;
  }
  function keyColon(s) {   // "키: 값" 의 콜론 위치 (따옴표 밖, 뒤가 공백이거나 줄 끝). 없으면 -1
    if (s[0] === '{' || s[0] === '[') return -1;
    let q = null;
    for (let k = 0; k < s.length; k++) {
      const c = s[k];
      if (q) { if (c === '\\' && q === '"') k++; else if (c === q) q = null; continue; }
      if (quoteStart(s, k)) { q = c; continue; }
      if (c === '#' && k > 0 && /\s/.test(s[k - 1])) return -1;
      if (c === ':' && (k + 1 === s.length || s[k + 1] === ' ')) return k;
    }
    return -1;
  }
  function balanced(s) {
    let q = null, d = 0;
    for (let k = 0; k < s.length; k++) {
      const c = s[k];
      if (q) { if (c === '\\' && q === '"') k++; else if (c === q) q = null; continue; }
      if (c === '"' || c === "'") q = c; else if (c === '[' || c === '{') d++; else if (c === ']' || c === '}') d--;
    }
    return d <= 0 && !q;
  }
  function scalar(raw, n) {
    const s = raw.trim();
    if (s === '' || s === '~' || s === 'null') return null;
    if (s === 'true') return true;
    if (s === 'false') return false;
    if (/^-?(0|[1-9]\d*)(\.\d+)?([eE][-+]?\d+)?$/.test(s)) return Number(s);
    if (s[0] === '"') {
      if (s.length < 2 || s[s.length - 1] !== '"') fail('닫히지 않은 큰따옴표', n);
      try { return JSON.parse(s); } catch { fail('잘못된 큰따옴표 문자열', n); }
    }
    if (s[0] === "'") {
      if (s.length < 2 || s[s.length - 1] !== "'") fail('닫히지 않은 작은따옴표', n);
      return s.slice(1, -1).replace(/''/g, "'");
    }
    if (/^[&*!%@`]/.test(s) || /^[|>]/.test(s)) fail(`지원하지 않는 문법 "${s[0]}" (값을 따옴표로 감싸거나 yaml 패키지 설치)`, n);
    return s;
  }
  function flow(s, n) {
    let p = 0;
    const ws = () => { while (p < s.length && /\s/.test(s[p])) p++; };
    const quoted = () => {
      const q = s[p];
      let k = p + 1;
      for (; k < s.length; k++) {
        if (s[k] === '\\' && q === '"') k++;
        else if (s[k] === q) { if (q === "'" && s[k + 1] === "'") k++; else break; }
      }
      if (k >= s.length) fail('닫히지 않은 따옴표', n);
      const v = scalar(s.slice(p, k + 1), n);
      p = k + 1;
      return v;
    };
    const value = () => {
      ws();
      if (s[p] === '[') {
        p++; const arr = [];
        for (;;) {
          ws();
          if (s[p] === ']') { p++; return arr; }
          arr.push(value()); ws();
          if (s[p] === ',') p++; else if (s[p] !== ']') fail('flow 시퀀스 문법 오류', n);
        }
      }
      if (s[p] === '{') {
        p++; const obj = {};
        for (;;) {
          ws();
          if (s[p] === '}') { p++; return obj; }
          let key;
          if (s[p] === '"' || s[p] === "'") key = String(quoted());
          else { const st = p; while (p < s.length && !':,}'.includes(s[p])) p++; key = s.slice(st, p).trim(); }
          ws();
          if (s[p] !== ':') fail('flow 맵에는 "키: 값" 이 필요', n);
          p++;
          obj[key] = value(); ws();
          if (s[p] === ',') p++; else if (s[p] !== '}') fail('flow 맵 문법 오류', n);
        }
      }
      if (s[p] === '"' || s[p] === "'") return quoted();
      const st = p;
      while (p < s.length && !',]}'.includes(s[p])) p++;
      return scalar(s.slice(st, p), n);
    };
    const v = value();
    ws();
    if (p < s.length) fail('flow 컬렉션 뒤에 해석하지 못한 글자가 남음', n);
    return v;
  }
  function valueOf(after, n) {   // 현재 줄은 이미 소비된 상태 (i 는 다음 줄)
    let s = stripComment(after).trim();
    if (s[0] === '[' || s[0] === '{') {
      while (!balanced(s)) { if (i >= lines.length) fail('닫히지 않은 flow 컬렉션', n); s += ' ' + stripComment(lines[i++]).trim(); }
      return flow(s, n);
    }
    return scalar(s, n);
  }
  function blockScalar(header, parentIndent) {
    const fold = header[0] === '>';
    const chomp = header.includes('-') ? 'strip' : header.includes('+') ? 'keep' : 'clip';
    const buf = [];
    let bi = null;
    while (i < lines.length) {
      const raw = lines[i];
      if (raw.trim() === '') { buf.push(''); i++; continue; }
      const d = raw.match(/^ */)[0].length;
      if (d <= parentIndent || (bi != null && d < bi)) break;
      if (bi == null) bi = d;
      buf.push(raw.slice(bi)); i++;
    }
    let trailing = 0;
    while (buf.length && buf[buf.length - 1] === '') { buf.pop(); trailing++; }
    let body = '';
    if (!fold) body = buf.join('\n');
    else buf.forEach((ln, k) => { body += k === 0 ? ln : ln === '' ? '\n' : buf[k - 1] === '' ? ln : ' ' + ln; });
    if (!buf.length) return '';
    return chomp === 'strip' ? body : chomp === 'keep' ? body + '\n'.repeat(trailing + 1) : body + '\n';
  }
  const isSeqLine = (body) => body === '-' || body.startsWith('- ');
  const unquoteKey = (k, n) => ((k[0] === '"' || k[0] === "'") ? String(scalar(k, n)) : k);

  function map(indent) {
    const obj = {};
    for (;;) {
      const line = peek();
      if (line == null) break;
      const d = ind(line, i);
      if (d < indent) break;
      if (d > indent) fail('들여쓰기가 맞지 않음', i);
      const body = line.slice(d);
      if (isSeqLine(body)) break;
      const c = keyColon(body);
      if (c < 0) fail('"키: 값" 형식이 아님', i);
      const key = unquoteKey(body.slice(0, c).trim(), i);
      if (Object.prototype.hasOwnProperty.call(obj, key)) fail(`키 중복 "${key}"`, i);
      const rest = stripComment(body.slice(c + 1)).trim();
      const n = i++;
      if (rest === '') {
        const nx = peek();
        if (nx != null && ind(nx, i) > indent) obj[key] = node();
        else if (nx != null && ind(nx, i) === indent && isSeqLine(nx.slice(indent))) obj[key] = seq(indent);
        else obj[key] = null;
      } else if (/^[|>][-+]?$/.test(rest)) obj[key] = blockScalar(rest, indent);
      else obj[key] = valueOf(body.slice(c + 1), n);
    }
    return obj;
  }
  function seq(indent) {
    const arr = [];
    for (;;) {
      const line = peek();
      if (line == null) break;
      const d = ind(line, i);
      if (d > indent) fail('들여쓰기가 맞지 않음', i);
      if (d < indent || !isSeqLine(line.slice(d))) break;
      const after = line.slice(d + 1);
      const pad = after.match(/^ */)[0].length;
      const rest = after.slice(pad);
      const bare = stripComment(rest).trim();
      if (bare === '') { i++; const nx = peek(); arr.push(nx != null && ind(nx, i) > indent ? node() : null); continue; }
      if (keyColon(rest) >= 0) {   // "- 키: 값" → 그 자리에서 시작하는 맵
        lines[i] = ' '.repeat(indent + 1 + pad) + rest;
        arr.push(map(indent + 1 + pad));
        continue;
      }
      const n = i++;
      arr.push(/^[|>][-+]?$/.test(bare) ? blockScalar(bare, indent) : valueOf(rest, n));
    }
    return arr;
  }
  function node() {
    const line = peek();
    if (line == null) return null;
    const d = ind(line, i);
    const body = line.slice(d);
    if (isSeqLine(body)) return seq(d);
    if (keyColon(body) >= 0) return map(d);
    const n = i++;
    return valueOf(body, n);
  }

  const first = peek();
  if (first != null && /^---\s*$/.test(first)) i++;
  const v = node();
  if (peek() != null) fail('해석하지 못한 내용이 남음 (들여쓰기 확인)', i);
  return v;
}

module.exports = { parse };
