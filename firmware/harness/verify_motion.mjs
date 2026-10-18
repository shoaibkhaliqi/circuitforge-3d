// Capstone check for the two firmware-driven *actuators* in one run: a servo's commanded
// angle is recovered from its 50 Hz pulse train and a STEP/DIR stepper's travel from the
// STEP edges (with DIR held at each one), out of the same transition record. Neither is a
// device model - the MCU's own pulses are the evidence.
// Exit 0/1.
//
//   arduino-cli compile --fqbn arduino:avr:uno --output-dir build/motion_demo \
//     sketches/motion_demo
//   node verify_motion.mjs build/motion_demo/motion_demo.ino.hex
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const hexPath = process.argv[2] ?? join(here, '..', 'build', 'motion_demo', 'motion_demo.ino.hex');

const SERVO_PIN = 9;
const STEP_PIN = 3;
const DIR_PIN = 2;
const MIN_US = 544;
const MAX_US = 2400;
const RANGE_DEG = 180;
const TOL_DEG = 3; // the sketch's own micros()-loop error, ~+6..9 us per pulse

const widths = (transitions) => {
  const out = [];
  let rise = null;
  for (const tr of transitions) {
    if (tr.digital_pin !== SERVO_PIN) continue;
    if (tr.level === 1) rise = tr.t_ms;
    else if (rise !== null) { out.push(Math.round((tr.t_ms - rise) * 1000)); rise = null; }
  }
  return out;
};
const angleOf = (us) => Math.max(0, Math.min(RANGE_DEG, ((us - MIN_US) / (MAX_US - MIN_US)) * RANGE_DEG));

const steps = (transitions) => {
  const out = { net: 0, forward: 0, reverse: 0, rising: 0, minHighUs: Infinity, lastDir: 0 };
  let level = 0;
  let dir = 0;
  let rise = null;
  for (const tr of transitions) {
    if (tr.digital_pin === DIR_PIN) { dir = tr.level; continue; }
    if (tr.digital_pin !== STEP_PIN) continue;
    if (tr.level === 1 && level === 0) {
      out.rising += 1;
      if (dir === 1) { out.net += 1; out.forward += 1; } else { out.net -= 1; out.reverse += 1; }
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

const raw = execFileSync(process.execPath, [join(here, 'run.mjs'), hexPath, '1500'], { encoding: 'utf8' });
const { serial = '', transitions = [] } = JSON.parse(raw);
const failures = [];

// --- stepper: 200 forward then 50 back, interleaved with the servo pulses ---
const st = steps(transitions);
console.log(`stepper: ${st.forward} forward / ${st.reverse} reverse, net ${st.net} `
  + `(${st.rising} edges, min STEP high ${st.minHighUs.toFixed(1)} us)`);
if (st.net !== 150) failures.push(`net steps ${st.net} (want +150)`);
if (st.forward !== 200) failures.push(`forward steps ${st.forward} (want 200)`);
if (st.reverse !== 50) failures.push(`reverse steps ${st.reverse} (want 50)`);
if (st.rising !== 250) failures.push(`STEP rising edges ${st.rising} (want 250)`);
if (st.lastDir !== 0) failures.push(`final DIR level ${st.lastDir} (want 0 = reverse)`);
if (!(st.minHighUs >= 1.0 && st.minHighUs < 100)) {
  failures.push(`STEP high pulse ${st.minHighUs.toFixed(2)} us is outside 1..100 us`);
}

// --- servo: 0..180 in 36-degree plateaus, then settle at 90 ---
const pulses = widths(transitions);
const ang = pulses.map(angleOf);
console.log(`servo: ${pulses.length} pulses, widths ${Math.min(...pulses)}..${Math.max(...pulses)} us, `
  + `angles ${Math.min(...ang).toFixed(1)}..${Math.max(...ang).toFixed(1)} deg, final ${ang[ang.length - 1].toFixed(1)} deg`);
if (pulses.length < 40) failures.push(`only ${pulses.length} servo pulses recorded`);
if (Math.abs(Math.min(...ang)) > TOL_DEG) failures.push(`servo did not reach 0 deg (min ${Math.min(...ang).toFixed(1)})`);
if (Math.abs(Math.max(...ang) - 180) > TOL_DEG) failures.push(`servo did not reach 180 deg (max ${Math.max(...ang).toFixed(1)})`);
for (const a of ang.slice(-5)) {
  if (Math.abs(a - 90) > TOL_DEG) failures.push(`servo settled at ${a.toFixed(1)} deg (want 90)`);
}
// The schedule only ever climbs to 180 and then comes back to 90, so the angles must be
// non-decreasing up to the peak and non-increasing after it.
const peak = ang.indexOf(Math.max(...ang));
for (let i = 1; i <= peak; i++) {
  if (ang[i] < ang[i - 1] - TOL_DEG) failures.push(`angle fell before the peak: ${ang[i - 1].toFixed(1)} -> ${ang[i].toFixed(1)}`);
}
for (let i = peak + 1; i < ang.length; i++) {
  if (ang[i] > ang[i - 1] + TOL_DEG) failures.push(`angle rose after the peak: ${ang[i - 1].toFixed(1)} -> ${ang[i].toFixed(1)}`);
}
const span = { min: Math.min(...pulses), max: Math.max(...pulses) };
if (span.min < MIN_US || span.max > MAX_US + 12) failures.push(`pulse span ${span.min}..${span.max} us is outside the servo band`);

for (const line of ['motion demo', 'stepper 200 forward', 'stepper 50 reverse']) {
  if (!serial.includes(line)) failures.push(`sketch did not report "${line}"`);
}

if (failures.length) {
  console.error(`FAIL:\n  ${failures.join('\n  ')}`);
  process.exit(1);
}
console.log(`PASS: one run drives both actuators - servo 0..180 settling at 90 deg `
  + `(${span.min}..${span.max} us) and stepper net +150 steps (200 fwd / 50 rev)`);
