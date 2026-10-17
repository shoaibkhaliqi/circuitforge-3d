// Reproducible check for the EEPROM round-trip: serve a 24LC256 on the I2C bus
// (CF_DEVICES), run the eeprom_roundtrip sketch (store 0xA5, read it back) and
// assert the value survives. Exit 0/1.
//
//   arduino-cli compile --fqbn arduino:avr:uno --output-dir build/eeprom_roundtrip \
//     sketches/eeprom_roundtrip
//   node verify_eeprom.mjs build/eeprom_roundtrip/eeprom_roundtrip.ino.hex
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const hexPath = process.argv[2] ?? join(here, '..', 'build', 'eeprom_roundtrip', 'eeprom_roundtrip.ino.hex');

const raw = execFileSync(process.execPath, [join(here, 'run.mjs'), hexPath, '600'], {
  encoding: 'utf8',
  env: { ...process.env, CF_DEVICES: '[{"kind":"eeprom","address":80,"size":256,"init":[]}]' },
});
const { serial, devices, i2c } = JSON.parse(raw);

const failures = [];
if (serial.trim() !== 'eeprom 165') failures.push(`serial "${serial.trim()}" (want "eeprom 165")`);
const mem = devices && devices[0] && devices[0].mem;
if (!mem || mem[0] !== 0xa5) failures.push(`mem[0]=${mem && mem[0]} (want 165)`);
if (!Array.isArray(i2c) || i2c.length < 2) failures.push(`i2c transactions ${i2c && i2c.length} (want >=2)`);

console.log(`serial="${serial.trim()}" mem0=${mem && mem[0]} i2c=${i2c && i2c.length}`);
if (failures.length) {
  console.error(`FAIL:\n  ${failures.join('\n  ')}`);
  process.exit(1);
}
console.log('PASS: 24LC256 stored 0xA5 and read back 165 on the I2C bus');
