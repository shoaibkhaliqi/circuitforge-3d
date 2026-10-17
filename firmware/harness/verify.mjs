// Reproducible check for the M7 spike: compile nothing here — it runs the harness
// on an already-built HEX and asserts the D13 blink is a clean, deterministic
// ~1 Hz square wave. Exit 0 on pass, 1 on fail.
//
//   arduino-cli compile --fqbn arduino:avr:uno --output-dir build/blink sketches/blink
//   node verify.mjs build/blink/blink.ino.hex
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const hexPath = process.argv[2] ?? join(here, '..', 'build', 'blink', 'blink.ino.hex');

const raw = execFileSync(process.execPath, [join(here, 'run.mjs'), hexPath, '2500'], {
  encoding: 'utf8',
});
const { transitions } = JSON.parse(raw);

const d13 = transitions.filter((t) => t.digital_pin === 13);
const edges = [];
for (let i = 1; i < d13.length; i++) {
  edges.push(d13[i].t_ms - d13[i - 1].t_ms);
}

const failures = [];
if (d13.length < 4) failures.push(`only ${d13.length} D13 transitions (want >= 4)`);
for (const gap of edges) {
  if (Math.abs(gap - 500) > 1) failures.push(`edge gap ${gap} ms not ~500 ms`);
}
if (d13[0] && d13[0].level !== 1) failures.push('D13 did not start HIGH');

console.log(`D13 transitions: ${d13.length}`);
console.log(`edge gaps (ms): ${edges.map((g) => g.toFixed(3)).join(', ')}`);

if (failures.length) {
  console.error(`FAIL:\n  ${failures.join('\n  ')}`);
  process.exit(1);
}
console.log('PASS: deterministic ~1 Hz blink on D13 (open-loop Stage B spike)');
