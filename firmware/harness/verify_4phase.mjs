// Reproducible check for a four-phase (ULN2003 + 28BYJ-48) stepper: recover the travel from
// the phase-pin transitions alone. As with the servo and STEP/DIR stepper, the motor is an
// output, so no device model is involved.
// Exit 0/1.
//
//   arduino-cli compile --fqbn arduino:avr:uno --output-dir build/stepper_4phase \
//     sketches/stepper_4phase
//   node verify_4phase.mjs build/stepper_4phase/stepper_4phase.ino.hex
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const hexPath = process.argv[2] ?? join(here, '..', 'build', 'stepper_4phase', 'stepper_4phase.ino.hex');

const PHASE_PINS = [8, 9, 10, 11];           // IN1..IN4
const CYCLE = [0b0001, 0b0011, 0b0010, 0b0110, 0b0100, 0b1100, 0b1000, 0b1001];

// One pattern per port write (transitions sharing a timestamp are the same write), then walk
// the cycle by the shortest signed distance. Wave and full-step driving hop two entries,
// half-step driving one.
const decode = (transitions, reverse = false) => {
  const out = { steps: 0, changes: 0, forward: 0, reverse: 0, skipped: 0 };
  const patterns = [];
  let pattern = 0;
  let groupT = null;
  for (const tr of transitions) {
    const i = PHASE_PINS.indexOf(tr.digital_pin);
    if (i < 0) continue;
    if (groupT !== null && tr.t_ms !== groupT) patterns.push(pattern);
    groupT = tr.t_ms;
    if (tr.level === 1) pattern |= 1 << i; else pattern &= ~(1 << i);
  }
  if (groupT !== null) patterns.push(pattern);
  let last = -1;
  for (const pat of patterns) {
    const idx = CYCLE.indexOf(pat);
    if (idx < 0) { last = -1; out.skipped += 1; continue; }
    if (last < 0) { last = idx; continue; }
    let delta = idx - last;
    if (delta > 4) delta -= 8; else if (delta < -4) delta += 8;
    last = idx;
    if (delta === 0) continue;
    if (Math.abs(delta) === 4) { out.skipped += 1; continue; }
    if (reverse) delta = -delta;
    out.steps += delta;
    out.changes += 1;
    if (delta > 0) out.forward += delta; else out.reverse += -delta;
  }
  return out;
};

const raw = execFileSync(process.execPath, [join(here, 'run.mjs'), hexPath, '500'], { encoding: 'utf8' });
const { serial = '', transitions = [] } = JSON.parse(raw);
const failures = [];

// The sketch: 32 half steps forward, then 8 wave steps reverse (-16 half steps),
// then 8 wave steps forward (+16) = net +32 half steps, with two coil-off gaps.
const got = decode(transitions);
console.log(`half 32 fwd, wave 8 rev, wave 8 fwd -> ${got.changes} pattern changes,`
  + ` net ${got.steps} half steps (${got.forward} fwd / ${got.reverse} rev), ${got.skipped} skipped`);

if (got.steps !== 32) failures.push(`net half steps ${got.steps} (want +32)`);
if (got.changes !== 48) failures.push(`pattern changes ${got.changes} (want 48)`);
if (got.forward !== 48) failures.push(`forward half steps ${got.forward} (want 48)`);
if (got.reverse !== 16) failures.push(`reverse half steps ${got.reverse} (want 16)`);
if (got.skipped !== 2) failures.push(`skipped patterns ${got.skipped} (want 2 coil-off gaps)`);

// Reversing coil order (or the decoder's convention) must flip the travel.
const flipped = decode(transitions, true);
if (flipped.steps !== -32) failures.push(`reversed convention gives ${flipped.steps} (want -32)`);
console.log(`with the coil order reversed -> net ${flipped.steps} half steps`);

for (const line of ['half 32 fwd', 'wave 8 rev', 'wave 8 fwd', '4phase done 32']) {
  if (!serial.includes(line)) failures.push(`sketch did not report "${line}"`);
}

if (failures.length) {
  console.error(`FAIL:\n  ${failures.join('\n  ')}`);
  process.exit(1);
}
console.log('PASS: four-phase sequence decodes to the commanded net +32 half steps across half-step and wave driving');
