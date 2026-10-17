// Reproducible check for the PCF8591 I2C ADC: serve the part on the bus
// (CF_DEVICES) with AIN0 = 2.5 V over a 5 V reference, run pcf8591_read and assert
// the 8-bit code. Exit 0/1.
//
//   arduino-cli compile --fqbn arduino:avr:uno --output-dir build/pcf8591_read \
//     sketches/pcf8591_read
//   node verify_pcf8591.mjs build/pcf8591_read/pcf8591_read.ino.hex
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const hexPath = process.argv[2] ?? join(here, '..', 'build', 'pcf8591_read', 'pcf8591_read.ino.hex');

const raw = execFileSync(process.execPath, [join(here, 'run.mjs'), hexPath, '400'], {
  encoding: 'utf8',
  env: { ...process.env, CF_DEVICES: '[{"kind":"pcf8591","address":72,"ain":[2.5,0,0,0],"vref":5}]' },
});
const { serial, devices } = JSON.parse(raw);
const dev = (devices && devices[0]) || {};

const failures = [];
if (serial.trim() !== 'adc 128') failures.push(`serial "${serial.trim()}" (want "adc 128")`);
if (dev.read !== 128) failures.push(`dev.read=${dev.read} (want 128)`);
if (!dev.ain || dev.ain[0] !== 2.5) failures.push(`ain[0]=${dev.ain && dev.ain[0]} (want 2.5)`);

console.log(`serial="${serial.trim()}" read=${dev.read} ain0=${dev.ain && dev.ain[0]}`);
if (failures.length) {
  console.error(`FAIL:\n  ${failures.join('\n  ')}`);
  process.exit(1);
}
console.log('PASS: PCF8591 read 2.5 V on AIN0 as code 128 (8-bit, 5 V ref)');
