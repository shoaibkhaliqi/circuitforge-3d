// Reproducible check for the MCP3008 SPI ADC: serve the part on the AVR's SPI peripheral
// (CF_DEVICES), run the spi_adc sketch and assert the 10-bit codes it reads back are the
// ones the spec implies - i.e. the harness really *answers* on MISO (the first SPI
// device -> firmware read path). Three runs:
//   * the configured channels (3.3 V, 1.25 V, 0 V, 5 V over vref 5 V),
//   * a full-scale control (all 5 V) to show the codes follow the spec, not a constant,
//   * a negative control with no device attached: the bus idles at 0x00, so the sketch
//     must read zeros - proving the codes came from the device model.
// Exit 0/1.
//
//   arduino-cli compile --fqbn arduino:avr:uno --output-dir build/spi_adc sketches/spi_adc
//   node verify_spi_adc.mjs build/spi_adc/spi_adc.ino.hex
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const hexPath = process.argv[2] ?? join(here, '..', 'build', 'spi_adc', 'spi_adc.ino.hex');

const CS_PIN = 10;
const VREF = 5;
const AIN = [3.3, 1.25, 0, 5, 0, 0, 0, 0];
const CHANNELS = [0, 1, 2, 3];
// What the sketch asked for: three transfers per conversion, channel in bits 6..4 of the
// second byte, twice over (it reads every channel twice).
const EXPECTED_TRACE = [0x01, 0x80, 0x00, 0x01, 0x90, 0x00, 0x01, 0xa0, 0x00, 0x01, 0xb0, 0x00];

const run = (specs, ms = 900) => {
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

const codeFor = (volts) => Math.max(0, Math.min(1023,
  Math.round((Math.max(0, Math.min(VREF, volts)) / VREF) * 1023)));

const failures = [];
const want = (label, got, expected) => {
  if (got !== expected) failures.push(`${label}=${JSON.stringify(got)} (want ${JSON.stringify(expected)})`);
};

// ---- the configured channels -------------------------------------------------
const { serial = '', devices = [], spi_bytes: spiBytes = [], spi_byte_count: spiCount = 0 } =
  run([{ kind: 'mcp3008', cs: CS_PIN, vref: VREF, ain: AIN }]);
const dev = devices[0] ?? {};

want('kind', dev.kind, 'mcp3008');
want('cs_pin', dev.cs_pin, CS_PIN);
want('vref', dev.vref, VREF);
want('ain', JSON.stringify(dev.ain), JSON.stringify(AIN));
want('conversions', dev.conversions, CHANNELS.length * 2);
want('differential_requests', dev.differential_requests, 0);
want('bytes', dev.bytes, EXPECTED_TRACE.length * 2);
want('deselected', dev.deselected, 0); // every transfer is inside a CS-low window
want('spi_byte_count', spiCount, EXPECTED_TRACE.length * 2);
want('spi trace', JSON.stringify(spiBytes), JSON.stringify(EXPECTED_TRACE.concat(EXPECTED_TRACE)));

const reads = dev.reads ?? [];
want('reads recorded', reads.length, CHANNELS.length * 2);
const expectedCodes = CHANNELS.map((ch) => codeFor(AIN[ch]));
want('codes', JSON.stringify(reads.map((r) => r.code)),
  JSON.stringify(expectedCodes.concat(expectedCodes)));
want('channels', JSON.stringify(reads.map((r) => r.channel)),
  JSON.stringify(CHANNELS.concat(CHANNELS)));
for (let i = 0; i < reads.length; i++) {
  const r = reads[i];
  const want_v = Math.round((expectedCodes[i % CHANNELS.length] / 1023) * VREF * 1e6) / 1e6;
  if (r.volts !== want_v) failures.push(`read[${i}].volts=${r.volts} (want ${want_v})`);
}
// The sketch's own report must agree: "ch0 675 675" etc.
for (let i = 0; i < CHANNELS.length; i++) {
  const line = `ch${CHANNELS[i]} ${expectedCodes[i]} ${expectedCodes[i]}`;
  if (!serial.includes(line)) failures.push(`serial missing ${JSON.stringify(line)}: ${JSON.stringify(serial)}`);
}

// ---- positive control: codes follow the spec, not a constant ------------------
const full = run([{ kind: 'mcp3008', cs: CS_PIN, vref: VREF, ain: [VREF, VREF, VREF, VREF] }]);
const fullDev = full.devices[0] ?? {};
want('full-scale codes', JSON.stringify((fullDev.reads ?? []).map((r) => r.code)),
  JSON.stringify(Array(8).fill(1023)));
if (!String(full.serial ?? '').includes('ch0 1023 1023')) {
  failures.push(`full-scale serial did not report 1023: ${JSON.stringify(full.serial)}`);
}

// ---- negative control: no device on the bus -> MISO idles low ----------------
const blind = run(null);
if ((blind.devices ?? []).some((d) => d.kind === 'mcp3008')) {
  failures.push('a device was served with no device attached');
}
if (!/ch0 0 0/.test(String(blind.serial ?? ''))) {
  failures.push(`with no device the sketch did not read zeros: ${JSON.stringify(blind.serial)}`);
}

console.log(`conversions=${dev.conversions} codes=${JSON.stringify(expectedCodes)} `
  + `bytes=${dev.bytes} serial=${JSON.stringify(serial.trim())}`);
console.log(`full-scale control: codes=${JSON.stringify((fullDev.reads ?? []).map((r) => r.code).slice(0, 4))}`);
console.log(`no-device control: serial=${JSON.stringify(String(blind.serial ?? '').trim())}`);
if (failures.length) {
  console.error(`FAIL:\n  ${failures.join('\n  ')}`);
  process.exit(1);
}
console.log('PASS: MCP3008 answered on MISO with the spec\'s 10-bit codes '
  + '(3.3 V/1.25 V/0 V/5 V over vref 5 V), and with no device attached the same firmware '
  + 'reads zeros - the codes come from the device, not the sketch');
