import { createHash } from 'node:crypto';

// Simulates the function-body md5 guards that forward migrations carry
// (`md5(replace(prosrc, chr(13), '')) ... is distinct from 'hex'`) against the function bodies the prepared
// recovery chain would hold at that point, without a database. Pure functions only; the CLI lives in
// scripts/ci/check-md5-guards.mjs.

const IDENT_CHAR = /[A-Za-z0-9_$]/;

// ---- lexing -------------------------------------------------------------------------------------------------------

function dollarTagAt(source, index) {
  if (source[index] !== '$') return null;
  if (index > 0 && IDENT_CHAR.test(source[index - 1])) return null;
  const match = /^\$(?:[A-Za-z_][A-Za-z0-9_]*)?\$/.exec(source.slice(index, index + 80));
  return match ? match[0] : null;
}

// Splits SQL into top-level statements. Comments become spaces (newlines kept), string literals and
// dollar-quoted bodies are kept verbatim. Each statement carries its dollar-quoted segments.
export function splitStatements(source) {
  const text = source.replace(/\r\n/g, '\n').replace(/\r/g, '\n');
  const statements = [];
  let current = '';
  let segments = [];
  let line = 1;
  let startLine = null;
  let i = 0;
  const push = ch => { current += ch; if (startLine === null && !/\s/.test(ch)) startLine = line; };
  const flush = () => {
    if (current.trim() !== '') statements.push({ text: current, segments, line: startLine ?? line });
    current = ''; segments = []; startLine = null;
  };
  while (i < text.length) {
    const ch = text[i];
    const next = text[i + 1];
    if (ch === '-' && next === '-') {
      while (i < text.length && text[i] !== '\n') i += 1;
      current += ' ';
      continue;
    }
    if (ch === '/' && next === '*') {
      let depth = 1;
      i += 2;
      while (i < text.length && depth > 0) {
        if (text[i] === '/' && text[i + 1] === '*') { depth += 1; i += 2; continue; }
        if (text[i] === '*' && text[i + 1] === '/') { depth -= 1; i += 2; continue; }
        if (text[i] === '\n') { line += 1; current += '\n'; }
        i += 1;
      }
      current += ' ';
      continue;
    }
    if (ch === "'") {
      const escaped = /[eE]$/.test(current) && !IDENT_CHAR.test(current.slice(-2, -1) || ' ');
      push(ch); i += 1;
      while (i < text.length) {
        const c = text[i];
        if (c === '\n') line += 1;
        if (escaped && c === '\\') { current += c + (text[i + 1] ?? ''); if (text[i + 1] === '\n') line += 1; i += 2; continue; }
        current += c; i += 1;
        if (c === "'") { if (text[i] === "'") { current += "'"; i += 1; continue; } break; }
      }
      continue;
    }
    if (ch === '"') {
      push(ch); i += 1;
      while (i < text.length) {
        const c = text[i];
        current += c; i += 1;
        if (c === '"') { if (text[i] === '"') { current += '"'; i += 1; continue; } break; }
      }
      continue;
    }
    const tag = ch === '$' ? dollarTagAt(text, i) : null;
    if (tag) {
      const close = text.indexOf(tag, i + tag.length);
      if (close < 0) { push(text.slice(i)); i = text.length; break; }
      const content = text.slice(i + tag.length, close);
      segments.push({ tag, content, line });
      const raw = text.slice(i, close + tag.length);
      push(raw[0]);
      current += raw.slice(1);
      line += (raw.match(/\n/g) ?? []).length;
      i = close + tag.length;
      continue;
    }
    if (ch === ';') { i += 1; flush(); continue; }
    if (ch === '\n') line += 1;
    push(ch); i += 1;
  }
  flush();
  return statements;
}

