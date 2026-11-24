#!/usr/bin/env node
// collections.mjs — the operator's collections of tests, work/CATALOG.md (docs/catalog.md → Describing and
// categorizing): `| collection | members |`, the members comma-separated (#42, #42 AC-1, S-7, S-7 AC-1).
// The operator's word, in the direct session only; their press on the dashboard the dashboard server writes
// itself (lib/collections.mjs). Local only.
//
//   node collections.mjs add <name> <ref>…      -> {"collection", "members"}   a new name makes the collection
//   node collections.mjs remove <name> <ref>…   -> {"collection", "members"}   an emptied collection goes
//
// <name>: letters, digits, spaces and _ . - (at most 40, the first a letter or digit). <ref>: #N[ AC-k|IN-k] or
// S-k[ AC-j], one argument each. Exit 2: usage, a bad name or ref, or not the direct session.
import { join } from 'node:path';
import { changeCollection } from './lib/collections.mjs';
import { WORK, sh } from './lib/util.mjs';

const die = (m) => { process.stderr.write(`collections.mjs: ${m}\n`); process.exit(2); };
const [cmd, name, ...refs] = process.argv.slice(2);
if (!['add', 'remove'].includes(cmd) || !name || !refs.length) die('usage: collections.mjs add|remove <name> <ref>…');
if (sh('direct_session && echo yes') !== 'yes') die(`${cmd} is the operator's, in the direct session only`);
let members;
try { members = changeCollection(join(WORK, 'CATALOG.md'), cmd, name, refs); } catch (e) { die(e.message); }
process.stdout.write(`${JSON.stringify({ collection: name, members })}\n`);
