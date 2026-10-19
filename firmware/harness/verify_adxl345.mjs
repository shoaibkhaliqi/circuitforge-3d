// Reproducible check for the ADXL345 accelerometer: serve its register file (CF_DEVICES)
// with known sample values, run the sketch and assert the DEVID, the config read-back and
// the 6-byte axis burst all decode to the counts the spec implies at the scale the *sketch*
// selected (10-bit mode at +/-4 g = 128 LSB/g). Three runs:
//   * the configured sample (0.5 g, -0.25 g, 1 g),
//   * a positive control with different accelerations, to show the counts follow the spec,
//   * a negative control with no device attached: the bus reads 0xFF, so the sketch must
//     not see the served values (they came from the device, not from the sketch).
// Exit 0/1.
//
//   arduino-cli compile --fqbn arduino:avr:uno --output-dir build/adxl345_read \
//     sketches/adxl345_read
//   node verify_adxl345.mjs build/adxl345_read/adxl345_read.ino.hex
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const hexPath =
  process.argv[2] ?? join(here, '..', 'build', 'adxl345_read', 'adxl345_read.ino.hex');

const ADDR = 0x53;
const DEVID = 0xe5;
const LSB_PER_G = 128; // DATA_FORMAT 0x01 = 10-bit mode at +/-4 g
const AX = 0.5, AY = -0.25, AZ = 1.0;
const MG = (raw) => Math.trunc((raw * 1000) / LSB_PER_G);

const run = (specs, ms = 400) => {
  const env = { ...process.env };
  delete env.CF_DEVICES;
  if (specs) env.CF_DEVICES = JSON.stringify(specs);
  const raw = execFileSync(process.execPath, [join(here, 'run.mjs'), hexPath, String(ms)], {
    encoding: 'utf8',
    maxBuffer: 64 * 1024 * 1024,
    env,
  });
  return JSON.parse(raw);
};

const parse = (serial) => {
  const m = /devid 0x([0-9a-fA-F]+) fmt 0x([0-9a-fA-F]+) pwr 0x([0-9a-fA-F]+) ax (-?\d+) ay (-?\d+) az (-?\d+) mg (-?\d+) (-?\d+) (-?\d+)/
    .exec(String(serial ?? ''));
  return m
    ? {
        devid: parseInt(m[1], 16), fmt: parseInt(m[2], 16), pwr: parseInt(m[3], 16),
        ax: Number(m[4]), ay: Number(m[5]), az: Number(m[6]),
        mg: [Number(m[7]), Number(m[8]), Number(m[9])],
      }
    : null;
};

const failures = [];
const want = (label, got, expected) => {
  if (JSON.stringify(got) !== JSON.stringify(expected)) {
    failures.push(`${label}=${JSON.stringify(got)} (want ${JSON.stringify(expected)})`);
  }
};

// ---- the configured sample ---------------------------------------------------
const { serial = '', devices = [] } = run([{ kind: 'adxl345', address: ADDR, ax: AX, ay: AY, az: AZ }]);
const got = parse(serial);
const dev = devices[0] ?? {};

if (!got) failures.push(`Serial did not report a reading: ${JSON.stringify(serial)}`);
const rawCounts = [AX, AY, AZ].map((g) => Math.round(g * LSB_PER_G));
if (got) {
  want('devid', got.devid, DEVID);
  want('DATA_FORMAT read-back', got.fmt, 0x01);   // 10-bit mode, +/-4 g
  want('POWER_CTL read-back', got.pwr, 0x08);     // measure
  want('axis counts', [got.ax, got.ay, got.az], rawCounts);
  want('milli-g', got.mg, rawCounts.map(MG));
}

want('kind', dev.kind, 'adxl345');
want('address', dev.address, ADDR);
want('devid register', dev.devid, DEVID);
want('data_format', dev.data_format, 0x01);
want('full_res', dev.full_res, false);
want('range_g', dev.range_g, 4);
want('lsb_per_g', dev.lsb_per_g, LSB_PER_G);
want('accel_raw', dev.accel_raw, rawCounts);
want('accel_g', dev.accel_g, [AX, AY, AZ]);

// ---- positive control: the counts follow the spec, not a constant ------------
const ALT = [0.25, -1.0, 0.0];
const alt = parse(run([{ kind: 'adxl345', address: ADDR, ax: ALT[0], ay: ALT[1], az: ALT[2] }]).serial);
const altCounts = ALT.map((g) => Math.round(g * LSB_PER_G));
if (!alt) {
  failures.push('positive control: no reading');
} else {
  want('control counts', [alt.ax, alt.ay, alt.az], altCounts);
  want('control milli-g', alt.mg, altCounts.map(MG));
}

// ---- negative control: no device -> the bus reads 0xFF -----------------------
const blind = run(null);
const blindGot = parse(blind.serial);
if ((blind.devices ?? []).some((d) => d.kind === 'adxl345')) {
  failures.push('a device was served with no device attached');
}
if (!blindGot) {
  failures.push(`negative control: no reading: ${JSON.stringify(blind.serial)}`);
} else {
  want('negative-control devid', blindGot.devid, 0xff);
  if (blindGot.ax === rawCounts[0] && blindGot.mg[0] === MG(rawCounts[0])) {
    failures.push('negative control still read the served sample');
  }
}

console.log(`devid=0x${(got?.devid ?? 0).toString(16)} fmt=0x${(got?.fmt ?? 0).toString(16)} `
  + `raw=${JSON.stringify(rawCounts)} mg=${JSON.stringify(rawCounts.map(MG))} `
  + `lsb/g=${dev.lsb_per_g} (${dev.range_g} g, full_res=${dev.full_res})`);
console.log(`positive control: raw=${JSON.stringify(alt ? [alt.ax, alt.ay, alt.az] : null)}`);
console.log(`no-device control: serial=${JSON.stringify(String(blind.serial ?? '').trim())}`);
if (failures.length) {
  console.error(`FAIL:\n  ${failures.join('\n  ')}`);
  process.exit(1);
}
console.log('PASS: ADXL345 DEVID + config read-back + axis burst decode to the served counts '
  + `at the scale the sketch selected (${LSB_PER_G} LSB/g), and with no device the same `
  + 'firmware reads 0xFF - the counts come from the device, not the sketch');
