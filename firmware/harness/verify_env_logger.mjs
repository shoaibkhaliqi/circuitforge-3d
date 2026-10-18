// Reproducible check for the capstone example: one sketch reads a DHT22 and reports
// through a 16x2 I2C LCD *and* serial, so two device families are exercised together.
// Exit 0/1.
//
//   arduino-cli compile --fqbn arduino:avr:uno --output-dir build/env_logger \
//     sketches/env_logger
//   node verify_env_logger.mjs build/env_logger/env_logger.ino.hex
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const hexPath = process.argv[2] ?? join(here, '..', 'build', 'env_logger', 'env_logger.ino.hex');

const LCD = { kind: 'lcd1602', address: 0x27, cols: 16, rows: 2 };
const CASES = [
  { dht: { kind: 'dht', pin: 2, model: 'dht22', temp_c: 23, humidity: 48 },
    line: 'T=23.0C H=48.0%', status: 'checksum ok' },
  { dht: { kind: 'dht', pin: 2, model: 'dht22', temp_c: -5.5, humidity: 99.9 },
    line: 'T=-5.5C H=99.9%', status: 'checksum ok' },
  { dht: { kind: 'dht', pin: 9, model: 'dht22', temp_c: 23, humidity: 48 }, error: true },
];

const failures = [];
for (const c of CASES) {
  const raw = execFileSync(process.execPath, [join(here, 'run.mjs'), hexPath, '300'], {
    encoding: 'utf8',
    env: { ...process.env, CF_DEVICES: JSON.stringify([c.dht, LCD]) },
  });
  const { serial = '', devices = [], pin_devices: pinDevices = [] } = JSON.parse(raw);
  const lcd = devices.find((d) => d.kind === 'lcd1602') ?? {};
  const dht = pinDevices[0] ?? {};
  const lines = (lcd.lines ?? []).map((s) => s.trim());
  const label = `pin=${c.dht.pin} ${c.dht.temp_c}C ${c.dht.humidity}%`;

  if (c.error) {
    const ok = lines[0] === 'sensor error' && /env error/.test(serial) && dht.reads === 0;
    if (!ok) failures.push(`${label}: expected a sensor error, got ${JSON.stringify(lines)} ${JSON.stringify(serial)}`);
    console.log(`${label} -> LCD "${lines[0]}", serial error, ${dht.reads} sensor reads`);
    continue;
  }

  if (lines[0] !== c.line) failures.push(`${label}: LCD line 1 ${JSON.stringify(lines[0])} (want ${JSON.stringify(c.line)})`);
  if (lines[1] !== c.status) failures.push(`${label}: LCD line 2 ${JSON.stringify(lines[1])} (want ${JSON.stringify(c.status)})`);
  if (!serial.includes(`env ${c.line}`)) failures.push(`${label}: serial missing the report: ${JSON.stringify(serial)}`);
  if (dht.reads !== 1) failures.push(`${label}: sensor reads=${dht.reads} (want 1)`);
  console.log(`${label} -> LCD "${lines[0]}" / "${lines[1]}", serial "${serial.trim()}"`);
}

if (failures.length) {
  console.error(`FAIL:\n  ${failures.join('\n  ')}`);
  process.exit(1);
}
console.log('PASS: DHT22 + I2C LCD driven by one sketch (LCD text and serial agree)');
