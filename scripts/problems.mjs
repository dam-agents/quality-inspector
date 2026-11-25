#!/usr/bin/env node
// problems.mjs — the operator's dismissal of a dashboard problem F-<k>, work/PROBLEMS.md
// (docs/dashboard-page.md → Problems). The operator's word, in the direct session only; their press
// on the dashboard the dashboard server writes itself (lib/problems.mjs). Local only.
//
//   node problems.mjs dismiss F-<k> [false-positive|wont-fix|duplicate|by-design]  -> {"id", "title", "dismissed"}
//   node problems.mjs reopen F-<k>                                                  -> {"id", "title", "reopened"}
//
// F-<k> is the page's number, read from the newest catalog data (work/catalog/data.json). Exit 2:
// usage, an unknown problem or reason, or not the direct session.
import { join } from 'node:path';
import { changeProblem } from './lib/problems.mjs';
import { WORK, now, readJson, sh } from './lib/util.mjs';

const die = (m) => { process.stderr.write(`problems.mjs: ${m}\n`); process.exit(2); };
const [cmd, id, reason, ...rest] = process.argv.slice(2);
if (!['dismiss', 'reopen'].includes(cmd) || !/^F-\d{1,6}$/.test(id ?? '') || rest.length || (cmd === 'reopen' && reason)) die('usage: problems.mjs dismiss F-<k> [reason] | reopen F-<k>');
if (sh('direct_session && echo yes') !== 'yes') die(`${cmd} is the operator's, in the direct session only`);
let done;
try { done = changeProblem(join(WORK, 'PROBLEMS.md'), readJson(join(WORK, 'catalog', 'data.json'))?.runs, cmd, id, reason ?? null, now()); } catch (e) { die(e.message); }
process.stdout.write(`${JSON.stringify(done)}\n`);
