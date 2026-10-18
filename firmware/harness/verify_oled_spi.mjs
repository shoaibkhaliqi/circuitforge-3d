// Reproducible check for the SPI SSD1306 OLED: serve the panel on the AVR's SPI
// peripheral (CF_DEVICES), run the oled_spi sketch and assert the GDDRAM frame decoded
// from the MOSI byte stream matches the drawn pattern (left half white => 4096 lit
// pixels). Also proves the DC line is what tags command vs data: with no DC the same
// bytes must *not* decode into the frame. Exit 0/1.
//
//   arduino-cli compile --fqbn arduino:avr:uno --output-dir build/oled_spi \
//     sketches/oled_spi
//   node verify_oled_spi.mjs build/oled_spi/oled_spi.ino.hex
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const hexPath = process.argv[2] ?? join(here, '..', 'build', 'oled_spi', 'oled_spi.ino.hex');

const COLS = 128;
const PAGES = 8;
const WHITE_COLS = 64;   // left half lit
const DC_PIN = 9;
const CS_PIN = 10;
const EXPECTED_DATA = COLS * PAGES;
const EXPECTED_CMD = 31;  // the init block (25) + the 0x21/0x22 window (6)

const run = (spec, ms = 700) => {
  const raw = execFileSync(process.execPath, [join(here, 'run.mjs'), hexPath, String(ms)], {
    encoding: 'utf8',
    maxBuffer: 64 * 1024 * 1024,
    env: { ...process.env, CF_DEVICES: JSON.stringify([spec]) },
  });
  return JSON.parse(raw);
};

const { serial = '', devices = [], spi_bytes: spiBytes = [] } = run({
  kind: 'ssd1306_spi', dc: DC_PIN, cs: CS_PIN, cols: COLS, pages: PAGES,
});
const dev = devices[0] ?? {};
const pages = dev.pages_hex ?? [];
const failures = [];

if (dev.kind !== 'ssd1306_spi') failures.push(`kind=${dev.kind} (want ssd1306_spi)`);
if (dev.dc_pin !== DC_PIN) failures.push(`dc_pin=${dev.dc_pin} (want ${DC_PIN})`);
if (dev.cs_pin !== CS_PIN) failures.push(`cs_pin=${dev.cs_pin} (want ${CS_PIN})`);
if (dev.display_on !== true) failures.push(`display_on=${dev.display_on} (want true)`);
if (dev.data_bytes !== EXPECTED_DATA) failures.push(`data_bytes=${dev.data_bytes} (want ${EXPECTED_DATA})`);
if (dev.bytes !== EXPECTED_DATA + EXPECTED_CMD) {
  failures.push(`bytes=${dev.bytes} (want ${EXPECTED_DATA + EXPECTED_CMD})`);
}
if (dev.deselected !== 0) failures.push(`deselected=${dev.deselected} (want 0: CS held low)`);
if (pages.length !== PAGES) failures.push(`pages=${pages.length} (want ${PAGES})`);
const wantLit = WHITE_COLS * 64;
if (dev.pixels_set !== wantLit) failures.push(`pixels_set=${dev.pixels_set} (want ${wantLit})`);
for (let p = 0; p < PAGES && p < pages.length; p++) {
  const want = 'ff'.repeat(WHITE_COLS) + '00'.repeat(COLS - WHITE_COLS);
  if (pages[p] !== want) failures.push(`page ${p} differs from "left half white"`);
}
if (spiBytes.length !== dev.bytes) {
  failures.push(`spi_bytes=${spiBytes.length} (want ${dev.bytes}, the raw trace)`);
}
if (spiBytes.slice(0, 3).join(',') !== '174,213,128') {
  failures.push(`SPI trace does not start with the 0xAE/0xD5/0x80 init: ${spiBytes.slice(0, 3)}`);
}
if (!/oled spi bytes 1024 left half ff/.test(serial)) {
  failures.push(`serial missing the frame report: ${JSON.stringify(serial)}`);
}

// Negative control: the harness must use DC to tell commands from data, so the very same
// byte stream with no DC line cannot produce the frame (every data byte reads as a command).
const blind = run({ kind: 'ssd1306_spi', cols: COLS, pages: PAGES });
const blindDev = blind.devices[0] ?? {};
if (blindDev.pixels_set === wantLit) {
  failures.push('without DC the panel still decoded the frame - DC is not actually used');
}
if (blindDev.data_bytes !== 0) {
  failures.push(`without DC data_bytes=${blindDev.data_bytes} (want 0)`);
}

console.log(`display_on=${dev.display_on} pixels_set=${dev.pixels_set} bytes=${dev.bytes} `
  + `(${dev.data_bytes} data) pages=${pages.length} serial="${serial.trim()}"`);
console.log(`no-DC control: pixels_set=${blindDev.pixels_set} data_bytes=${blindDev.data_bytes}`);
if (failures.length) {
  console.error(`FAIL:\n  ${failures.join('\n  ')}`);
  process.exit(1);
}
console.log('PASS: SPI SSD1306 decoded the 128x64 frame (left half lit, 4096 pixels) '
  + 'and the DC line is what tags command vs data');
