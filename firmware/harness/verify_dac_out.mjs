// Reproducible check for the MCP4725 12-bit I2C DAC: serve the part (CF_DEVICES), run the
// sketch and assert the codes it wrote are the ones the device decoded - including the
// voltage each code produces at the reference, the EEPROM write count and the fact that a
// command byte the model does not implement (a fast-mode-style first byte) is counted but
// changes nothing. Four runs:
//   * the configured part (0x60, 5 V reference),
//   * the same firmware with a 3.3 V reference, to show `volts` follows `vref`,
//   * the same firmware with the device served at another address (0x61), so nothing is
//     decoded - the codes came from the addressed transaction, not from the sketch,
//   * no device at all (the bus still records the writes, but there is no decoded code).
// Exit 0/1.
//
//   arduino-cli compile --fqbn arduino:avr:uno --output-dir build/dac_out sketches/dac_out
//   node verify_dac_out.mjs build/dac_out/dac_out.ino.hex
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const hexPath = process.argv[2] ?? join(here, '..', 'build', 'dac_out', 'dac_out.ino.hex');

const ADDR = 0x60;
// The sketch assumes a 5 V (VDD) reference, so it prints milli-volts for that; the 3.3 V
// control below therefore checks the device's decoded `volts`, not the printed line.
const VREF = 5.0;
const STEPS = 4096;

// [code, power-down] in the order the sketch writes them.
const WRITES = [[2048, 0], [819, 0], [4095, 0], [1234, 0], [0, 1], [3300, 0]];
const MV = (code) => Math.trunc((code * 5000) / 4096);
const VOLTS = (code, vref) => Math.round((code / STEPS) * vref * 1e6) / 1e6;

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
  const re = /dac (\d+) (-?\d+) (\d)/g;
  let m;
  while ((m = re.exec(String(serial ?? ''))) !== null) {
    out.push({ code: Number(m[1]), mv: Number(m[2]), pd: Number(m[3]) });
  }
  return out;
};

const failures = [];
const want = (label, got, expected) => {
  if (JSON.stringify(got) !== JSON.stringify(expected)) {
    failures.push(`${label}=${JSON.stringify(got)} (want ${JSON.stringify(expected)})`);
  }
};

// ---- the configured part -----------------------------------------------------
const { serial = '', devices = [], i2c = [] } = run([{ kind: 'mcp4725', address: ADDR, vref: VREF }]);
const lines = parseLines(serial);
const dev = devices[0] ?? {};

want('line count', lines.length, WRITES.length);
want('codes', lines.map((l) => l.code), WRITES.map((w) => w[0]));
want('milli-volts', lines.map((l) => l.mv), WRITES.map((w) => MV(w[0])));
want('power-down bits', lines.map((l) => l.pd), WRITES.map((w) => w[1]));
want('fast-mode note', /fastmode/.test(String(serial)), true);
want('kind', dev.kind, 'mcp4725');
want('address', dev.address, ADDR);
want('decoded writes', dev.writes, WRITES.length);
want('EEPROM writes', dev.eeprom_writes, 1);
want('unrecognised writes', dev.unrecognised, 1);
want('final code', dev.code, 3300);
want('final power-down', dev.power_down, 0);
want('vref', dev.vref, VREF);
want('decoded volts', dev.volts, VOLTS(3300, VREF));
// The raw bus trace is still the bus trace: seven write transactions, the last one the
// fast-mode byte the model refuses to decode.
want('bus write count', i2c.filter((t) => t.write && t.address === ADDR).length, WRITES.length + 1);
want('last bus bytes', i2c[i2c.length - 1].bytes, [0x0f, 0x00]);

// ---- reference control: only the device's decoded volts change ---------------
const ref = run([{ kind: 'mcp4725', address: ADDR, vref: 3.3 }]);
want('3.3 V volts', (ref.devices[0] ?? {}).volts, VOLTS(3300, 3.3));
want('3.3 V printed line still assumes 5 V', parseLines(ref.serial)[5].mv, MV(3300));

// ---- wrong-address control: nothing is decoded -------------------------------
const other = run([{ kind: 'mcp4725', address: ADDR + 1, vref: VREF }]);
const otherDev = other.devices[0] ?? {};
want('wrong-address writes', otherDev.writes, 0);
want('wrong-address code', otherDev.code, 0);
want('wrong-address volts', otherDev.volts, 0);
if (otherDev.unrecognised) failures.push('wrong-address device saw an unrecognised write');

// ---- no device at all --------------------------------------------------------
const blind = run(null);
if ((blind.devices ?? []).length) failures.push('a device was served with no device attached');
want('no-device bus trace still recorded', (blind.i2c ?? []).length, WRITES.length + 1);

console.log(`codes=${JSON.stringify(lines.map((l) => l.code))} `
  + `mV=${JSON.stringify(lines.map((l) => l.mv))} `
  + `pd=${JSON.stringify(lines.map((l) => l.pd))}`);
console.log(`device: writes=${dev.writes} eeprom=${dev.eeprom_writes} `
  + `unrecognised=${dev.unrecognised} code=${dev.code} pd=${dev.power_down} `
  + `volts=${dev.volts} (vref ${dev.vref} V)`);
console.log(`3.3 V control: volts=${ref.devices?.[0]?.volts}  `
  + `wrong address: writes=${otherDev.writes} code=${otherDev.code}`);
if (failures.length) {
  console.error(`FAIL:\n  ${failures.join('\n  ')}`);
  process.exit(1);
}
console.log('PASS: the MCP4725 decoded every general write command (code, power-down and EEPROM '
  + 'bits), its volts follow the reference, and the fast-mode byte it does not implement is '
  + 'counted without changing the code - the codes come from the addressed device, not the sketch');
