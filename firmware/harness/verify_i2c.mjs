// Reproducible check for the I2C (TWI) trace surface: runs the i2c sketch and
// asserts the transaction to 0x27 with data [0x00, 0x41] was recorded. Exit 0/1.
//
//   arduino-cli compile --fqbn arduino:avr:uno --output-dir build/i2c_write sketches/i2c_write
//   node verify_i2c.mjs build/i2c_write/i2c_write.ino.hex
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const hexPath = process.argv[2] ?? join(here, '..', 'build', 'i2c_write', 'i2c_write.ino.hex');

const raw = execFileSync(process.execPath, [join(here, 'run.mjs'), hexPath, '2200'], {
  encoding: 'utf8',
});
const { i2c } = JSON.parse(raw);

const failures = [];
if (i2c.length < 4) failures.push(`only ${i2c.length} I2C transactions (want >= 4)`);
for (const txn of i2c) {
  if (txn.address !== 0x27) failures.push(`unexpected address ${txn.address}`);
  if (txn.write !== true) failures.push('expected a write transaction');
  if (JSON.stringify(txn.bytes) !== JSON.stringify([0x00, 0x41])) {
    failures.push(`unexpected bytes ${JSON.stringify(txn.bytes)}`);
  }
}

console.log(`I2C transactions: ${i2c.length}`);
console.log(`first: ${JSON.stringify(i2c[0])}`);

if (failures.length) {
  console.error(`FAIL:\n  ${failures.join('\n  ')}`);
  process.exit(1);
}
console.log('PASS: I2C write to 0x27 (bytes 0x00,0x41) captured as a bus trace');
