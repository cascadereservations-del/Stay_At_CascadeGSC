// cascade-core format (Cassy, 2026-09-13, D-104). The ADHD/ELI5 report shape, owned by code:
// one decision line, at most five lines, one action, then the model that answered.
export type Report = { decision: string; lines: string[]; action: string };

// Models like to number their lines; the bullet is ours, so "1. ", "1) " and leading "• " are dropped.
const clean = (s: unknown) => String(s ?? '').replace(/\s+/g, ' ').trim().replace(/^(?:[•\-*]\s*)?(?:\d{1,2}[.)]\s+)?/, '');

/** Lenient parse of the model's final text: JSON (fenced or bare) first, else first line = decision. */
export function parseReport(text: string): Report {
  const raw = text.replace(/^```(?:json)?\s*|\s*```$/g, '').trim();
  const start = raw.indexOf('{'), end = raw.lastIndexOf('}');
  if (start >= 0 && end > start) {
    try {
      const j = JSON.parse(raw.slice(start, end + 1));
      const lines = Array.isArray(j.lines) ? j.lines.map(clean).filter(Boolean) : clean(j.lines) ? [clean(j.lines)] : [];
      const decision = clean(j.decision);
      // A JSON blob without our keys (a model quoting data) is not a report; read the text instead.
      if (decision || lines.length) return { decision, lines, action: clean(j.action) };
    } catch { /* fall through to plain text */ }
  }
  // Plain text or "decision: … / lines: … / action: …" pseudo-YAML (seen live from flash, 2026-09-13).
  const ls = raw.replace(/[{}[\]"]/g, ' ').split(/\r?\n/).map(clean).filter(Boolean);
  let decision = '', action = '';
  const lines: string[] = [];
  for (const l of ls) {
    const m = /^(decision|lines|action)\s*:\s*(.*)$/i.exec(l);
    if (m) {
      const v = clean(m[2].replace(/^['"]|['"]$/g, ''));
      if (m[1].toLowerCase() === 'decision') decision = v;
      else if (m[1].toLowerCase() === 'action') action = v;
      else if (v) lines.push(v);
      continue;
    }
    const v = clean(l.replace(/^['"]|['"],?$/g, ''));
    if (!decision) decision = v; else lines.push(v);
  }
  return { decision, lines, action };
}

/** Model line names who answered; code-built reports (daily-digest) pass '' and get no signature. */
export function renderReport(r: Report, model = ''): string {
  const out: string[] = [r.decision || 'Nothing needs you right now.'];
  const lines = r.lines.slice(0, 5);
  if (lines.length) out.push('', ...lines.map((l) => `• ${l}`));
  if (r.action) out.push('', `Do: ${r.action}`);
  if (model) out.push('', `— ${model}`);
  return out.join('\n');
}