// String literals (single-quoted and dollar-quoted) of a SQL fragment, in order, with their line numbers.
export function scanLiterals(source, firstLine = 1) {
  const text = source.replace(/\r\n/g, '\n').replace(/\r/g, '\n');
  const literals = [];
  let line = firstLine;
  let i = 0;
  while (i < text.length) {
    const ch = text[i];
    const next = text[i + 1];
    if (ch === '\n') { line += 1; i += 1; continue; }
    if (ch === '-' && next === '-') { while (i < text.length && text[i] !== '\n') i += 1; continue; }
    if (ch === '/' && next === '*') {
      let depth = 1; i += 2;
      while (i < text.length && depth > 0) {
        if (text[i] === '/' && text[i + 1] === '*') { depth += 1; i += 2; continue; }
        if (text[i] === '*' && text[i + 1] === '/') { depth -= 1; i += 2; continue; }
        if (text[i] === '\n') line += 1;
        i += 1;
      }
      continue;
    }
    if (ch === '"') {
      i += 1;
      while (i < text.length) { if (text[i] === '"') { if (text[i + 1] === '"') { i += 2; continue; } break; } if (text[i] === '\n') line += 1; i += 1; }
      i += 1; continue;
    }
    if (ch === "'") {
      const startLine = line;
      let value = '';
      i += 1;
      while (i < text.length) {
        const c = text[i];
        if (c === "'") { if (text[i + 1] === "'") { value += "'"; i += 2; continue; } break; }
        if (c === '\n') line += 1;
        value += c; i += 1;
      }
      i += 1;
      literals.push({ value, line: startLine, kind: 'quote', after: text.slice(i, i + 40) });
      continue;
    }
    const tag = ch === '$' ? dollarTagAt(text, i) : null;
    if (tag) {
      const close = text.indexOf(tag, i + tag.length);
      if (close < 0) break;
      const content = text.slice(i + tag.length, close);
      literals.push({ value: content, line, kind: 'dollar' });
      line += (content.match(/\n/g) ?? []).length;
      i = close + tag.length;
      continue;
    }
    i += 1;
  }
  return literals;
}

// ---- signatures ---------------------------------------------------------------------------------------------------

const TYPE_ALIASES = new Map([
  ['int', 'integer'], ['int4', 'integer'], ['integer', 'integer'],
  ['int8', 'bigint'], ['bigint', 'bigint'],
  ['int2', 'smallint'], ['smallint', 'smallint'],
  ['bool', 'boolean'], ['boolean', 'boolean'],
  ['timestamptz', 'timestamptz'], ['timestamp with time zone', 'timestamptz'],
  ['timestamp', 'timestamp'], ['timestamp without time zone', 'timestamp'],
  ['timetz', 'timetz'], ['time with time zone', 'timetz'],
  ['time', 'time'], ['time without time zone', 'time'],
  ['varchar', 'varchar'], ['character varying', 'varchar'],
  ['char', 'bpchar'], ['character', 'bpchar'], ['bpchar', 'bpchar'],
  ['float8', 'float8'], ['double precision', 'float8'],
  ['float4', 'float4'], ['real', 'float4'],
  ['numeric', 'numeric'], ['decimal', 'numeric'],
]);
const KNOWN_TYPES = new Set([
  ...TYPE_ALIASES.values(), 'uuid', 'text', 'date', 'jsonb', 'json', 'bytea', 'interval', 'inet', 'citext', 'name', 'oid',
  'regclass', 'record', 'void', 'anyelement', 'anyarray', 'trigger', 'cidr', 'money', 'xml', 'tsvector', 'point',
]);

