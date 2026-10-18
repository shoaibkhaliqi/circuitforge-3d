// Reproducible check for the servo driver: run a 50 Hz software-PWM sweep and recover
// the commanded angle from the pin's recorded transitions (no device model is needed -
// the servo is an output, so the MCU's own pulse train is the evidence).
// Exit 0/1.
//
//   arduino-cli compile --fqbn arduino:avr:uno --output-dir build/servo_sweep \
//     sketches/servo_sweep
//   node verify_servo.mjs build/servo_sweep/servo_sweep.ino.hex
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const hexPath = process.argv[2] ?? join(here, '..', 'build', 'servo_sweep', 'servo_sweep.ino.hex');

const PIN = 9;
const MIN_US = 544;
const MAX_US = 2400;
const RANGE_DEG = 180;
const SWEEP = [0, 30, 60, 90, 120, 150, 180];
const TOL_DEG = 3; // the sketch's own micros()-loop timing error, ~+8 us per pulse

const widths = (transitions) => {
  const out = [];
  let rise = null;
  for (const tr of transitions) {
    if (tr.digital_pin !== PIN) continue;
    if (tr.level === 1) rise = tr.t_ms;
    else if (rise !== null) { out.push(Math.round((tr.t_ms - rise) * 1000)); rise = null; }
  }
  return out;
};
const angleOf = (us) => Math.max(0, Math.min(RANGE_DEG, ((us - MIN_US) / (MAX_US - MIN_US)) * RANGE_DEG));

const raw = execFileSync(process.execPath, [join(here, 'run.mjs'), hexPath, '1500'], { encoding: 'utf8' });
const { serial = '', transitions = [] } = JSON.parse(raw);
const pulses = widths(transitions);
const failures = [];

// The sketch announces seven 30-degree steps (3 pulses each) then settles at 90 (15 pulses).
if (pulses.length !== 21 + 15) failures.push(`expected 36 pulses, measured ${pulses.length}`);
for (let i = 0; i < SWEEP.length; i++) {
  const want = SWEEP[i];
  const got = pulses.slice(i * 3, i * 3 + 3).map(angleOf);
  for (const a of got) {
    if (Math.abs(a - want) > TOL_DEG) failures.push(`step ${want}deg: measured ${a.toFixed(2)}deg`);
  }
  if (got.length) console.log(`step ${String(want).padStart(3)}deg -> ${got.map((a) => a.toFixed(1)).join(' / ')}deg`);
}
const settled = pulses.slice(21).map(angleOf);
for (const a of settled) {
  if (Math.abs(a - 90) > TOL_DEG) failures.push(`settled pulse measured ${a.toFixed(2)}deg (want 90)`);
}
console.log(`settle 90deg -> ${settled.map((a) => a.toFixed(1)).join(' / ')}deg (${settled.length} pulses)`);

if (!/servo settle 90/.test(serial)) failures.push(`sketch did not report the settle phase: ${JSON.stringify(serial)}`);
const span = { min: Math.min(...pulses), max: Math.max(...pulses) };
if (span.min < MIN_US || span.max > MAX_US + 12) failures.push(`pulse span ${span.min}..${span.max} us is outside the servo band`);

if (failures.length) {
  console.error(`FAIL:\n  ${failures.join('\n  ')}`);
  process.exit(1);
}
console.log(`PASS: 50 Hz servo pulse train decodes to the commanded 0..180 deg sweep (pulses ${span.min}..${span.max} us)`);
