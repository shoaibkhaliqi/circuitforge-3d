// Reproducible check for a STEP/DIR stepper driver: recover the commanded move from the
// pin transitions. Like the servo, a stepper is an output - the MCU's own pulses are the
// evidence - so no device model is needed.
// Exit 0/1.
//
//   arduino-cli compile --fqbn arduino:avr:uno --output-dir build/stepper_sweep \
//     sketches/stepper_sweep
//   node verify_stepper.mjs build/stepper_sweep/stepper_sweep.ino.hex
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const hexPath = process.argv[2] ?? join(here, '..', 'build', 'stepper_sweep', 'stepper_sweep.ino.hex');

const STEP_PIN = 3;
const DIR_PIN = 2;

// Count STEP rising edges, taking the direction from the DIR level at each edge
// (reset state: every pin low). Returns the signed count and the splits.
const decode = (transitions, dirHighForward = true) => {
  const out = { steps: 0, forward: 0, reverse: 0, rising: 0, lastDir: 0, minHighUs: Infinity };
  let level = 0;
  let dir = 0;
  let rise = null;
  for (const tr of transitions) {
    if (tr.digital_pin === DIR_PIN) { dir = tr.level; continue; }
    if (tr.digital_pin !== STEP_PIN) continue;
    if (tr.level === 1 && level === 0) {
      out.rising += 1;
      const fwd = dirHighForward ? dir === 1 : dir === 0;
      out.steps += fwd ? 1 : -1;
      if (fwd) out.forward += 1; else out.reverse += 1;
      rise = tr.t_ms;
    } else if (tr.level === 0 && rise !== null) {
      out.minHighUs = Math.min(out.minHighUs, (tr.t_ms - rise) * 1000);
      rise = null;
    }
    level = tr.level;
  }
  out.lastDir = dir;
  return out;
};

const raw = execFileSync(process.execPath, [join(here, 'run.mjs'), hexPath, '400'], { encoding: 'utf8' });
const { serial = '', transitions = [] } = JSON.parse(raw);
const failures = [];

const got = decode(transitions);
console.log(`commands: +200 then -100 then +50 -> measured ${got.forward} forward, ${got.reverse} reverse, net ${got.steps}`);
console.log(`STEP high pulse >= ${got.minHighUs.toFixed(1)} us (A4988 needs >= 1 us), ${got.rising} edges`);

if (got.steps !== 150) failures.push(`net steps ${got.steps} (want +150)`);
if (got.forward !== 250) failures.push(`forward steps ${got.forward} (want 250)`);
if (got.reverse !== 100) failures.push(`reverse steps ${got.reverse} (want 100)`);
if (got.rising !== 350) failures.push(`STEP rising edges ${got.rising} (want 350)`);
if (got.lastDir !== 1) failures.push(`final DIR level ${got.lastDir} (want 1 = forward)`);
if (got.minHighUs < 1.0) failures.push(`STEP high pulse ${got.minHighUs.toFixed(2)} us is shorter than the driver's 1 us minimum`);
if (!(got.minHighUs > 0 && got.minHighUs < 100)) failures.push(`STEP high pulse ${got.minHighUs.toFixed(2)} us is not in a plausible range`);

// The polarity is a decoder option: flipping it must flip the net travel.
const flipped = decode(transitions, false);
if (flipped.steps !== -150) failures.push(`dir_high_forward=false gives ${flipped.steps} (want -150)`);
console.log(`with dir_high_forward=false -> net ${flipped.steps} steps`);

// No pulses on another pin means no steps.
const other = decode(transitions.filter((t) => t.digital_pin !== STEP_PIN));
if (other.rising !== 0 || other.steps !== 0) failures.push(`another pin shows ${other.rising} steps (want 0)`);

for (const line of ['stepper 200 forward', 'stepper 100 reverse', 'stepper 50 forward', 'stepper done 150']) {
  if (!serial.includes(line)) failures.push(`sketch did not report "${line}"`);
}

if (failures.length) {
  console.error(`FAIL:\n  ${failures.join('\n  ')}`);
  process.exit(1);
}
console.log('PASS: STEP/DIR pulse train decodes to the commanded +150 net steps (250 fwd / 100 rev)');
