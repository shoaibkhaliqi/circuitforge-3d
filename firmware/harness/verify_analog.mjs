// Reproducible check for circuit -> firmware analog feedback: set ADC channel 0
// to 2.5 V (CF_ADC), run the analog_read sketch and assert analogRead(A0) returns
// 512 (round(2.5/5*1023)). Exit 0/1.
//
//   arduino-cli compile --fqbn arduino:avr:uno --output-dir build/analog_read sketches/analog_read
//   node verify_analog.mjs build/analog_read/analog_read.ino.hex
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const hexPath = process.argv[2] ?? join(here, '..', 'build', 'analog_read', 'analog_read.ino.hex');

const raw = execFileSync(process.execPath, [join(here, 'run.mjs'), hexPath, '1600'], {
  encoding: 'utf8',
  env: { ...process.env, CF_ADC: JSON.stringify({ 0: 2.5 }) },
});
const { serial, adc } = JSON.parse(raw);

const failures = [];
if (adc['0'] !== 2.5) failures.push(`adc[0] = ${adc && adc['0']} (want 2.5)`);
const m = serial.match(/adc (\d+)/);
if (!m) failures.push(`no "adc N" line in serial: ${JSON.stringify(serial)}`);
else if (m[1] !== '512') failures.push(`analogRead(A0) = ${m[1]} (want 512 for 2.5 V)`);

console.log(`adc channels: ${JSON.stringify(adc)}`);
console.log(`serial: ${JSON.stringify(serial.slice(0, 40))}`);

if (failures.length) {
  console.error(`FAIL:\n  ${failures.join('\n  ')}`);
  process.exit(1);
}
console.log('PASS: analogRead(A0) read 2.5 V from the harness ADC (circuit -> firmware)');
