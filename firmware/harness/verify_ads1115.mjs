// Reproducible check for the ADS1115 16-bit I2C ADC: serve its register file (CF_DEVICES)
// with known channel voltages and assert the codes the sketch reads back are the ones the
// spec implies *at the settings the sketch itself wrote* - single-ended at +/-4.096 V, the
// A0/A1 differential pair, and one finer gain (+/-1.024 V) - i.e. the I2C twin of the SPI
// MCP3008 read path. Three runs:
//   * the configured channels (2.5 V, 1 V, 0 V, 3.3 V on A0..A3),
//   * a positive control including a negative full-scale reading, to show the codes follow
//     the spec and the gain rather than a constant,
//   * a negative control with no device attached: the bus reads 0xFF, so the sketch must
//     not see the served codes (they came from the device, not from the sketch).
// Exit 0/1.
//
//   arduino-cli compile --fqbn arduino:avr:uno --output-dir build/ads1115_read \
//     sketches/ads1115_read
//   node verify_ads1115.mjs build/ads1115_read/ads1115_read.ino.hex
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const hexPath =
  process.argv[2] ?? join(here, '..', 'build', 'ads1115_read', 'ads1115_read.ino.hex');

const ADDR = 0x48;
const AIN = [2.5, 1.0, 0.0, 3.3];
const FS = 4096;    // mV, the +/-4.096 V the sketch selects for five of six conversions
const FS_FINE = 1024;

// tag -> [mux, pga, full-scale mV] as the sketch writes them.
const STEPS = [
  ['a0', 4, 1, FS],       // A0 against GND
  ['a1', 5, 1, FS],       // A1 against GND
  ['a2', 6, 1, FS],       // A2 against GND
  ['a3', 7, 1, FS],       // A3 against GND
  ['d01', 0, 1, FS],      // A0 - A1, the differential pair
  ['a1g', 5, 3, FS_FINE], // A1 again at +/-1.024 V
];

// volts for a step -> the measured voltage -> the code and milli-volts it should produce.
const voltsFor = (ain, [tag, mux, , fsMv]) => {
  if (tag === 'd01') return ain[0] - ain[1];
  return ain[(mux - 4) % 4];
};
const wantFor = (ain) => STEPS.map(([tag, mux, pga, fsMv]) => {
  const v = voltsFor(ain, [tag, mux, pga, fsMv]);
  const fsV = fsMv / 1000;
  const code = Math.max(-32768, Math.min(32767, Math.round((v / fsV) * 32768)));
  return { tag, mux, pga, fsMv, code, mv: Math.trunc((code * fsMv) / 32768) };
});

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

const parseLines = (serial) => {
  const out = [];
  const re = /(\w+) (-?\d+) (-?\d+)/g;
  let m;
  while ((m = re.exec(String(serial ?? ''))) !== null) {
    out.push({ tag: m[1], code: Number(m[2]), mv: Number(m[3]) });
  }
  return out;
};

const failures = [];
const want = (label, got, expected) => {
  if (JSON.stringify(got) !== JSON.stringify(expected)) {
    failures.push(`${label}=${JSON.stringify(got)} (want ${JSON.stringify(expected)})`);
  }
};

// ---- the configured channels -------------------------------------------------
const { serial = '', devices = [] } = run([{ kind: 'ads1115', address: ADDR, ain: AIN }]);
const want0 = wantFor(AIN);
const lines = parseLines(serial);
const dev = devices[0] ?? {};

want('line count', lines.length, STEPS.length);
want('tags', lines.map((l) => l.tag), STEPS.map((s) => s[0]));
want('codes', lines.map((l) => l.code), want0.map((s) => s.code));
want('milli-volts', lines.map((l) => l.mv), want0.map((s) => s.mv));

want('kind', dev.kind, 'ads1115');
want('address', dev.address, ADDR);
want('ain', dev.ain, AIN);
want('conversions', dev.conversions, STEPS.length);
// The last conversion the sketch asked for: A1 against GND at +/-1.024 V.
want('final config', dev.config, 0xd783);
want('final mux', [dev.mux, dev.mux_mode], [5, 'single-ended']);
want('final pga', [dev.pga, dev.full_scale_v], [3, 1.024]);
const reads = dev.reads ?? [];
want('reads', reads.map((r) => [r.mux, r.pga, r.full_scale_v, r.code]),
  want0.map((s) => [s.mux, s.pga, s.fsMv / 1000, s.code]));
want('read volts', reads.map((r) => r.volts),
  want0.map((s) => Math.round((s.code / 32768) * (s.fsMv / 1000) * 1e6) / 1e6));

// ---- positive control: a different stimulus, including negative full scale ----
const ALT = [1.024, -1.024, 2.048, 0];
const altWant = wantFor(ALT);
const altLines = parseLines(run([{ kind: 'ads1115', address: ADDR, ain: ALT }]).serial);
want('control codes', altLines.map((l) => l.code), altWant.map((s) => s.code));
want('control milli-volts', altLines.map((l) => l.mv), altWant.map((s) => s.mv));
if (altWant.find((s) => s.tag === 'a1g').code !== -32768) {
  failures.push('positive control does not reach negative full scale');
}

// ---- negative control: no device -> the bus reads 0xFF -----------------------
const blind = run(null);
const blindLines = parseLines(blind.serial);
if ((blind.devices ?? []).some((d) => d.kind === 'ads1115')) {
  failures.push('a device was served with no device attached');
}
want('negative-control line count', blindLines.length, STEPS.length);
want('negative-control codes', blindLines.map((l) => l.code), Array(STEPS.length).fill(-1));
if (blindLines[0]?.code === want0[0].code) {
  failures.push('negative control still read the served conversion');
}

console.log(`codes=${JSON.stringify(lines.map((l) => l.code))} `
  + `mV=${JSON.stringify(lines.map((l) => l.mv))} `
  + `last config=0x${(dev.config ?? 0).toString(16)} (mux ${dev.mux}, pga ${dev.pga}, `
  + `${dev.full_scale_v} V full scale)`);
console.log(`positive control: codes=${JSON.stringify(altLines.map((l) => l.code))}`);
console.log(`no-device control: serial=${JSON.stringify(String(blind.serial ?? '').trim())}`);
if (failures.length) {
  console.error(`FAIL:\n  ${failures.join('\n  ')}`);
  process.exit(1);
}
console.log('PASS: ADS1115 conversions decode to the served channel voltages at the MUX/PGA '
  + 'the sketch wrote (single-ended, the A0/A1 differential pair, and two gains), and with '
  + 'no device the same firmware reads 0xFF - the codes come from the device, not the sketch');
