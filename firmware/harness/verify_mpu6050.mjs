// Reproducible check for the MPU-6050 IMU: serve a register file (CF_DEVICES) whose
// sample values are known, run the sketch and assert the WHO_AM_I byte plus the
// 14-byte accel/temp/gyro burst decode to the expected raw counts. Exit 0/1.
//
//   arduino-cli compile --fqbn arduino:avr:uno --output-dir build/mpu6050_read \
//     sketches/mpu6050_read
//   node verify_mpu6050.mjs build/mpu6050_read/mpu6050_read.ino.hex
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const hexPath =
  process.argv[2] ?? join(here, '..', 'build', 'mpu6050_read', 'mpu6050_read.ino.hex');

// AFS_SEL=0 -> 16384 LSB/g, FS_SEL=0 -> 131 LSB/(deg/s), temp -> 340 LSB/degC.
const AX = 0.5, AY = -0.25, AZ = 1.0;      // g
const GX = 10, GY = -20, GZ = 250;         // deg/s
const TEMP = 26.53;                        // degC (chosen so the raw count is exact)
const WHO = 0x68;

const want = {
  who: WHO,
  ax: Math.round(AX * 16384),
  ay: Math.round(AY * 16384),
  az: Math.round(AZ * 16384),
  gx: Math.round(GX * 131),
  gy: Math.round(GY * 131),
  gz: Math.round(GZ * 131),
  temp: Math.round((TEMP - 36.53) * 340) * 100 / 340 + 3653,
};

const raw = execFileSync(process.execPath, [join(here, 'run.mjs'), hexPath, '400'], {
  encoding: 'utf8',
  env: {
    ...process.env,
    CF_DEVICES: JSON.stringify([{
      kind: 'mpu6050', address: 0x68,
      ax: AX, ay: AY, az: AZ, gx: GX, gy: GY, gz: GZ, temp_c: TEMP,
    }]),
  },
});
const { serial = '', devices = [] } = JSON.parse(raw);

const m = /who 0x([0-9a-fA-F]+) ax (-?\d+) ay (-?\d+) az (-?\d+) gx (-?\d+) gy (-?\d+) gz (-?\d+) temp (-?\d+)/
  .exec(serial);
const got = m
  ? {
      who: parseInt(m[1], 16), ax: Number(m[2]), ay: Number(m[3]), az: Number(m[4]),
      gx: Number(m[5]), gy: Number(m[6]), gz: Number(m[7]), temp: Number(m[8]),
    }
  : null;
const dev = devices[0] ?? {};

const failures = [];
if (!got) failures.push(`Serial did not report a reading: ${JSON.stringify(serial)}`);
if (got) {
  for (const k of Object.keys(want)) {
    if (got[k] !== want[k]) failures.push(`${k}: got ${got[k]} (want ${want[k]})`);
  }
}
if (dev.kind !== 'mpu6050') failures.push(`device kind=${dev.kind} (want mpu6050)`);
if (dev.accel_raw && JSON.stringify(dev.accel_raw) !== JSON.stringify([want.ax, want.ay, want.az])) {
  failures.push(`accel_raw=${JSON.stringify(dev.accel_raw)}`);
}

console.log(got ? `who=0x${got.who.toString(16)} az=${got.az} gz=${got.gz} temp=${got.temp}` : serial);
if (failures.length) {
  console.error(`FAIL:\n  ${failures.join('\n  ')}`);
  process.exit(1);
}
console.log('PASS: MPU-6050 WHO_AM_I + accel/temp/gyro burst decode to the served values');
