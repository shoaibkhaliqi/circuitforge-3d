// Reproducible check for the DS18B20 driver: serve the harness's 1-Wire *slave* (CF_DEVICES)
// and assert that the sketch's hand-written 1-Wire master decodes at datasheet timings - the
// reset/presence pulse, READ ROM (0x33) with its CRC-8, MATCH ROM (0x55) against a ROM that is
// not the part's (silence) and against the ROM just read (an answer), two CONVERT T (0x44)
// cycles, READ SCRATCHPAD (0xBE) at the power-on 12-bit resolution, WRITE SCRATCHPAD (0x4E)
// with a 10-bit config and the quantised read-back, and COPY/RECALL E2.
//
// Everything the sketch prints is recomputed here from the spec the harness was given (ROM,
// raw 12/10-bit counts, milli-degrees, TH/TL/config, the Dallas CRC-8), and the device side is
// cross-checked too (the served ROM, the scratchpad it put on the wire, the command sequence,
// the reset/presence counts). Controls: a second temperature (the values must follow the
// spec), a *pull-up only* bus (no part answers: the driver sees no presence and every CRC
// fails), and the part served on a pin the firmware does not use (its counters stay at zero,
// so the decoded data cannot have come from anywhere but the firmware's own pin). Exit 0/1.
//
//   arduino-cli compile --fqbn arduino:avr:uno --output-dir build/ds18b20_read \
//     sketches/ds18b20_read
//   node verify_ds18b20.mjs build/ds18b20_read/ds18b20_read.ino.hex
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const hexPath = process.argv[2] ?? join(here, '..', 'build', 'ds18b20_read', 'ds18b20_read.ino.hex');

// The ROM the model serves (family 0x28 + a fixed serial) and the CRC-8 its 8th byte must be.
const ROM_BODY = [0x28, 0x8a, 0x1b, 0x2c, 0x3d, 0x4e, 0x5f];
const WRONG_ROM = [0x28, 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x00];
const FIRMWARE_PIN = 2;

// Dallas/Maxim CRC-8 (reflected polynomial 0x8C, init 0) - the checksum 1-Wire uses. This is
// the verifier's own implementation; the sketch computes the same one in C, and the harness in
// JavaScript, so three independent decodings have to agree.
function crc8(bytes) {
  let crc = 0;
  for (const byte of bytes) {
    let inByte = byte & 0xff;
    for (let i = 0; i < 8; i++) {
      const mix = (crc ^ inByte) & 0x01;
      crc = (crc >> 1) & 0xff;
      if (mix) crc ^= 0x8c;
      inByte >>= 1;
    }
  }
  return crc;
}

const ROM = [...ROM_BODY, crc8(ROM_BODY)];
const hex = (b) => (b & 0xff).toString(16).padStart(2, '0');
const hexUpper = (b) => (b & 0xff).toString(16).toUpperCase().padStart(2, '0');

// The 9-byte scratchpad the part must serve for a temperature at `config`'s resolution, and
// the signed raw count + milli-degrees a driver decodes from it.
function payload(tempC, alarmHigh, alarmLow, config) {
  const resolution = 9 + ((config >> 5) & 0x03);
  let raw = Math.round(tempC / 0.0625) & 0xffff;
  const dropped = 12 - resolution;
  if (dropped > 0) raw = (raw & ~((1 << dropped) - 1)) & 0xffff;
  const body = [
    raw & 0xff, (raw >> 8) & 0xff, alarmHigh & 0xff, alarmLow & 0xff, config & 0xff,
    0xff, 0xff, 0xff,
  ];
  const signed = raw > 0x7fff ? raw - 0x10000 : raw;
  return {
    bytes: [...body, crc8(body)],
    raw: signed,
    milliC: Math.trunc((signed * 125) / 2),
    resolution,
  };
}

const DEFAULT_CONFIG = 0x7f; // power-on 12-bit resolution
const WRITTEN_CONFIG = 0x3f; // TH/TL/config the sketch writes: 10-bit resolution

function run(spec, ms) {
  const raw = execFileSync(process.execPath, [join(here, 'run.mjs'), hexPath, String(ms)], {
    encoding: 'utf8',
    env: { ...process.env, CF_DEVICES: JSON.stringify([spec]) },
  });
  return JSON.parse(raw);
}

const failures = [];
const check = (ok, label) => { if (!ok) failures.push(label); };

// The sketch's command sequence after the two ROM reads: a conversion + scratchpad read twice,
// a third scratchpad read, a config write + read-back, then COPY and RECALL.
function expectedCommands() {
  return [
    0x33,
    0x55, ...WRONG_ROM,
    0x55, ...ROM,
    0xbe,
    0xcc, 0x44, 0xcc, 0xbe,
    0xcc, 0x44, 0xcc, 0xbe,
    0xcc, 0xbe,
    0xcc, 0x4e, 0x4b, 0x46, WRITTEN_CONFIG, 0xcc, 0xbe,
    0xcc, 0x48,
    0xcc, 0xb8,
  ];
}

