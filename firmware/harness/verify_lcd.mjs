// Reproducible check for the I2C HD44780 LCD: serve a 16x2 LCD behind a PCF8574
// backpack (CF_DEVICES), run lcd_hello and assert the decoded text. Exit 0/1.
//
//   arduino-cli compile --fqbn arduino:avr:uno --output-dir build/lcd_hello \
//     sketches/lcd_hello
//   node verify_lcd.mjs build/lcd_hello/lcd_hello.ino.hex
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const hexPath = process.argv[2] ?? join(here, '..', 'build', 'lcd_hello', 'lcd_hello.ino.hex');

const raw = execFileSync(process.execPath, [join(here, 'run.mjs'), hexPath, '800'], {
  encoding: 'utf8',
  env: { ...process.env, CF_DEVICES: '[{"kind":"lcd1602","address":39,"cols":16,"rows":2}]' },
});
const { devices } = JSON.parse(raw);
const dev = (devices && devices[0]) || {};
const lines = dev.lines || [];
const line0 = (lines[0] || '').trimEnd();
const line1 = (lines[1] || '').trimEnd();

const failures = [];
if (dev.kind !== 'lcd1602') failures.push(`kind=${dev.kind} (want lcd1602)`);
if (line0 !== 'CircuitForge') failures.push(`line0 "${line0}" (want "CircuitForge")`);
if (line1 !== '3D') failures.push(`line1 "${line1}" (want "3D")`);

console.log(`line0="${line0}" line1="${line1}"`);
if (failures.length) {
  console.error(`FAIL:\n  ${failures.join('\n  ')}`);
  process.exit(1);
}
console.log('PASS: LCD shows "CircuitForge" / "3D" decoded from the I2C backpack');
