// Reproducible check for the SSD1306 OLED: serve a 128x64 panel (CF_DEVICES), run the
// oled_fill sketch and assert the decoded GDDRAM frame matches the drawn pattern
// (pages 0..3 white, 4..7 black => 4096 lit pixels). Exit 0/1.
//
//   arduino-cli compile --fqbn arduino:avr:uno --output-dir build/oled_fill \
//     sketches/oled_fill
//   node verify_oled.mjs build/oled_fill/oled_fill.ino.hex
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const hexPath = process.argv[2] ?? join(here, '..', 'build', 'oled_fill', 'oled_fill.ino.hex');

const COLS = 128;
const PAGES = 8;
const WHITE_PAGES = 4; // top half lit

const raw = execFileSync(process.execPath, [join(here, 'run.mjs'), hexPath, '600'], {
  encoding: 'utf8',
  env: {
    ...process.env,
    CF_DEVICES: JSON.stringify([{ kind: 'ssd1306', address: 0x3c, cols: COLS, pages: PAGES }]),
  },
});
const { serial = '', devices = [] } = JSON.parse(raw);
const dev = devices[0] ?? {};
const pages = dev.pages_hex ?? [];

const failures = [];
if (dev.kind !== 'ssd1306') failures.push(`kind=${dev.kind} (want ssd1306)`);
if (dev.display_on !== true) failures.push(`display_on=${dev.display_on} (want true)`);
if (pages.length !== PAGES) failures.push(`pages=${pages.length} (want ${PAGES})`);
if (dev.pixels_set !== WHITE_PAGES * COLS * 8) {
  failures.push(`pixels_set=${dev.pixels_set} (want ${WHITE_PAGES * COLS * 8})`);
}
for (let p = 0; p < PAGES && p < pages.length; p++) {
  const want = (p < WHITE_PAGES ? 'ff' : '00').repeat(COLS);
  if (pages[p] !== want) failures.push(`page ${p} differs from ${p < WHITE_PAGES ? 'white' : 'black'}`);
}
if (!/oled bytes 1024/.test(serial)) failures.push(`serial missing the frame report: ${JSON.stringify(serial)}`);

console.log(`display_on=${dev.display_on} pixels_set=${dev.pixels_set} pages=${pages.length} serial="${serial.trim()}"`);
if (failures.length) {
  console.error(`FAIL:\n  ${failures.join('\n  ')}`);
  process.exit(1);
}
console.log('PASS: SSD1306 decoded the 128x64 frame (top half lit, 4096 pixels)');
