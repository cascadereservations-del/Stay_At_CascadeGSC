import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const cssPath = new URL('../assets/css/cascade-luxury.css', import.meta.url);
const css = await readFile(cssPath, 'utf8');
const html = await readFile(new URL('../index.html', import.meta.url), 'utf8');

/* Strip comments so the brace/at-rule checks below see only real CSS. */
function stripComments(source) {
  let out = '';
  let i = 0;
  while (i < source.length) {
    if (source.startsWith('/*', i)) {
      const end = source.indexOf('*/', i + 2);
      assert.notEqual(end, -1, `unterminated /* comment at offset ${i}`);
      i = end + 2;
      continue;
    }
    out += source[i];
    i += 1;
  }
  return out;
}

/* A `*/` with no matching `/*` is how the desktop hero media query was lost:
   the parser treated the stray comment tail as the start of a selector and
   swallowed the whole @media block that followed it. */
test('stylesheet has no orphaned comment delimiters', () => {
  const opens = (css.match(/\/\*/g) || []).length;
  const closes = (css.match(/\*\//g) || []).length;
  assert.equal(opens, closes, `${opens} "/*" vs ${closes} "*/" — a comment is unbalanced`);

  let depth = 0;
  const token = /\/\*|\*\//g;
  let match;
  while ((match = token.exec(css)) !== null) {
    if (match[0] === '/*') {
      depth += 1;
    } else {
      depth -= 1;
      assert.ok(depth >= 0, `orphaned "*/" at offset ${match.index} — the "/*" is missing`);
    }
  }
});

test('stylesheet braces are balanced', () => {
  const body = stripComments(css);
  let depth = 0;
  for (let i = 0; i < body.length; i += 1) {
    if (body[i] === '{') depth += 1;
    if (body[i] === '}') {
      depth -= 1;
      assert.ok(depth >= 0, `unmatched "}" at offset ${i}`);
    }
  }
  assert.equal(depth, 0, `${depth} unclosed block(s)`);
});

/* Every at-rule must start at a real `@`. If a preceding rule silently
   consumed one, this catches the count drifting to zero. */
test('the desktop hero media query survives parsing', () => {
  const body = stripComments(css);
  const desktopBlocks = body.match(/@media\s*\(min-width:\s*768px\)/g) || [];
  assert.ok(desktopBlocks.length >= 1, 'the (min-width: 768px) hero block is missing');
  assert.match(body, /@media\s*\(min-width:\s*768px\)\s*\{[^@]*\.theme-quiet-luxury\s+\.hero-bk\s*\{[^}]*margin-top:/s);
});

test('the hero booking card is a frosted-glass surface', () => {
  assert.match(css, /\.theme-quiet-luxury\s+\.hero-bk\s*\{[^}]*backdrop-filter:\s*blur\(/s);
  assert.match(css, /@supports not \(\(backdrop-filter/);
});

test('the stylesheet is cache-busted whenever it changes', () => {
  assert.match(html, /assets\/css\/cascade-luxury\.css\?v=\d{8}[a-z]/);
});