function expectedSerial(tempC, { present = 1, romOK = true } = {}) {
  const at12 = payload(tempC, 0x00, 0x00, DEFAULT_CONFIG);
  const at10 = payload(tempC, 0x4b, 0x46, WRITTEN_CONFIG);
  const readLine = (tag, p, th, tl, cfg) =>
    `${tag} ${p.raw} ${p.milliC} 1 ${hexUpper(th)} ${hexUpper(tl)} ${hexUpper(cfg)}`;
  const servoTemp = readLine('temp', at12, 0x00, 0x00, DEFAULT_CONFIG);
  const serveCfg = readLine('cfg', at10, 0x4b, 0x46, WRITTEN_CONFIG);
  return [
    `present ${present}`,
    `rom ${ROM.map(hexUpper).join(' ')} ${romOK ? 'crc-ok' : 'crc-bad'}`,
    'match-bad crc-bad',
    'match-ok crc-ok',
    servoTemp, servoTemp, servoTemp,
    serveCfg,
    'e2',
  ];
}

function assertMain(label, { spec, tempC, ms = 2400 }) {
  const out = run(spec, ms);
  const serial = out.serial.replace(/\r/g, '').split('\n').map((l) => l.trim()).filter(Boolean);
  const want = expectedSerial(tempC);
  check(serial.length === want.length,
    `${label}: ${serial.length} serial lines (want ${want.length}): ${JSON.stringify(serial)}`);
  serial.forEach((line, i) => check(line === want[i], `${label}: line ${i} "${line}" (want "${want[i]}")`));

  const dev = out.pin_devices[0] ?? {};
  check(dev.kind === 'ds18b20' && dev.pin === FIRMWARE_PIN,
    `${label}: device is ${dev.kind} on pin ${dev.pin}`);
  check(dev.rom_hex === ROM.map(hex).join(' ') && dev.rom_crc_ok === true,
    `${label}: served ROM ${dev.rom_hex} (crc ${dev.rom_crc_ok})`);
  check(dev.presence === dev.resets && dev.resets === 13,
    `${label}: ${dev.resets} resets / ${dev.presence} presence pulses (want 13/13 - every reset answered)`);
  check(dev.converts === 2, `${label}: ${dev.converts} conversions (want 2)`);
  check(dev.muted === true, `${label}: a non-matching MATCH ROM was not recorded`);
  const cmds = JSON.stringify(dev.commands);
  check(cmds === JSON.stringify(expectedCommands()), `${label}: command stream ${cmds}`);
  check(dev.writes_config === 1 && dev.config === WRITTEN_CONFIG && dev.resolution === 10,
    `${label}: config ${dev.config} at ${dev.resolution} bits after ${dev.writes_config} WRITE SCRATCHPAD`);
  check(dev.alarm_high === 0x4b && dev.alarm_low === 0x46,
    `${label}: TH/TL ${dev.alarm_high}/${dev.alarm_low} (want 0x4b/0x46)`);
  check(dev.copies === 1 && dev.recalls === 1 && dev.search === 0 && dev.unknown_commands === 0,
    `${label}: copies ${dev.copies} recalls ${dev.recalls} search ${dev.search} unknown ${dev.unknown_commands}`);
  check(dev.scratchpad_reads === 5, `${label}: ${dev.scratchpad_reads} scratchpad reads (want 5)`);
  // The live payload (at the config the sketch wrote) must be the 10-bit quantised one.
  const live = payload(tempC, 0x4b, 0x46, WRITTEN_CONFIG);
  check(dev.scratchpad_hex === live.bytes.map(hex).join(' ') && dev.scratchpad_crc_ok === true,
    `${label}: scratchpad ${dev.scratchpad_hex} (want ${live.bytes.map(hex).join(' ')})`);
  // ... and the wire log has to hold what was served at each read's own resolution: the first
  // four at 12-bit (the MATCH ROM read and the three temperature reads), the last after the
  // config write at 10-bit.
  const pre = payload(tempC, 0x00, 0x00, DEFAULT_CONFIG);
  const reads = dev.reads ?? [];
  reads.slice(0, 4).forEach((r, i) => check(
    JSON.stringify(r.bytes) === JSON.stringify(pre.bytes) && r.resolution === 12 && r.crc_ok === true,
    `${label}: read ${i} served ${JSON.stringify(r.bytes)} at ${r.resolution} bits`,
  ));
  reads.slice(4).forEach((r, i) => check(
    JSON.stringify(r.bytes) === JSON.stringify(live.bytes) && r.resolution === 10 && r.crc_ok === true,
    `${label}: read ${i + 4} served ${JSON.stringify(r.bytes)} at ${r.resolution} bits`,
  ));
  console.log(`${label} -> ${serial.length} lines, ${dev.resets} resets, ${dev.scratchpad_reads} reads, `
    + `temp ${payload(tempC, 0x00, 0x00, DEFAULT_CONFIG).raw} raw / ${payload(tempC, 0x4b, 0x46, WRITTEN_CONFIG).raw} at 10 bits`);
  return dev;
}

