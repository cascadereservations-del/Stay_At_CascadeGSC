import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { extname } from 'node:path';
import { fileURLToPath } from 'node:url';

const TEXT_EXTENSIONS = new Set(['.css', '.html', '.js', '.json', '.md', '.mjs', '.ps1', '.sql', '.toml', '.ts', '.yaml', '.yml']);
const RULES = [
  ['private_key', /-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/g],
  ['openai_key', /\bsk-(?:proj-)?[A-Za-z0-9_-]{20,}\b/g],
  ['openrouter_key', /\bsk-or-v1-[A-Za-z0-9]{20,}\b/g],
  ['github_token', /\b(?:ghp|gho|ghu|ghs|github_pat)_[A-Za-z0-9_]{20,}\b/g],
  ['telegram_token', /\b\d{8,12}:[A-Za-z0-9_-]{30,}\b/g],
  ['supabase_service_jwt', /\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b/g],
];

export function scanTrackedFiles(root = process.cwd()) {
  const names = execFileSync('git', ['ls-files', '-co', '--exclude-standard'], { cwd: root, encoding: 'utf8' })
    .split(/\r?\n/).filter(Boolean)
    .filter((name) => TEXT_EXTENSIONS.has(extname(name).toLowerCase()))
    .filter((name) => !name.startsWith('node_modules/'));
  const findings = [];
  for (const name of names) {
    let body;
    try { body = readFileSync(`${root}/${name}`, 'utf8'); } catch { continue; }
    for (const [rule, pattern] of RULES) {
      pattern.lastIndex = 0;
      for (const match of body.matchAll(pattern)) {
        const line = body.slice(0, match.index).split('\n').length;
        findings.push({ file: name, line, rule });
      }
    }
  }
  return findings;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const findings = scanTrackedFiles();
  if (findings.length) {
    console.error(JSON.stringify({ ok: false, findings }, null, 2));
    process.exitCode = 1;
  } else {
    console.log('Secret scan passed: no high-confidence credential patterns found.');
  }
}
