// Reproducible check for the ILI9341 colour TFT: serve the panel on the AVR's SPI peripheral
// (CF_DEVICES), run the tft_fill sketch and assert the RGB565 frame decoded from the MOSI
// byte stream matches the drawn pattern (left half red 0xF800, right half blue 0x001F).
// The frame hash is recomputed here from the pattern, so the whole 76800-pixel buffer is
// checked, not just a sample. Also proves the DC line is what tags command vs data: with no
// DC the same bytes must not fill the frame. Exit 0/1.
//
//   arduino-cli compile --fqbn arduino:avr:uno --output-dir build/tft_fill \
//     sketches/tft_fill
//   node verify_tft.mjs build/tft_fill/tft_fill.ino.hex
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const hexPath = process.argv[2] ?? join(here, '..', 'build', 'tft_fill', 'tft_fill.ino.hex');

const W = 240;
const H = 320;
const DC_PIN = 9;
const CS_PIN = 10;
const RED = 0xf800;
const BLUE = 0x001f;
const HALF = W / 2;
// The sketch's init sends 25 command bytes (DC low) and 69 parameters (DC high), then the
// 76800-pixel frame as 153600 bytes.
const EXPECTED_CMD = 25;
const EXPECTED_PARAM = 69;
const EXPECTED_PIXEL_BYTES = W * H * 2;

const run = (spec, ms = 2500) => {
  const raw = execFileSync(process.execPath, [join(here, 'run.mjs'), hexPath, String(ms)], {
    encoding: 'utf8',
    maxBuffer: 64 * 1024 * 1024,
    env: { ...process.env, CF_DEVICES: JSON.stringify([spec]) },
  });
  return JSON.parse(raw);
};

// The frame the sketch draws, hashed the same way the harness hashes it (FNV-1a over the
// big-endian RGB565 pairs, row-major) so a wrong pixel anywhere changes the digest.
const expectedHash = () => {
  let hash = 0x811c9dc5;
  for (let y = 0; y < H; y++) {
    for (let x = 0; x < W; x++) {
      const v = x < HALF ? RED : BLUE;
      hash ^= (v >> 8) & 0xff; hash = Math.imul(hash, 0x01000193) >>> 0;
      hash ^= v & 0xff; hash = Math.imul(hash, 0x01000193) >>> 0;
    }
  }
  return hash.toString(16).padStart(8, '0');
};

const { serial = '', devices = [], spi_bytes: spiBytes = [], spi_byte_count: spiCount = 0 } = run({
  kind: 'ili9341', dc: DC_PIN, cs: CS_PIN, width: W, height: H,
});
const dev = devices[0] ?? {};
const failures = [];
const want = (label, got, expected) => {
  if (got !== expected) failures.push(`${label}=${JSON.stringify(got)} (want ${JSON.stringify(expected)})`);
};

want('kind', dev.kind, 'ili9341');
want('dc_pin', dev.dc_pin, DC_PIN);
want('cs_pin', dev.cs_pin, CS_PIN);
want('width', dev.width, W);
want('height', dev.height, H);
want('display_on', dev.display_on, true);
want('sleeping', dev.sleeping, false);
want('colmod', dev.colmod, 0x55);   // 16 bits/pixel, as the sketch sets it
want('madctl', dev.madctl, 0x48);
want('pixels_written', dev.pixels_written, W * H);
want('colors', dev.colors, 2);
want('data_bytes', dev.data_bytes, EXPECTED_PIXEL_BYTES + EXPECTED_PARAM);
want('bytes', dev.bytes, EXPECTED_PIXEL_BYTES + EXPECTED_PARAM + EXPECTED_CMD);
want('deselected', dev.deselected, 0); // CS held low for the whole run
want('window', JSON.stringify(dev.window), JSON.stringify([0, W - 1, 0, H - 1]));
want('frame_hash', dev.frame_hash, expectedHash());
// The probes are redundant with the hash, but they pin the geometry (mirroring/madctl) too.
const probes = dev.probes ?? [];
const wantProbe = (i, x, y, colour) => {
  const p = probes[i] ?? {};
  want(`probe[${i}]`, `${p.x},${p.y},${p.color}`, `${x},${y},${colour}`);
};
wantProbe(0, 0, 0, RED);                    // top-left, red
wantProbe(1, W - 1, 0, BLUE);               // top-right, blue
wantProbe(2, 0, H - 1, RED);                // bottom-left, red
wantProbe(3, W - 1, H - 1, BLUE);           // bottom-right, blue
wantProbe(4, W >> 1, H >> 1, BLUE);         // centre (first blue column), blue
want('spi_byte_count', spiCount, dev.bytes); // the true trace length
want('spi_bytes (capped trace)', spiBytes.length, Math.min(4096, dev.bytes));
if (spiBytes[0] !== 0x01 || spiBytes[1] !== 0x11) {
  failures.push(`SPI trace does not start with the 0x01/0x11 reset+sleep-out: ${spiBytes.slice(0, 2)}`);
}
if (!/tft pixels 76800 left half red/.test(serial)) {
  failures.push(`serial missing the pixel report: ${JSON.stringify(serial)}`);
}

// Negative control: the harness must use DC to tell commands from parameters and pixels, so
// the very same byte stream with no DC line cannot fill the frame.
const blind = run({ kind: 'ili9341', width: W, height: H });
const blindDev = blind.devices[0] ?? {};
if (blindDev.pixels_written !== 0) {
  failures.push(`without DC pixels_written=${blindDev.pixels_written} (want 0)`);
}
if (blindDev.frame_hash === expectedHash()) {
  failures.push('without DC the panel still decoded the frame - DC is not actually used');
}

console.log(`display_on=${dev.display_on} colmod=0x${(dev.colmod ?? 0).toString(16)} `
  + `madctl=0x${(dev.madctl ?? 0).toString(16)} pixels_written=${dev.pixels_written} `
  + `colors=${dev.colors} bytes=${dev.bytes} (${dev.data_bytes} data) `
  + `hash=${dev.frame_hash} serial="${serial.trim()}"`);
console.log(`no-DC control: pixels_written=${blindDev.pixels_written} hash=${blindDev.frame_hash}`);
if (failures.length) {
  console.error(`FAIL:\n  ${failures.join('\n  ')}`);
  process.exit(1);
}
console.log('PASS: ILI9341 decoded the 240x320 RGB565 frame (left half red, right half blue, '
  + '76800 pixels) and the DC line is what tags command vs parameter/data');