// 1. The configured part: 23.1 C is a value the 12-bit resolution can hold (raw 370) but the
//    10-bit one cannot (raw 368 = 23.0 C), so the read-back after the config write shows the
//    quantisation the *part* applies.
assertMain('temp 23.1 C', { spec: { kind: 'ds18b20', pin: FIRMWARE_PIN, temp_c: 23.1 }, tempC: 23.1 });

// 2. Positive control: a negative temperature, whose 16-bit two's-complement count and the
//    conversion to milli-degrees must follow the spec (-162 raw / -10125 mC, -164 / -10250 at
//    10 bits). Nothing in the firmware knows this number.
{
  const label = 'control -10.125 C';
  const dev = assertMain(label, { spec: { kind: 'ds18b20', pin: FIRMWARE_PIN, temp_c: -10.125 }, tempC: -10.125 });
  check(dev.temp_c === -10.125, `${label}: device reports ${dev.temp_c} C`);
}

// 3. Negative control - pull-up only: no part answers, so the driver must see *no* presence
//    pulse, read all ones and fail every CRC. The pull-up is modelled explicitly because the
//    harness has no resistors on MCU pins (an unattached pin floats low; see case 4), and a
//    bus with a pull-up and no sensor is what "no device" really looks like.
{
  const label = 'control no device (pull-up only)';
  const out = run({ kind: 'ds18b20', pin: FIRMWARE_PIN, absent: 1 }, 2400);
  const serial = out.serial.replace(/\r/g, '').split('\n').map((l) => l.trim()).filter(Boolean);
  const want = [
    'present 0',
    'rom FF FF FF FF FF FF FF FF crc-bad',
    'match-bad crc-bad',
    'match-ok crc-bad',
    'temp -1 -62 0 FF FF FF',
    'temp -1 -62 0 FF FF FF',
    'temp -1 -62 0 FF FF FF',
    'cfg -1 -62 0 FF FF FF',
    'e2',
  ];
  check(JSON.stringify(serial) === JSON.stringify(want),
    `${label}: ${JSON.stringify(serial)}`);
  const dev = out.pin_devices[0] ?? {};
  check(dev.absent === true && dev.resets === undefined && dev.presence === undefined,
    `${label}: the bus pull-up must not act like a part (${JSON.stringify(dev)})`);
  console.log(`${label} -> no presence pulse, every CRC failed (line 1: "${serial[0]}")`);
}

// 4. The part served on a pin the firmware does not use: its own counters stay at zero, so
//    nothing it decoded could be in the output. The firmware's pin has no pull-up here (an
//    unattached 1-Wire pin floats low in this model), which reads as a false "presence" and an
//    all-zero scratchpad whose CRC is trivially valid (the CRC-8 of zeros is 0) - the reason a
//    no-device control uses the pull-up above, and why this case asserts the *garbage*, not a
//    CRC verdict.
{
  const label = 'control device on pin 3';
  const out = run({ kind: 'ds18b20', pin: 3, temp_c: 23.1 }, 2400);
  const serial = out.serial.replace(/\r/g, '').split('\n').map((l) => l.trim()).filter(Boolean);
  // Every bit reads 0, so the ROM is all zeros, the CRC of an all-zero scratchpad is 0 (valid,
  // trivially), the config byte never follows the sketch's write and the temperature is 0.0 C.
  const want = [
    'present 1',
    'rom 00 00 00 00 00 00 00 00 crc-ok',
    'match-bad crc-ok',
    'match-ok crc-ok',
    'temp 0 0 1 00 00 00',
    'temp 0 0 1 00 00 00',
    'temp 0 0 1 00 00 00',
    'cfg 0 0 1 00 00 00',
    'e2',
  ];
  check(JSON.stringify(serial) === JSON.stringify(want),
    `${label}: ${JSON.stringify(serial)}`);
  const dev = out.pin_devices[0] ?? {};
  check(dev.pin === 3 && dev.resets === 0 && dev.presence === 0 && dev.scratchpad_reads === 0,
    `${label}: the part on pin 3 saw no traffic (${JSON.stringify(dev).slice(0, 120)})`);
  console.log(`${label} -> firmware decoded 0.0 C from a floating pin, served part saw no traffic`);
}

if (failures.length) {
  console.error(`FAIL:\n  ${failures.join('\n  ')}`);
  process.exit(1);
}
console.log('PASS: DS18B20 1-Wire slave - presence, READ ROM + CRC-8, MATCH ROM (match and miss), '
  + 'CONVERT T, READ/WRITE SCRATCHPAD with resolution quantisation, COPY/RECALL, and controls');
