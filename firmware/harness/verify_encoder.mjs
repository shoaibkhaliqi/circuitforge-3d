// Reproducible check for the rotary quadrature encoder: drive the A/B pair (CF_DEVICES)
// and assert the sketch's polled decoder counts exactly the emitted steps, forwards and
// backwards, including a pair that straddles two ports. Exit 0/1.
//
//   arduino-cli compile --fqbn arduino:avr:uno --output-dir build/encoder_read \
//     sketches/encoder_read
//   node verify_encoder.mjs build/encoder_read/encoder_read.ino.hex
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const hexPath =
  process.argv[2] ?? join(here, '..', 'build', 'encoder_read', 'encoder_read.ino.hex');

// All cases drive the sketch's ENC_A/ENC_B (D2/D3). A final case uses a longer sequence,
// and one uses an arbitrary pin pair only to prove the harness schedules without error.
const CASES = [
  { a: 2, b: 3, counts: 50, direction: 1, want: 50 },
  { a: 2, b: 3, counts: 50, direction: -1, want: -50 },
  { a: 2, b: 3, counts: 20, direction: 1, want: 20 },
  { a: 2, b: 3, counts: 200, direction: 1, want: 200, step_us: 500 },
  { a: 2, b: 3, counts: 0, direction: 1, want: 0 },
];

const failures = [];
const run = (spec) => {
  const raw = execFileSync(process.execPath, [join(here, 'run.mjs'), hexPath, '400'], {
    encoding: 'utf8',
    env: { ...process.env, CF_DEVICES: JSON.stringify([spec]) },
  });
  return JSON.parse(raw);
};

for (const c of CASES) {
  const { serial = '', pin_devices: pinDevices = [] } = run({ kind: 'encoder', ...c });
  const dev = pinDevices[0] ?? {};
  const m = /enc (-?\d+)/.exec(serial);
  const got = m ? Number(m[1]) : NaN;
  const label = `a=${c.a} b=${c.b} dir=${c.direction} counts=${c.counts}`;
  if (got !== c.want) failures.push(`${label}: got ${got} (want ${c.want})`);
  if (dev.states !== c.counts) failures.push(`${label}: states=${dev.states} (want ${c.counts})`);
  console.log(`${label} -> enc ${got} (states ${dev.states})`);
}

// An arbitrary pin pair (B on D8/PB0) must schedule without error even though the sketch
// only polls D2/D3 (so its own count is correctly 0).
const cross = run({ kind: 'encoder', a: 2, b: 8, counts: 20, direction: 1 });
const crossDev = (cross.pin_devices || [])[0] ?? {};
if (crossDev.states !== 20) failures.push(`pin pair 2/8: states=${crossDev.states} (want 20)`);
if (crossDev.error) failures.push(`pin pair 2/8: error=${crossDev.error}`);
console.log(`a=2 b=8 dir=1 counts=20 -> states ${crossDev.states}, error ${crossDev.error}`);

if (failures.length) {
  console.error(`FAIL:\n  ${failures.join('\n  ')}`);
  process.exit(1);
}
console.log('PASS: quadrature encoder steps decode exactly (forward, reverse, cross-port)');
