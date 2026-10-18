// Reproducible check for the DHT11/DHT22 driver: serve a sensor on the data pin
// (CF_DEVICES) and assert the sketch's bit-banged read decodes at datasheet timings.
// Exit 0/1.
//
//   arduino-cli compile --fqbn arduino:avr:uno --output-dir build/dht_read \
//     sketches/dht_read
//   node verify_dht.mjs build/dht_read/dht_read.ino.hex
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const hexPath = process.argv[2] ?? join(here, '..', 'build', 'dht_read', 'dht_read.ino.hex');

const CASES = [
  { spec: { kind: 'dht', pin: 2, model: 'dht22', temp_c: 23, humidity: 48 },
    raw: '01 E0 00 E6 C7', temp: '23.0', hum: '48.0' },
  { spec: { kind: 'dht', pin: 2, model: 'dht22', temp_c: -5.5, humidity: 99.9 },
    raw: '03 E7 80 37 A1', temp: '-5.5', hum: '99.9' }, // sign bit + 16-bit humidity
  { spec: { kind: 'dht', pin: 2, model: 'dht11', temp_c: 21, humidity: 55 },
    raw: '37 00 15 00 4C' }, // DHT11 framing: int humidity/temp + checksum
  { spec: { kind: 'dht', pin: 9, model: 'dht22', temp_c: 23, humidity: 48 }, error: true },
];

const failures = [];
for (const c of CASES) {
  const raw = execFileSync(process.execPath, [join(here, 'run.mjs'), hexPath, '200'], {
    encoding: 'utf8',
    env: { ...process.env, CF_DEVICES: JSON.stringify([c.spec]) },
  });
  const { serial = '', pin_devices: pinDevices = [] } = JSON.parse(raw);
  const dev = pinDevices[0] ?? {};
  const label = `pin=${c.spec.pin} ${c.spec.model} ${c.spec.temp_c}C ${c.spec.humidity}%`;

  if (c.error) {
    const ok = /dht error/.test(serial) && dev.reads === 0;
    if (!ok) failures.push(`${label}: expected a timeout, got ${JSON.stringify(serial)} reads=${dev.reads}`);
    console.log(`${label} -> dht error (nothing on that pin)`);
    continue;
  }

  const m = /raw ([0-9A-F ]+) ok (\d)/.exec(serial);
  const t = /t (-?\d+\.\d)/.exec(serial);
  const h = /h (\d+\.\d)/.exec(serial);
  if (!m) { failures.push(`${label}: no raw frame in ${JSON.stringify(serial)}`); continue; }
  if (m[1].trim() !== c.raw) failures.push(`${label}: raw ${m[1].trim()} (want ${c.raw})`);
  if (m[2] !== '1') failures.push(`${label}: checksum failed`);
  if (c.temp && (!t || t[1] !== c.temp)) failures.push(`${label}: temp ${t && t[1]} (want ${c.temp})`);
  if (c.hum && (!h || h[1] !== c.hum)) failures.push(`${label}: humidity ${h && h[1]} (want ${c.hum})`);
  console.log(`${label} -> raw ${m[1].trim()} ok ${m[2]}, t ${t && t[1]}, h ${h && h[1]}`);
}

if (failures.length) {
  console.error(`FAIL:\n  ${failures.join('\n  ')}`);
  process.exit(1);
}
console.log('PASS: DHT22 (incl. sign bit) and DHT11 frames read correctly, timeouts handled');
