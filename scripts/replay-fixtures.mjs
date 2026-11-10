#!/usr/bin/env node
// Builds one replay stream from the real incident fixtures, in chronological
// order, with sequence numbers renumbered so the engine reads it as one feed:
//   node scripts/replay-fixtures.mjs var/replay.jsonl
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const fixtures = [
  'apps/engine/test/fixtures/incidents/usdc-depeg-2023-03-11.jsonl',
  'apps/engine/test/fixtures/incidents/euler-finance-2023-03-13.jsonl',
];
const out = process.argv[2] ?? path.join(root, 'var/replay.jsonl');

let seq = 0;
const lines = [];
for (const f of fixtures) {
  for (const line of fs.readFileSync(path.join(root, f), 'utf8').split('\n')) {
    if (!line.trim()) continue;
    const m = JSON.parse(line);
    m.seq = ++seq;
    lines.push(JSON.stringify(m));
  }
}
fs.mkdirSync(path.dirname(out), { recursive: true });
fs.writeFileSync(out, lines.join('\n') + '\n');
console.log(`replay stream: ${lines.length} messages from ${fixtures.length} incidents -> ${path.relative(root, out)}`);
