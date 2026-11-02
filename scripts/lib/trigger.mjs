// trigger.mjs — who started a run, from where and why (docs/reporting.md → **Who started the run**)
// for the records of runs by hand (scripts/rerun.mjs, scripts/features.mjs record). A person's name
// and the reason are a person's or an issue's words, so they arrive only in the call's own file
// (lib/words.mjs, <kind> = trigger): one JSON object {"via", "who", "why"}.

import { takeWords } from './words.mjs';

export const VIA = ['github', 'schedule', 'slack', 'chat', 'dashboard', 'discovery', 'profile'];
const line = (x, n) => (typeof x === 'string' && x.replace(/\s+/g, ' ').trim() ? x.replace(/\s+/g, ' ').trim().slice(0, n) : null);

// takeTrigger(<path>): {via, who, why} from the file, the file then removed. Throws on a file that is
// not the call's own, not one JSON object, or a `via` outside VIA.
export function takeTrigger(path) {
  let t;
  try { t = JSON.parse(takeWords(path, 'trigger')); } catch (e) { throw new Error(e instanceof SyntaxError ? `${path}: not JSON` : e.message); }
  if (!t || typeof t !== 'object' || Array.isArray(t)) throw new Error(`${path}: not one JSON object`);
  if (!VIA.includes(t.via)) throw new Error(`${path}: "via" is one of ${VIA.join(', ')}`);
  return { via: t.via, who: line(t.who, 80), why: line(t.why, 200) };
}
