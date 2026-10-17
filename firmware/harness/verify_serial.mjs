// Reproducible check for the UART/protocol surface of the M7 spike: runs the
// serial sketch and asserts its Serial.print output was captured. Exit 0/1.
//
//   arduino-cli compile --fqbn arduino:avr:uno --output-dir build/serial_hello sketches/serial_hello
//   node verify_serial.mjs build/serial_hello/serial_hello.ino.hex
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const hexPath = process.argv[2] ?? join(here, '..', 'build', 'serial_hello', 'serial_hello.ino.hex');

const raw = execFileSync(process.execPath, [join(here, 'run.mjs'), hexPath, '2200'], {
  encoding: 'utf8',
});
const { serial, serial_bytes: serialBytes } = JSON.parse(raw);
const lines = serial.replace(/\r\n/g, '\n').split('\n').filter(Boolean);

const failures = [];
if (serialBytes < 50) failures.push(`only ${serialBytes} serial bytes`);
if (!serial.includes('CircuitForge tick')) failures.push('missing expected serial text');
if (lines.length < 4) failures.push(`only ${lines.length} serial lines (want >= 4)`);

console.log(`serial bytes: ${serialBytes}`);
console.log(`lines: ${JSON.stringify(lines)}`);

if (failures.length) {
  console.error(`FAIL:\n  ${failures.join('\n  ')}`);
  process.exit(1);
}
console.log('PASS: UART output captured from firmware (Serial.print -> serial)');