export function normalizeType(raw) {
  let type = raw.replace(/"/g, '').replace(/\s+/g, ' ').trim().toLowerCase();
  type = type.replace(/^public\./, '').replace(/^pg_catalog\./, '');
  const arrayDepth = (type.match(/\[\s*\d*\s*\]/g) ?? []).length + (/\barray\b/.test(type) ? 1 : 0);
  type = type.replace(/\[\s*\d*\s*\]/g, '').replace(/\barray\b/, '').trim();
  type = type.replace(/\s*\(\s*\d+\s*(?:,\s*\d+\s*)?\)/g, '');
  type = type.replace(/^public\./, '').trim();
  type = TYPE_ALIASES.get(type) ?? type;
  return `${type}${'[]'.repeat(arrayDepth)}`;
}

function maskNested(text) {
  // Blank out quoted strings and everything inside parentheses so top-level separators can be found by index.
  let out = '';
  let depth = 0;
  let quote = null;
  for (let i = 0; i < text.length; i += 1) {
    const ch = text[i];
    if (quote) { out += ' '; if (ch === quote) quote = null; continue; }
    if (ch === "'" || ch === '"') { quote = ch; out += ' '; continue; }
    if (ch === '(' || ch === '[') { depth += 1; out += depth === 1 ? ch : ' '; continue; }
    if (ch === ')' || ch === ']') { depth -= 1; out += depth === 0 ? ch : ' '; continue; }
    out += depth > 0 ? ' ' : ch;
  }
  return out;
}

function splitTopLevelCommas(text) {
  const masked = maskNested(text);
  const parts = [];
  let last = 0;
  for (let i = 0; i < masked.length; i += 1) {
    if (masked[i] === ',') { parts.push(text.slice(last, i)); last = i + 1; }
  }
  parts.push(text.slice(last));
  return parts.map(part => part.trim()).filter(part => part !== '');
}

function argTypeFromDefinition(definition) {
  // Returns the normalized identity type of one parameter of a CREATE FUNCTION argument list, or null for an OUT parameter.
  let arg = definition.trim();
  const masked = maskNested(arg);
  const cut = masked.search(/\bdefault\b|=/i);
  if (cut >= 0) arg = arg.slice(0, cut).trim();
  const mode = /^(in|out|inout|variadic)\s+/i.exec(arg);
  if (mode) {
    arg = arg.slice(mode[0].length).trim();
    if (mode[1].toLowerCase() === 'out') return null;
  }
  const whole = normalizeType(arg);
  if (KNOWN_TYPES.has(whole.replace(/\[\]/g, ''))) return whole;
  const named = /^("[^"]+"|[A-Za-z_][A-Za-z0-9_$]*)\s+(.+)$/s.exec(arg);
  if (named) return normalizeType(named[2]);
  return whole;
}

export function normalizeSignature(schemaName, name, argTypes) {
  return `${schemaName}.${name}(${argTypes.join(',')})`;
}

function splitQualifiedName(raw) {
  const parts = [...raw.matchAll(/"((?:[^"]|"")+)"|([A-Za-z_][A-Za-z0-9_$]*)/g)].map(match => (match[1] ?? match[2]).replace(/""/g, '"'));
  if (parts.length === 1) return { schema: 'public', name: parts[0].toLowerCase() };
  return { schema: parts[parts.length - 2].toLowerCase(), name: parts[parts.length - 1].toLowerCase() };
}

function matchingParen(text, openIndex) {
  let depth = 0;
  let quote = null;
  for (let i = openIndex; i < text.length; i += 1) {
    const ch = text[i];
    if (quote) { if (ch === quote) quote = null; continue; }
    if (ch === "'" || ch === '"') { quote = ch; continue; }
    if (ch === '(') depth += 1;
    else if (ch === ')') { depth -= 1; if (depth === 0) return i; }
  }
  return -1;
}

// 'public.f(uuid, integer)' as written in a guard (regprocedure text) or a DROP FUNCTION target.
export function parseSignatureLiteral(literal) {
  const open = literal.indexOf('(');
  if (open < 0 || !literal.trim().endsWith(')')) return null;
  const name = splitQualifiedName(literal.slice(0, open));
  const inner = literal.slice(open + 1, literal.lastIndexOf(')'));
  const types = splitTopLevelCommas(inner).map(part => {
    const mode = /^(in|inout|variadic)\s+/i.exec(part);
    const text = mode ? part.slice(mode[0].length) : part;
    const whole = normalizeType(text);
    if (KNOWN_TYPES.has(whole.replace(/\[\]/g, ''))) return whole;
    const named = /^("[^"]+"|[A-Za-z_][A-Za-z0-9_$]*)\s+(.+)$/s.exec(text.trim());
    return named ? normalizeType(named[2]) : whole;
  });
  return normalizeSignature(name.schema, name.name, types);
}

