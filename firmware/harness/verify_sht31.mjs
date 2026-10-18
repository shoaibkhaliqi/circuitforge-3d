// Reproducible check for the SHT31 driver: serve the sensor on I2C (CF_DEVICES) and
// assert the sketch's hand-written driver decodes the frame and validates both CRC-8s.
// Exit 0/1.
//
//   arduino-cli compile --fqbn arduino:avr:uno --output-dir build/sht31_read \
//     sketches/sht31_read
//   node verify_sht31.mjs build/sht31_read/sht31_read.ino.hex
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const hexPath = process.argv[2] ?? join(here, '..', 'build', 'sht31_read', 'sht31_read.ino.hex');

// The harness CRC must be the part's own: the datasheet's worked example (0xBE 0xEF -> 0x92).
const crc8 = (a, b) => {
  let crc = 0xff;
  for (const byte of [a, b]) {
    crc ^= byte & 0xff;
    for (let i = 0; i < 8; i++) crc = crc & 0x80 ? ((crc << 1) ^ 0x31) & 0xff : (crc << 1) & 0xff;
  }
  return crc;
};

const CASES = [
  { spec: { kind: 'sht31', address: 68, temp_c: 23, humidity: 48 },
    temp: '23.0', hum: '48.0', raw: [25465, 31457] },
  { spec: { kind: 'sht31', address: 68, temp_c: -5.5, humidity: 99.9 },
    temp: '-5.5', hum: '99.9', raw: [14792, 65469] },
  { spec: { kind: 'sht31', address: 68, temp_c: 23, humidity: 48, corrupt_crc: 1 },
    crcError: true },
  { spec: { kind: 'sht31', address: 69, temp_c: 23, humidity: 48 }, noDevice: true },
];

const failures = [];
if (crc8(0xbe, 0xef) !== 0x92) failures.push('CRC-8 does not match the SHT31 datasheet vector');

for (const c of CASES) {
  const raw = execFileSync(process.execPath, [join(here, 'run.mjs'), hexPath, '300'], {
    encoding: 'utf8',
    env: { ...process.env, CF_DEVICES: JSON.stringify([c.spec]) },
  });
  const { serial = '', devices = [] } = JSON.parse(raw);
  const dev = devices[0] ?? {};
  const label = `address=${c.spec.address} ${c.spec.temp_c}C ${c.spec.humidity}%` +
    (c.spec.corrupt_crc ? ' (corrupt CRC)' : '') + (c.noDevice ? ' (nothing at that address)' : '');

  const m = /sht31 t (-?\d+\.\d) h (\d+\.\d) ok (\d)/.exec(serial);
  if (c.crcError || c.noDevice) {
    const ok = /sht31 crc error/.test(serial) &&
      (c.noDevice ? dev.reads === 0 : dev.crc_ok === false);
    if (!ok) failures.push(`${label}: expected a checksum failure, got ${JSON.stringify(serial)} crc_ok=${dev.crc_ok} reads=${dev.reads}`);
    console.log(`${label} -> sht31 crc error (caught by the driver's checksum)`);
    continue;
  }
  if (!m) { failures.push(`${label}: no reading in ${JSON.stringify(serial)}`); continue; }
  if (m[1] !== c.temp) failures.push(`${label}: temp ${m[1]} (want ${c.temp})`);
  if (m[2] !== c.hum) failures.push(`${label}: humidity ${m[2]} (want ${c.hum})`);
  if (m[3] !== '1') failures.push(`${label}: driver reported a checksum failure`);
  if (dev.temp_raw !== c.raw[0] || dev.humidity_raw !== c.raw[1]) {
    failures.push(`${label}: raw ${dev.temp_raw}/${dev.humidity_raw} (want ${c.raw.join('/')})`);
  }
  if (dev.command !== 0x2400) failures.push(`${label}: command 0x${dev.command.toString(16)} (want 0x2400)`);
  console.log(`${label} -> t ${m[1]}, h ${m[2]}, raw ${dev.temp_raw}/${dev.humidity_raw}, crc ok`);
}

if (failures.length) {
  console.error(`FAIL:\n  ${failures.join('\n  ')}`);
  process.exit(1);
}
console.log('PASS: SHT31 commands, 16-bit values and both CRC-8s read back exactly');
