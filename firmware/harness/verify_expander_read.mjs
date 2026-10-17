// Reproducible check for device -> firmware feedback: attach a PCF8574 with
// inputs = 0x0F (P0..P3 held low), run the expander_read sketch and assert the
// firmware read 0xF0 back (Serial prints "port 240"). Exit 0/1.
//
//   arduino-cli compile --fqbn arduino:avr:uno --output-dir build/expander_read sketches/expander_read
//   node verify_expander_read.mjs build/expander_read/expander_read.ino.hex
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const hexPath = process.argv[2] ?? join(here, '..', 'build', 'expander_read', 'expander_read.ino.hex');

const devices = [{ kind: 'pcf8574', address: 0x27, state: 0xff, inputs: 0x0f }];
const raw = execFileSync(process.execPath, [join(here, 'run.mjs'), hexPath, '2200'], {
  encoding: 'utf8',
  env: { ...process.env, CF_DEVICES: JSON.stringify(devices) },
});
const { i2c, serial, devices: devs } = JSON.parse(raw);

const failures = [];
if (!serial.includes('port 240')) failures.push(`serial did not report 240: ${JSON.stringify(serial)}`);
const reads = i2c.filter((t) => t.address === 0x27 && t.write === false);
if (reads.length < 3) failures.push(`only ${reads.length} read transactions (want >= 3)`);
for (const t of reads) {
  if (t.bytes[0] !== 0xf0) failures.push(`read byte ${t.bytes[0]} (want 0xf0)`);
}
const dev = (devs ?? []).find((d) => d.kind === 'pcf8574');
if (!dev || dev.read !== 0xf0) failures.push(`device summary read=${dev && dev.read}`);

console.log(`read transactions: ${reads.length}`);
console.log(`device: ${JSON.stringify(dev)}`);
console.log(`serial: ${JSON.stringify(serial.slice(0, 40))}`);

if (failures.length) {
  console.error(`FAIL:\n  ${failures.join('\n  ')}`);
  process.exit(1);
}
console.log('PASS: firmware read 0xF0 from the PCF8574 (device -> firmware feedback)');