const SIGNATURE_LITERAL = /^(?:"?[A-Za-z_][A-Za-z0-9_]*"?\.)?"?[A-Za-z_][A-Za-z0-9_]*"?\s*\([A-Za-z0-9_,\s\[\]."]*\)$/;
const EXISTENCE_CHECK = /^[\s):a-z_]*\bis\s+(?:not\s+)?null/i;

// ---- chain state --------------------------------------------------------------------------------------------------

export function bodyMd5(body) {
  return createHash('md5').update(body.replace(/\r/g, ''), 'utf8').digest('hex');
}

const CREATE_FUNCTION = /^create\s+(?:or\s+replace\s+)?function\s+(?:if\s+not\s+exists\s+)?((?:"(?:[^"]|"")+"|[A-Za-z_][A-Za-z0-9_$]*)(?:\s*\.\s*(?:"(?:[^"]|"")+"|[A-Za-z_][A-Za-z0-9_$]*))?)\s*\(/i;

// Normalized signature key of the function a CREATE [OR REPLACE] FUNCTION text defines, or null when it is not one.
export function createFunctionKey(text) {
  const header = text.replace(/\s+/g, ' ').trim();
  const create = CREATE_FUNCTION.exec(header);
  if (!create) return null;
  const headerOpen = header.indexOf('(', create[0].length - 1);
  const headerClose = matchingParen(header, headerOpen);
  if (headerClose < 0) return null;
  const { schema, name } = splitQualifiedName(create[1]);
  const argTypes = splitTopLevelCommas(header.slice(headerOpen + 1, headerClose)).map(argTypeFromDefinition).filter(type => type !== null);
  return normalizeSignature(schema, name, argTypes);
}

// Applies one statement to the function state (key -> {md5, source, line}). Returns nothing.
export function applyStatement(state, statement, source) {
  const clean = statement.text.replace(/\s+/g, ' ').trim();
  const key = createFunctionKey(clean);
  if (key) {
    const segment = statement.segments[0];
    if (!segment) {
      state.set(key, { md5: null, source: `${source}:${statement.line}`, line: statement.line, unknownBody: true });
    } else {
      state.set(key, { md5: bodyMd5(segment.content), source: `${source}:${statement.line}`, line: statement.line });
    }
    return;
  }
  const drop = /^drop\s+function\s+(?:if\s+exists\s+)?(.+?)(?:\s+(?:cascade|restrict))?$/i.exec(clean);
  if (drop) {
    for (const target of splitTopLevelCommas(drop[1])) {
      const key = parseSignatureLiteral(target);
      if (key) state.delete(key);
    }
  }
}

// A DO block that patches a live body (pg_get_functiondef, or execute format('create or replace function ...')) cannot be
// replayed without a database: the functions it rewrites are marked dynamic, and later guards on them are UNVERIFIED.
export function dynamicPatchInfo(statement) {
  if (!/^do\b/i.test(statement.text.trimStart())) return null;
  const { text, line } = guardText(statement);
  const execute = /\bexecute\b/i.exec(text);
  if (!execute) return null;
  const keys = new Set();
  const patchesLiveBody = /pg_get_functiondef/i.test(text);
  let dynamicCreate = false;
  const literals = scanLiterals(text, line);
  for (const literal of literals) {
    const created = /^\s*create\s+(?:or\s+replace\s+)?function\b/i.test(literal.value) ? createFunctionKey(literal.value) : null;
    if (created) { keys.add(created); dynamicCreate = true; }
  }
  if (!patchesLiveBody && !dynamicCreate) return null;
  if (patchesLiveBody) {
    for (const literal of literals) {
      if (literal.kind === 'quote' && SIGNATURE_LITERAL.test(literal.value.trim())) keys.add(parseSignatureLiteral(literal.value.trim()));
    }
  }
  for (const group of extractGuardGroups(text, line)) {
    for (const entry of group.entries) {
      const key = parseSignatureLiteral(entry.literal);
      if (key) keys.add(key);
    }
  }
  const executeLine = line + (text.slice(0, execute.index).match(/\n/g) ?? []).length;
  return { keys, line, executeLine };
}

export function markDynamicPatches(state, info, source) {
  if (!info) return;
  for (const key of info.keys) state.set(key, { md5: null, dynamic: true, source: `${source}:${info.line} (patched at run time)`, line: info.line });
}

// ---- guards -------------------------------------------------------------------------------------------------------

// Guard entries of one statement: each function signature literal with the 32-hex literals that follow it, grouped by
// source line so that "old signature has the old body, or the new signature already has the new body" rows pass as one.
export function extractGuardGroups(text, firstLine) {
  const literals = scanLiterals(text, firstLine);
  const entries = [];
  for (const literal of literals) {
    if (literal.kind === 'quote' && SIGNATURE_LITERAL.test(literal.value.trim())) {
      if (EXISTENCE_CHECK.test(literal.after ?? '')) continue; // `to_regprocedure('f(...)') is [not] null` checks existence, not a body
      entries.push({ literal: literal.value.trim(), line: literal.line, hexes: [] });
    } else if (literal.kind === 'quote' && /^[0-9a-f]{32}$/.test(literal.value) && entries.length > 0) {
      entries.at(-1).hexes.push(literal.value);
    }
  }
  const guarded = entries.filter(entry => entry.hexes.length > 0);
  const groups = [];
  for (const entry of guarded) {
    const previous = groups.at(-1);
    if (previous && previous.line === entry.line) previous.entries.push(entry);
    else groups.push({ line: entry.line, entries: [entry] });
  }
  return groups;
}

function isMd5Guard(text) {
  return /\bprosrc\b/i.test(text) && /\bmd5\s*\(/i.test(text);
}

export function guardText(statement) {
  const head = statement.text.trimStart().slice(0, 2).toLowerCase();
  if (head === 'do' && /^do\b/i.test(statement.text.trimStart()) && statement.segments[0]) {
    return { text: statement.segments[0].content, line: statement.segments[0].line };
  }
  return { text: statement.text, line: statement.line };
}

// chain: [{ label, sql, kind: 'base' | 'bridge' | 'forward' }] in apply order. Returns the report rows.
export function simulateMd5Guards(chain, { allowlist = [] } = {}) {
  const state = new Map();
  const rows = [];
  for (const file of chain) {
    for (const statement of splitStatements(file.sql)) {
      const patchInfo = file.kind === 'forward' ? dynamicPatchInfo(statement) : null;
      if (file.kind === 'forward') {
        const { text, line } = guardText(statement);
        if (isMd5Guard(text)) {
          for (const group of extractGuardGroups(text, line)) {
            const resolved = group.entries.map(entry => {
              const key = parseSignatureLiteral(entry.literal);
              const found = key ? state.get(key) : undefined;
              return {
                entry, key,
                got: found?.md5 ?? null,
                source: found?.source ?? '-',
                // dynamic: patched at run time by an earlier migration, or checked after this block's own patch
                dynamic: Boolean(found?.dynamic) || Boolean(key && patchInfo?.keys.has(key) && entry.line > patchInfo.executeLine),
                matched: Boolean(found?.md5) && entry.hexes.includes(found.md5),
              };
            });
            const winner = resolved.find(item => item.matched) ?? resolved.find(item => item.dynamic) ?? resolved[0];
            let status = 'MATCH';
            if (!resolved.some(item => item.matched)) {
              if (resolved.some(item => item.dynamic)) status = 'DYNAMIC';
              else status = resolved.every(item => item.got === null) ? 'MISSING' : 'DIFF';
            }
            const allowed = status !== 'MATCH' && allowlist.some(item => item.migration === file.label && item.signature === winner.key);
            rows.push({
              migration: file.label,
              line: group.line,
              signature: winner.entry.literal,
              expected: winner.entry.hexes.join('|'),
              got: winner.got,
              source: winner.source,
              status,
              allowed,
            });
          }
        }
      }
      applyStatement(state, statement, file.label);
      if (file.kind === 'forward') markDynamicPatches(state, patchInfo, file.label);
    }
  }
  return rows;
}

export function formatMd5GuardReport(rows) {
  const header = ['migration', 'line', 'function', 'expected', 'got', 'last body from', 'status'];
  const lines = rows.map(row => [
    row.migration, String(row.line), row.signature.replace(/^public\./, ''),
    row.expected.split('|').map(hex => hex.slice(0, 8)).join('|'),
    row.got ? row.got.slice(0, 8) : '-',
    row.source,
    row.status + (row.allowed ? ' (allowlisted)' : ''),
  ]);
  const widths = header.map((title, index) => Math.max(title.length, ...lines.map(line => line[index].length)));
  const render = cells => cells.map((cell, index) => cell.padEnd(widths[index])).join('  ').trimEnd();
  return [render(header), render(widths.map(width => '-'.repeat(width))), ...lines.map(render)].join('\n');
}

export function summarizeMd5Guards(rows) {
  const counts = { MATCH: 0, DIFF: 0, MISSING: 0, DYNAMIC: 0 };
  for (const row of rows) counts[row.status] += 1;
  const failing = rows.filter(row => (row.status === 'DIFF' || row.status === 'MISSING') && !row.allowed);
  return { counts, failing };
}
