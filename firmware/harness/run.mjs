// M7 spike harness — runs an arduino-cli Intel HEX on avr8js (MIT) and streams
// GPIO transitions as JSON on stdout.
//
//   node run.mjs <hexPath> <msLimit>
//
// It wires up the ATmega328P peripherals an Arduino Uno sketch needs (timer0/1/2
// + ports B/C/D), executes one instruction at a time, and records every change of
// a PORT output bit with the emulated timestamp (cpu.cycles / F_CPU).
//
// Nothing here is cycle-accurate against external analog: this is an open-loop
// (Stage B) spike. It only proves that a real compiled sketch runs and that its
// digital pin activity is deterministic and readable.
import { readFileSync } from 'node:fs';
import {
  CPU,
  avrInstruction,
  AVRTimer,
  AVRUSART,
  AVRTWI,
  AVRSPI,
  AVRADC,
  AVRIOPort,
  timer0Config,
  timer1Config,
  timer2Config,
  usart0Config,
  twiConfig,
  spiConfig,
  adcConfig,
  portBConfig,
  portCConfig,
  portDConfig,
} from 'avr8js';

const F_CPU = 16_000_000;

function loadHexProgram(path) {
  const bytes = new Uint8Array(0x8000);
  const text = readFileSync(path, 'utf8');
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (!line.startsWith(':')) continue;
    const rec = Buffer.from(line.slice(1), 'hex');
    const len = rec[0];
    const addr = (rec[1] << 8) | rec[2];
    const type = rec[3];
    if (type === 0x00) {
      for (let i = 0; i < len; i++) bytes[addr + i] = rec[4 + i];
    }
  }
  return new Uint16Array(bytes.buffer, bytes.byteOffset, bytes.length / 2);
}

const [hexPath, msArg] = process.argv.slice(2);
if (!hexPath) {
  process.stdout.write(
    JSON.stringify({ ok: false, error: 'usage: node run.mjs <hexPath> [msLimit]' }) + '\n',
  );
  process.exit(2);
}
const msLimit = Number(msArg ?? 3000);

let program;
try {
  program = loadHexProgram(hexPath);
} catch (err) {
  process.stdout.write(
    JSON.stringify({ ok: false, error: `cannot read firmware: ${err.message}` }) + '\n',
  );
  process.exit(3);
}

const cpu = new CPU(program);
new AVRTimer(cpu, timer0Config);
new AVRTimer(cpu, timer1Config);
new AVRTimer(cpu, timer2Config);

const ports = {
  B: new AVRIOPort(cpu, portBConfig),
  C: new AVRIOPort(cpu, portCConfig),
  D: new AVRIOPort(cpu, portDConfig),
};

// USART0 (the Uno's USB-serial): capture every byte the sketch transmits so a
// caller can read Serial.print output. This is the first real *protocol* surface
// (UART) the harness exposes, independent of the digital-pin transitions.
const usart = new AVRUSART(cpu, usart0Config, F_CPU);
const serialBytes = [];
usart.onByteTransmit = (value) => serialBytes.push(value & 0xff);

// I2C (TWI) bus with optional devices. With no devices attached the harness just
// ACKs so a sketch's Wire transaction can proceed, records each transaction
// (address, direction, bytes) and returns 0xFF on read. When devices are supplied
// through the CF_DEVICES env var the matching address is served by a device model
// (so firmware can *read* a device — device -> firmware feedback).
//
//   CF_DEVICES=[{"kind":"pcf8574","address":39,"state":0,"inputs":15}]
//   CF_DEVICES=[{"kind":"eeprom","address":80,"size":256,"init":[1,2,3]}]
//   CF_DEVICES=[{"kind":"pcf8591","address":72,"ain":[2.5,0,0,0],"vref":5}]
//   CF_DEVICES=[{"kind":"lcd1602","address":39,"cols":16,"rows":2}]
//   CF_DEVICES=[{"kind":"mpu6050","address":104,"az":1,"temp_c":25}]
//   CF_DEVICES=[{"kind":"ssd1306","address":60,"cols":128,"pages":8}]
//   CF_DEVICES=[{"kind":"ssd1306_spi","dc":9,"cs":10,"cols":128,"pages":8}]
//   CF_DEVICES=[{"kind":"ili9341","dc":9,"cs":10,"width":240,"height":320}]
//   CF_DEVICES=[{"kind":"sht31","address":68,"temp_c":23,"humidity":48}]
//   CF_DEVICES=[{"kind":"mcp3008","cs":10,"vref":5,"ain":[3.3,1.25,0,5]}]
//   CF_DEVICES=[{"kind":"adxl345","address":83,"ax":0.5,"ay":-0.25,"az":1}]
//   CF_DEVICES=[{"kind":"ads1115","address":72,"ain":[2.5,1,0,3.3]}]
//   CF_DEVICES=[{"kind":"mcp4725","address":96,"vref":5}]
//
// `hc_sr04`, `encoder`, `dht` and `ds18b20` are not I2C devices: they drive MCU *input*
// pins (or, for the DS18B20, a whole 1-Wire bus), so they are listed separately as
// pin_devices.
//   CF_DEVICES=[{"kind":"hc_sr04","trig":9,"echo":10,"distance_cm":30}]
//   CF_DEVICES=[{"kind":"encoder","a":2,"b":3,"counts":50,"direction":1}]
//   CF_DEVICES=[{"kind":"dht","pin":2,"model":"dht22","temp_c":23,"humidity":48}]
//   CF_DEVICES=[{"kind":"ds18b20","pin":2,"temp_c":23.1}]
const pinDevices = [];
// SPI-attached devices. Unlike I2C there is no address to hook: the AVR's own SPI
// peripheral is the bus, so these are decoded from the transfers the monitor records,
// with the DC (command/data) and CS (select) line levels sampled at each transfer. A
// device may also *answer* on MISO (the monitor returns what its `onByte` gives back),
// which is how a read-only part like the MCP3008 serves firmware reads.
const spiDevices = [];

// SSD1306 GDDRAM + command engine, shared by the I2C and SPI panels: both are fed the same
// command/data stream and differ only in how a byte is tagged (I2C control byte vs the SPI
// DC line). Page/horizontal/vertical addressing, the 0x21/0x22 range commands and the
// B0-B7 column-set are tracked so a driver's frame writes land in the right place; the
// frame is returned as hex pages.
function makeSsd1306(cols, nPages) {
  const fb = new Uint8Array(cols * nPages);
  let col = 0;
  let page = 0;
  let colStart = 0;
  let colEnd = cols - 1;
  let pageStart = 0;
  let pageEnd = nPages - 1;
  let addrMode = 2; // 2 = page addressing, 0 = horizontal, 1 = vertical
  let cmd = -1;
  let args = [];
  let displayOn = false;
  let dataBytes = 0;
  const argCount = (c) =>
    c === 0x21 || c === 0x22 ? 2
      : (c === 0x20 || c === 0x81 || c === 0xd5 || c === 0xd9 || c === 0xda || c === 0x8d || c === 0xdb || c === 0xa8) ? 1
        : 0;
  const applyCmd = (c) => {
    if (cmd >= 0) {
      args.push(c);
      if (args.length < argCount(cmd)) return;
      if (cmd === 0x20) addrMode = args[0] & 0x03;
      else if (cmd === 0x21) { colStart = args[0] & 0x7f; colEnd = args[1] & 0x7f; col = colStart; }
      else if (cmd === 0x22) { pageStart = args[0] & 0x07; pageEnd = args[1] & 0x07; page = pageStart; }
      cmd = -1;
      args = [];
      return;
    }
    if (c >= 0xb0 && c <= 0xb7) page = (c & 0x07) % nPages;
    else if (c <= 0x0f) col = (col & 0xf0) | c;
    else if (c >= 0x10 && c <= 0x1f) col = (col & 0x0f) | ((c & 0x0f) << 4);
    else if (c === 0xae) displayOn = false;
    else if (c === 0xaf) displayOn = true;
    else if (argCount(c) > 0) { cmd = c; args = []; }
  };
  const writeData = (b) => {
    dataBytes++;
    if (col >= 0 && col < cols && page >= 0 && page < nPages) fb[page * cols + col] = b;
    if (addrMode === 0) {
      col++;
      if (col > colEnd) { col = colStart; page++; if (page > pageEnd) page = pageStart; }
    } else if (addrMode === 1) {
      page++;
      if (page > pageEnd) { page = pageStart; col++; if (col > colEnd) col = colStart; }
    } else {
      col++;
      if (col >= cols) col = 0;
    }
  };
  return {
    writeCommand: applyCmd,
    writeData,
    fields: () => {
      const pagesHex = [];
      let set = 0;
      for (let p = 0; p < nPages; p++) {
        let s2 = '';
        for (let c2 = 0; c2 < cols; c2++) {
          const v = fb[p * cols + c2];
          s2 += v.toString(16).padStart(2, '0');
          for (let x = v; x; x >>= 1) set += x & 1;
        }
        pagesHex.push(s2);
      }
      return {
        cols, pages: nPages, display_on: displayOn,
        pixels_set: set, data_bytes: dataBytes, pages_hex: pagesHex,
      };
    },
  };
}

// ILI9341 colour TFT (240x320) GDDRAM engine. The command stream is the usual one a small
// driver sends: 0x2A/0x2B set the column/page address window (four argument bytes each) and
// 0x2C streams pixels big-endian into that window; the other init commands are recognised
// only so their argument bytes are consumed rather than mistaken for commands. The frame is
// *summarised*, never returned whole (a full RGB565 frame is 153600 bytes, which would dwarf
// the rest of the reply): the written-pixel count, the distinct colour count, an FNV-1a hash
// over the RGB565 buffer and five probe pixels pin the drawn pattern exactly.
function makeIli9341(width, height) {
  const fb = new Uint16Array(width * height);
  const painted = new Uint8Array(width * height); // separate: 0x0000 is a legal colour
  let colStart = 0;
  let colEnd = width - 1;
  let pageStart = 0;
  let pageEnd = height - 1;
  let col = 0;
  let page = 0;
  let madctl = 0;
  let colmod = 0x55; // 16 bits/pixel, the power-on default most drivers rely on
  let displayOn = false;
  let sleeping = true;
  let cmd = -1;
  let args = [];
  let pixelsWritten = 0;
  let dataBytes = 0;
  let writeMode = false; // between 0x2C and the next command the data bytes are pixels
  let hi = -1;           // high byte of the current RGB565 pixel
  // Argument counts for the commands a typical ILI9341 init sends. An unrecognised command
  // takes none, which is the honest limit: its arguments would then read as commands.
  const ARGC = {
    0x01: 0, 0x10: 0, 0x11: 0, 0x13: 0, 0x20: 0, 0x21: 0, 0x26: 1, 0x28: 0, 0x29: 0,
    0x2a: 4, 0x2b: 4, 0x2c: 0, 0x2e: 0, 0x35: 1, 0x36: 1, 0x37: 2, 0x3a: 1,
    0x51: 1, 0x53: 1, 0x55: 1, 0xb0: 1, 0xb1: 2, 0xb4: 1, 0xb6: 3, 0xbf: 1,
    0xc0: 1, 0xc1: 1, 0xc5: 2, 0xc7: 1, 0xcb: 4, 0xcf: 3, 0xd3: 2, 0xda: 2,
    0xe0: 15, 0xe1: 15, 0xe8: 3, 0xea: 2, 0xed: 4, 0xf2: 1, 0xf7: 1,
  };
  const applyCmd = () => {
    const c = cmd;
    const a = args;
    cmd = -1;
    args = [];
    if (c === 0x2a) { colStart = (a[0] << 8) | a[1]; colEnd = (a[2] << 8) | a[3]; col = colStart; }
    else if (c === 0x2b) { pageStart = (a[0] << 8) | a[1]; pageEnd = (a[2] << 8) | a[3]; page = pageStart; }
    else if (c === 0x36) madctl = a[0]; // recorded, not applied: no rotation/orientation
    else if (c === 0x3a) colmod = a[0];
  };
  const writeCommand = (b) => {
    // A DC-low byte is a command. It also aborts an unfinished one: the ILI9341 sends a
    // command's parameters with DC *high*, so a command byte can never be an argument.
    writeMode = false;
    hi = -1;
    cmd = -1;
    args = [];
    if (b === 0x2c) { writeMode = true; col = colStart; page = pageStart; return; }
    if (b === 0x11) sleeping = false;
    else if (b === 0x10) sleeping = true;
    else if (b === 0x29) displayOn = true;
    else if (b === 0x28) displayOn = false;
    if (ARGC[b] > 0) { cmd = b; args = []; }
  };
  const writeData = (b) => {
    dataBytes++;
    b &= 0xff;
    if (cmd >= 0) { // a command's parameters arrive with DC high
      args.push(b);
      if (args.length >= ARGC[cmd]) applyCmd();
      return;
    }
    if (!writeMode) return; // data outside a command or memory write: ignored
    if (hi < 0) { hi = b; return; }
    const px = (hi << 8) | b;
    hi = -1;
    if (col >= 0 && col < width && page >= 0 && page < height) {
      const i = page * width + col;
      if (!painted[i]) { painted[i] = 1; pixelsWritten++; }
      fb[i] = px;
    }
    col++;
    if (col > colEnd) { col = colStart; page++; if (page > pageEnd) page = pageStart; }
  };
  return {
    writeCommand,
    writeData,
    fields: () => {
      let hash = 0x811c9dc5; // FNV-1a 32-bit over the RGB565 buffer, row-major
      const colors = new Set();
      for (let i = 0; i < fb.length; i++) {
        const v = fb[i];
        hash ^= (v >> 8) & 0xff; hash = Math.imul(hash, 0x01000193) >>> 0;
        hash ^= v & 0xff; hash = Math.imul(hash, 0x01000193) >>> 0;
        colors.add(v);
      }
      const probe = (x, y) => ({ x, y, color: fb[y * width + x] });
      return {
        width, height, colmod, madctl, display_on: displayOn, sleeping,
        data_bytes: dataBytes, pixels_written: pixelsWritten, colors: colors.size,
        frame_hash: hash.toString(16).padStart(8, '0'),
        window: [colStart, colEnd, pageStart, pageEnd],
        probes: [probe(0, 0), probe(width - 1, 0), probe(0, height - 1),
          probe(width - 1, height - 1), probe(width >> 1, height >> 1)],
      };
    },
  };
}

// E-paper (Waveshare 2.13") SPI frame: a monochrome panel addressed by a single RAM
// write (command 0x10) followed by a refresh (0x12). DC low = command, DC high = data,
// exactly like the SSD1306/ILI9341 panels; CS frames the transaction. The frame buffer
// is row-major, one bit per pixel (0 = black, 1 = white). BUSY/RST are not electrically
// modelled - the decoded frame and the byte count are what a driver's output can be
// checked against.
function makeEpaper(width, height) {
  const bytesPerRow = Math.ceil(width / 8);
  const totalBytes = bytesPerRow * height;
  const fb = new Uint8Array(totalBytes);
  let writeMode = false;
  let idx = 0;
  let dataBytes = 0;
  let refreshed = false;
  let displayOn = false;
  const ARGC = { 0x10: 0, 0x11: 1, 0x12: 0, 0x13: 0, 0x20: 1, 0x21: 1, 0x22: 1,
    0x24: 0, 0x26: 1, 0x32: 0, 0x3c: 1, 0x3f: 1, 0x44: 2, 0x45: 2, 0x4e: 1,
    0x4f: 2 };
  let cmd = -1;
  let args = [];
  const applyCmd = (c) => {
    if (c === 0x10) writeMode = true;
    else if (c === 0x12) { refreshed = true; writeMode = false; }
    else if (c === 0x11) displayOn = true;
  };
  const writeCommand = (b) => {
    writeMode = false;
    cmd = -1;
    args = [];
    if (ARGC[b] > 0) { cmd = b; args = []; }
    else applyCmd(b);
  };
  const writeData = (b) => {
    dataBytes++;
    b &= 0xff;
    if (cmd >= 0) {
      args.push(b);
      if (args.length >= ARGC[cmd]) { applyCmd(cmd); cmd = -1; args = []; }
      return;
    }
    if (!writeMode) return;
    if (idx < totalBytes) fb[idx++] = b;
  };
  return {
    writeCommand,
    writeData,
    fields: () => {
      let set = 0;
      for (let i = 0; i < totalBytes; i++) {
        const v = fb[i];
        for (let x = v; x; x >>= 1) set += x & 1;
      }
      let hash = 0x811c9dc5;
      for (let i = 0; i < totalBytes; i++) {
        hash ^= fb[i]; hash = Math.imul(hash, 0x01000193) >>> 0;
      }
      return {
        width, height, data_bytes: dataBytes, bytes_written: idx,
        pixels_set: set, frame_hash: hash.toString(16).padStart(8, '0'),
        refreshed, display_on: displayOn,
      };
    },
  };
}

// MAX7219 8x8 LED matrix driver on SPI: no DC line. Each transaction is a 16-bit word
// (address high byte, data low byte) framed by CS; address 1..8 selects a digit row (a
// byte bitmask, bit 7 = column 0), and 0x09/0x0A/0x0B/0x0C/0x0F configure decode, intensity,
// scan limit, shutdown and display test. BUSY/RST are not modelled.
function makeMax7219() {
  const rows = new Uint8Array(8);
  let intensity = 0x0f;
  let decode = 0x00;
  let scanLimit = 0x07;
  let shutdown = 0x00; // 0 = shutdown, 1 = normal
  let displayTest = 0x00;
  let dataBytes = 0;
  let words = 0;
  let pending = -1; // high byte of the current word
  const writeWord = (addr, data) => {
    addr &= 0x0f; data &= 0xff;
    if (addr >= 0x01 && addr <= 0x08) rows[addr - 1] = data;
    else if (addr === 0x09) decode = data;
    else if (addr === 0x0a) intensity = data & 0x0f;
    else if (addr === 0x0b) scanLimit = data & 0x07;
    else if (addr === 0x0c) shutdown = data & 0x01;
    else if (addr === 0x0f) displayTest = data & 0x01;
    words++;
  };
  return {
    // MAX7219 has no DC line: bytes are paired into 16-bit words by CS framing. The
    // `onByte` callback in the SPI monitor drives this; here we expose byteIn for the
    // device object.
    byteIn(b) {
      dataBytes++;
      b &= 0xff;
      if (pending < 0) { pending = b; return; }
      writeWord(pending, b);
      pending = -1;
    },
    fields: () => {
      const rowsHex = Array.from(rows).map((v) => v.toString(16).padStart(2, '0'));
      let set = 0;
      for (let i = 0; i < 8; i++) for (let x = rows[i]; x; x >>= 1) set += x & 1;
      return {
        rows: rowsHex, intensity, decode, scan_limit: scanLimit,
        shutdown: shutdown === 1, display_test: displayTest === 1,
        data_bytes: dataBytes, words, pixels_set: set,
      };
    },
    // flush a half-word at CS deassertion
    flush() { pending = -1; },
  };
}

// Level of a pin driven by the MCU right now (1 = high, 0 = low or input). Uses the same
// UNO_PIN table as the transition recorder.
function levelOfPin(pin) {
  const p = pinByNumber.get(pin);
  if (!p) return 0;
  return ports[p.port].pinState(p.bit) === 1 ? 1 : 0;
}

function buildDevices() {
  const raw = process.env.CF_DEVICES;
  const map = new Map();
  if (!raw) return map;
  let specs;
  try {
    specs = JSON.parse(raw);
  } catch {
    return map;
  }
  for (const s of Array.isArray(specs) ? specs : []) {
    if (s.kind === 'hc_sr04') {
      pinDevices.push({
        kind: 'hc_sr04',
        trig: Number(s.trig),
        echo: Number(s.echo),
        distance_cm: Math.max(0, Number(s.distance_cm ?? 30)),
        echoes: [],
        error: null,
      });
      continue;
    }
    if (s.kind === 'encoder') {
      pinDevices.push({
        kind: 'encoder',
        a: Number(s.a),
        b: Number(s.b),
        counts: Math.max(0, Math.min(100000, Math.round(Number(s.counts ?? 0)))),
        direction: Number(s.direction ?? 1) >= 0 ? 1 : -1,
        start_us: Math.max(0, Number(s.start_us ?? 2000)),
        step_us: Math.max(50, Number(s.step_us ?? 1000)),
        edges: [],
        error: null,
      });
      continue;
    }
    if (s.kind === 'dht') {
      pinDevices.push({
        kind: 'dht',
        pin: Number(s.pin),
        model: String(s.model ?? 'dht22').toLowerCase() === 'dht11' ? 'dht11' : 'dht22',
        temp_c: Math.max(-40, Math.min(125, Number(s.temp_c ?? 23.0))),
        humidity: Math.max(0, Math.min(100, Number(s.humidity ?? 48.0))),
        reads: [],
        error: null,
      });
      continue;
    }
    if (s.kind === 'ds18b20') {
      pinDevices.push({
        kind: 'ds18b20',
        pin: Number(s.pin),
        // Harness aid, not a part: `absent` serves *only* the bus pull-up, which is how a
        // no-device control gets a realistic idle-high line (the harness has no resistors on
        // MCU pins, so an unattached pin floats low). With it, the master sees no presence
        // pulse at all, which is exactly what "no sensor on the bus" looks like.
        absent: !!s.absent,
        temp_c: Math.max(-55, Math.min(125, Number(s.temp_c ?? 23.0))),
        alarm_high: 0x00,
        alarm_low: 0x00,
        config: 0x7f, // power-on default: 12-bit resolution
        resolution: 12,
        resets: 0,
        presence: 0,
        commands: [],
        converts: 0,
        reads: [],
        writes_config: 0,
        copies: 0,
        recalls: 0,
        search: 0,
        unknown: 0,
        muted: false,
        error: null,
      });
      continue;
    }
    if (s.kind === 'hx711') {
      pinDevices.push({
        kind: 'hx711',
        dout: Number(s.dout),
        sck: Number(s.sck),
        value: Number(s.value ?? 100000) & 0xffffff,
        reads: 0,
        error: null,
      });
      continue;
    }
    if (s.kind === 'ws2812b') {
      pinDevices.push({
        kind: 'ws2812b',
        pin: Number(s.pin),
        count: Math.max(1, Math.min(256, Number(s.count ?? 8))),
        leds: [],
        error: null,
      });
      continue;
    }
    if (s.kind === 'ssd1306_spi' || s.kind === 'ili9341') {
      // A panel on the AVR's SPI peripheral. Unlike I2C there is no address to serve: the
      // bytes come from the SPI monitor and `dc` (command vs data) / `cs` (selected) are
      // sampled live, so both panels share this path and differ only in their core
      // (omit dc/cs as -1 when the board ties that line).
      const core = s.kind === 'ili9341'
        ? makeIli9341(
          Math.max(1, Math.min(1024, Number(s.width ?? 240))),
          Math.max(1, Math.min(1024, Number(s.height ?? 320))))
        : makeSsd1306(
          Math.max(1, Math.min(256, Number(s.cols ?? 128))),
          Math.max(1, Math.min(16, Number(s.pages ?? 8))));
      spiDevices.push({
        kind: s.kind,
        dc: Number.isFinite(Number(s.dc)) ? Number(s.dc) : -1,
        cs: Number.isFinite(Number(s.cs)) ? Number(s.cs) : -1,
        bytes: 0,
        deselected: 0,
        selected: false,
        core,
        onByte(b) {
          if (this.dc >= 0 && levelOfPin(this.dc) === 1) this.core.writeData(b);
          else this.core.writeCommand(b);
          return 0x00; // a panel never drives MISO
        },
        summary() {
          return {
            kind: this.kind, dc_pin: this.dc, cs_pin: this.cs,
            bytes: this.bytes, deselected: this.deselected,
            ...this.core.fields(),
          };
        },
      });
      continue;
    }
    if (s.kind === 'epaper_spi') {
      // E-paper panel on the SPI peripheral: same DC/CS tagging as the OLED/TFT, but a
      // monochrome frame buffer (one bit per pixel) and a refresh command (0x12) that
      // latches the frame. BUSY/RST are not modelled electrically.
      const core = makeEpaper(
        Math.max(1, Math.min(400, Number(s.width ?? 250))),
        Math.max(1, Math.min(400, Number(s.height ?? 122))));
      spiDevices.push({
        kind: 'epaper_spi',
        dc: Number.isFinite(Number(s.dc)) ? Number(s.dc) : -1,
        cs: Number.isFinite(Number(s.cs)) ? Number(s.cs) : -1,
        bytes: 0,
        deselected: 0,
        selected: false,
        core,
        onByte(b) {
          if (this.dc >= 0 && levelOfPin(this.dc) === 1) this.core.writeData(b);
          else this.core.writeCommand(b);
          return 0x00;
        },
        summary() {
          return {
            kind: 'epaper_spi', dc_pin: this.dc, cs_pin: this.cs,
            bytes: this.bytes, deselected: this.deselected,
            ...this.core.fields(),
          };
        },
      });
      continue;
    }
    if (s.kind === 'max7219_spi') {
      const core = makeMax7219();
      spiDevices.push({
        kind: 'max7219_spi',
        dc: -1,
        cs: Number.isFinite(Number(s.cs)) ? Number(s.cs) : -1,
        bytes: 0,
        deselected: 0,
        selected: false,
        core,
        select() { this.core.flush(); },
        onByte(b) {
          this.core.byteIn(b);
          return 0x00;
        },
        summary() {
          return {
            kind: 'max7219_spi', cs_pin: this.cs,
            bytes: this.bytes, deselected: this.deselected,
            ...this.core.fields(),
          };
        },
      });
      continue;
    }
    if (s.kind === 'max6675_spi') {
      const tempC = Number(s.temperature ?? 25);
      const raw = Math.max(0, Math.min(4095, Math.round((tempC / 0.25))));
      const word = (raw & 0x0fff) << 3; // bits 3..14, bit2=0 (connected), bit0=0
      let phase = 0;
      spiDevices.push({
        kind: 'max6675_spi',
        dc: -1,
        cs: Number.isFinite(Number(s.cs)) ? Number(s.cs) : -1,
        bytes: 0,
        deselected: 0,
        selected: false,
        select() { phase = 0; },
        onByte(b) {
          phase++;
          if (phase === 1) return (word >> 8) & 0xff;
          if (phase === 2) { const v = word & 0xff; phase = 0; return v; }
          return 0x00;
        },
        summary() {
          return {
            kind: 'max6675_spi', cs_pin: this.cs, temperature_c: tempC,
            raw: raw, word: word, bytes: this.bytes, deselected: this.deselected,
          };
        },
      });
      continue;
    }
    if (s.kind === 'mcp3008') {
      // MCP3008 8-channel 10-bit ADC, also on the SPI peripheral: one conversion is three
      // transfers inside a single CS-low window - 0x01 (start), then 0x80 | channel << 4
      // (single-ended + channel), then a don't-care. This is the first SPI device that
      // *answers*: MISO returns a leading zero bit and then the 10-bit code, so a driver
      // reading `((hi & 0x03) << 8) | lo` gets it. The channel voltages are the solved
      // node voltages the app passes as `ain` (8 of them), scaled by `vref`; a channel
      // with no voltage reads 0. Only single-ended mode is modelled - a differential
      // request is answered with the channel's single-ended code and counted.
      const vref = Math.max(0.001, Number(s.vref ?? 5));
      const ain = Array.from({ length: 8 },
        (_, i) => Number((Array.isArray(s.ain) ? s.ain : [])[i] ?? 0));
      const reads = [];
      let phase = 0;
      let channel = 0;
      let code = 0;
      let differential = 0;
      const codeFor = (ch) => Math.max(0, Math.min(1023,
        Math.round((Math.max(0, Math.min(vref, ain[ch])) / vref) * 1023)));
      spiDevices.push({
        kind: 'mcp3008',
        dc: -1,
        cs: Number.isFinite(Number(s.cs)) ? Number(s.cs) : -1,
        bytes: 0,
        deselected: 0,
        selected: false,
        select() { phase = 0; }, // each CS-low window frames one conversion
        onByte(b) {
          const step = phase % 3;
          phase++;
          if (step === 0) return 0x00; // the start byte is clocked in, nothing is clocked out
          if (step === 1) {
            if ((b & 0x80) === 0) differential++;
            channel = (b >> 4) & 0x07;
            code = codeFor(channel);
            return (code >> 8) & 0x03; // leading zero bit, then result bits 9 and 8
          }
          reads.push({
            channel, code, volts: Math.round((code / 1023) * vref * 1e6) / 1e6,
          });
          return code & 0xff;
        },
        summary() {
          return {
            kind: 'mcp3008', cs_pin: this.cs, vref,
            ain: ain.map((v) => Math.round(v * 1e6) / 1e6),
            reads, conversions: reads.length, differential_requests: differential,
            bytes: this.bytes, deselected: this.deselected,
          };
        },
      });
      continue;
    }
    const addr = Number(s.address) & 0x7f;
    if (s.kind === 'pcf8574') {
      let state = Number(s.state ?? 0) & 0xff;
      const inputs = Number(s.inputs ?? 0) & 0xff;
      map.set(addr, {
        kind: 'pcf8574',
        writeByte(b) { state = b & 0xff; },
        readByte() { return state & ~inputs & 0xff; },
        summary: () => ({ kind: 'pcf8574', address: addr, state, read: state & ~inputs & 0xff }),
      });
    } else if (s.kind === 'eeprom') {
      const size = Math.max(1, Number(s.size ?? 256));
      const mem = new Uint8Array(size);
      if (Array.isArray(s.init)) {
        for (let i = 0; i < Math.min(size, s.init.length); i++) mem[i] = Number(s.init[i]) & 0xff;
      }
      let ptr = 0;
      let hi = null;
      let data = false;
      map.set(addr, {
        kind: 'eeprom',
        onStart(write) { if (write) { hi = null; data = false; } },
        writeByte(b) {
          b &= 0xff;
          if (data) { mem[ptr % size] = b; ptr = (ptr + 1) % size; }
          else if (hi === null) { hi = b; }
          else { ptr = ((hi << 8) | b) % size; hi = null; data = true; }
        },
        readByte() { const v = mem[ptr % size]; ptr = (ptr + 1) % size; return v; },
        summary: () => ({ kind: 'eeprom', address: addr, size, pointer: ptr, mem: Array.from(mem) }),
      });
    } else if (s.kind === 'pcf8591') {
      const vref = Math.max(0.001, Number(s.vref ?? 5));
      const ain = [0, 1, 2, 3].map((i) => Number((Array.isArray(s.ain) ? s.ain : [])[i] ?? 0));
      const code8 = (v) => Math.max(0, Math.min(255, Math.round((Math.max(0, Math.min(vref, v)) / vref) * 255)));
      let control = 0;
      let channel = 0;
      let dac = 0;
      let first = true;
      map.set(addr, {
        kind: 'pcf8591',
        onStart(write) { if (write) first = true; },
        writeByte(b) {
          b &= 0xff;
          if (first) { control = b; channel = b & 3; first = false; }
          else if (control & 0x40) { dac = b; }
        },
        readByte() {
          const v = code8(ain[channel]);
          if (control & 0x04) channel = (channel + 1) & 3;
          return v;
        },
        summary: () => ({
          kind: 'pcf8591', address: addr, control, channel,
          ain: ain.map((v) => Math.round(v * 1e6) / 1e6),
          read: code8(ain[channel]), dac,
          aout: Math.round((dac / 255) * vref * 1e6) / 1e6,
        }),
      });
    } else if (s.kind === 'mcp4725') {
      // MCP4725 12-bit I2C DAC: write-only (nothing to read back, so a read returns 0x00).
      // A write transaction carries the general write command in its first byte
      // (0x40 = write the DAC register, 0x60 = the DAC register and its EEPROM, with the
      // power-down mode in bits 1..0) followed by two data bytes carrying the 12-bit code
      // in their top 12 bits, so code = (d1 << 4) | (d2 >> 4). The output is VDD-referenced:
      // vout = vref * code / 4096, and the power-down code is reported rather than applied
      // (the netlist models it, see the catalog notes). Only the general write command is
      // decoded - the fast-mode encoding is not (an unrecognised first byte is counted).
      const vref = Math.max(0.001, Number(s.vref ?? 5));
      const PD_OHMS = [0, 1000, 100000, 500000];
      let code = 0;
      let powerDown = 0;
      let command = 0;
      let writes = 0;
      let eepromWrites = 0;
      let unrecognised = 0;
      let first = true;
      let pendingHi = 0;
      let data = 0;
      map.set(addr, {
        kind: 'mcp4725',
        onStart(write) { if (write) { first = true; data = 0; } },
        writeByte(b) {
          b &= 0xff;
          if (first) {
            first = false;
            if ((b & 0x60) === 0x40 || (b & 0x60) === 0x60) {
              command = b;
              powerDown = b & 0x03;
              if ((b & 0x60) === 0x60) eepromWrites++;
              return;
            }
            unrecognised++; // e.g. a fast-mode command byte: not decoded
            data = 9;       // ignore the rest of this transaction
            return;
          }
          if (data === 0) { pendingHi = b; data = 1; return; }
          if (data === 1) {
            code = ((pendingHi << 4) | (b >> 4)) & 0x0fff;
            powerDown = command & 0x03;
            writes++;
            data = 2;
            return;
          }
          // data === 2: the optional third data byte carries the EEPROM power-down bits.
        },
        readByte() { return 0x00; },
        summary: () => ({
          kind: 'mcp4725', address: addr, command, writes, eeprom_writes: eepromWrites,
          unrecognised, code, power_down: powerDown,
          power_down_ohms: PD_OHMS[powerDown] ?? 0, vref,
          volts: Math.round((code / 4096) * vref * 1e6) / 1e6,
        }),
      });
    } else if (s.kind === 'lcd1602') {
      // HD44780 character LCD behind a PCF8574 I2C backpack (bit0=RS, bit1=RW,
      // bit2=E, bit3=backlight, bits4-7=D4..D7). We latch a nibble on the E falling
      // edge and pair two nibbles into a byte (4-bit mode), then track DDRAM.
      const cols = Math.max(1, Number(s.cols ?? 16));
      const rows = Math.max(1, Number(s.rows ?? 2));
      const ddram = new Array(cols * rows).fill(0x20);
      let cursor = 0;
      let pending = null;
      let prevE = 0;
      let inCgram = false;
      const addrToIndex = (a) => {
        const line = a >= 0x40 ? 1 : 0;
        const col = a - (line ? 0x40 : 0x00);
        const idx = line * cols + col;
        return idx >= 0 && idx < cols * rows ? idx : cursor;
      };
      const apply = (byte, rs) => {
        if (rs) {
          if (!inCgram) { ddram[cursor] = byte & 0xff; cursor = (cursor + 1) % (cols * rows); }
          return;
        }
        if (byte & 0x80) { cursor = addrToIndex(byte & 0x7f); inCgram = false; }
        else if (byte === 0x01) { ddram.fill(0x20); cursor = 0; inCgram = false; }
        else if (byte === 0x02) { cursor = 0; inCgram = false; }
        else if (byte & 0x40) { inCgram = true; }
      };
      map.set(addr, {
        kind: 'lcd1602',
        writeByte(state) {
          state &= 0xff;
          const e = (state >> 2) & 1;
          if (prevE === 1 && e === 0) {
            const data = (state >> 4) & 0x0f;
            if (pending === null) pending = data;
            else { const byte = (pending << 4) | data; pending = null; apply(byte, state & 1); }
          }
          prevE = e;
        },
        readByte() { return 0xff; },
        summary: () => {
          const lines = [];
          for (let r = 0; r < rows; r++) {
            lines.push(ddram.slice(r * cols, r * cols + cols).map((c) => String.fromCharCode(c)).join(''));
          }
          return { kind: 'lcd1602', address: addr, cols, rows, cursor, lines };
        },
      });
    } else if (s.kind === 'mpu6050') {
      // MPU-6050 IMU register file: the first byte of a write transaction sets the
      // register pointer, further bytes write and auto-increment; reads return the
      // register at the pointer and auto-increment. Sample values come from params
      // (AFS_SEL=0 -> 16384 LSB/g, FS_SEL=0 -> 131 LSB/(deg/s), temp 340 LSB/degC).
      const regs = new Uint8Array(0x80);
      const toI16 = (v) => {
        const n = Math.max(-32768, Math.min(32767, Math.round(v)));
        return n < 0 ? n + 0x10000 : n;
      };
      const put16 = (a, raw) => {
        regs[a & 0x7f] = (raw >> 8) & 0xff;
        regs[(a + 1) & 0x7f] = raw & 0xff;
      };
      const rd16 = (a) => {
        const v = ((regs[a & 0x7f] << 8) | regs[(a + 1) & 0x7f]) & 0xffff;
        return v >= 0x8000 ? v - 0x10000 : v;
      };
      put16(0x3b, toI16(Number(s.ax ?? 0) * 16384));
      put16(0x3d, toI16(Number(s.ay ?? 0) * 16384));
      put16(0x3f, toI16(Number(s.az ?? 0) * 16384));
      put16(0x41, toI16((Number(s.temp_c ?? 25) - 36.53) * 340));
      put16(0x43, toI16(Number(s.gx ?? 0) * 131));
      put16(0x45, toI16(Number(s.gy ?? 0) * 131));
      put16(0x47, toI16(Number(s.gz ?? 0) * 131));
      regs[0x75] = Number(s.who_am_i ?? 0x68) & 0xff;
      let ptr = 0;
      let first = true;
      map.set(addr, {
        kind: 'mpu6050',
        onStart(write) { if (write) first = true; },
        writeByte(b) {
          b &= 0xff;
          if (first) { ptr = b & 0x7f; first = false; }
          else { regs[ptr & 0x7f] = b; ptr = (ptr + 1) & 0x7f; }
        },
        readByte() {
          const v = regs[ptr & 0x7f];
          ptr = (ptr + 1) & 0x7f;
          return v;
        },
        summary: () => ({
          kind: 'mpu6050', address: addr, who_am_i: regs[0x75], pointer: ptr,
          accel_raw: [rd16(0x3b), rd16(0x3d), rd16(0x3f)],
          gyro_raw: [rd16(0x43), rd16(0x45), rd16(0x47)],
          temp_c: Math.round((rd16(0x41) / 340 + 36.53) * 1000) / 1000,
        }),
      });
    } else if (s.kind === 'adxl345') {
      // ADXL345 register file (I2C): the same pointer + auto-increment shape as the
      // MPU-6050 with the ADXL345's own map. DEVID (0x00) is 0xE5. The sample g values
      // come from params, but their *scale* is whatever the firmware selected: DATA_FORMAT
      // (0x31) bit 3 is FULL_RES (3.9 mg/LSB, i.e. 256 LSB/g, at every range) and in
      // 10-bit mode the scale is 256 >> range LSB/g (so +/-4 g is 128 LSB/g). The DATA
      // registers (0x32..0x37) are little-endian 16-bit two's complement and are computed
      // from the live configuration, so writing DATA_FORMAT changes the counts a read
      // returns.
      const regs = new Uint8Array(0x40);
      regs[0x00] = 0xe5; // DEVID
      const ax = Number(s.ax ?? 0), ay = Number(s.ay ?? 0), az = Number(s.az ?? 1);
      const toU16 = (v) => {
        const n = Math.max(-32768, Math.min(32767, Math.round(v)));
        return n < 0 ? n + 0x10000 : n;
      };
      const rangeBits = () => regs[0x31] & 0x03;
      const lsbPerG = () => ((regs[0x31] & 0x08) ? 256 : (256 >> rangeBits()));
      const dataByte = (a) => {
        const g = a < 0x34 ? ax : (a < 0x36 ? ay : az);
        const raw = toU16(g * lsbPerG()) & 0xffff;
        return (a & 1) === 0 ? (raw & 0xff) : ((raw >> 8) & 0xff);
      };
      const rd16 = (a) => {
        const v = (dataByte(a) | (dataByte(a + 1) << 8)) & 0xffff;
        return v >= 0x8000 ? v - 0x10000 : v;
      };
      let ptr = 0;
      let first = true;
      map.set(addr, {
        kind: 'adxl345',
        onStart(write) { if (write) first = true; },
        writeByte(b) {
          b &= 0xff;
          if (first) { ptr = b & 0x3f; first = false; }
          else { regs[ptr & 0x3f] = b; ptr = (ptr + 1) & 0x3f; }
        },
        readByte() {
          const p = ptr & 0x3f;
          const v = (p >= 0x32 && p <= 0x37) ? dataByte(p) : regs[p];
          ptr = (ptr + 1) & 0x3f;
          return v;
        },
        summary: () => ({
          kind: 'adxl345', address: addr, devid: regs[0x00], pointer: ptr,
          data_format: regs[0x31], full_res: (regs[0x31] & 0x08) !== 0,
          range_g: [2, 4, 8, 16][rangeBits()], lsb_per_g: lsbPerG(),
          data_rate: regs[0x2c], power_ctl: regs[0x2d],
          accel_raw: [rd16(0x32), rd16(0x34), rd16(0x36)],
          accel_g: [rd16(0x32), rd16(0x34), rd16(0x36)]
            .map((raw) => Math.round((raw / lsbPerG()) * 1e6) / 1e6),
        }),
      });
    } else if (s.kind === 'ads1115') {
      // ADS1115 16-bit I2C ADC register file: four 16-bit registers selected by a pointer
      // (0x00 conversion, 0x01 config, 0x02 Lo_thresh, 0x03 Hi_thresh), each read and
      // written MSB first. The conversion is computed from the channel voltages the app
      // passes as `ain` (solved node voltages) and the settings the firmware *wrote* to the
      // config register: MUX 0..3 select the differential pairs and 4..7 select AIN0..3
      // against GND, and the PGA bits give +/-6.144/4.096/2.048/1.024/0.512/0.256 V full
      // scale (the reserved codes 6/7 are treated as 0.256 V). Conversion timing is not
      // modelled - the code is ready as soon as the config is written.
      const ain = Array.from({ length: 4 },
        (_, i) => Number((Array.isArray(s.ain) ? s.ain : [])[i] ?? 0));
      const DIFF_PAIRS = [[0, 1], [0, 3], [1, 3], [2, 3]];
      const hi = new Uint8Array(4);
      const lo = new Uint8Array(4);
      hi[1] = 0x85; lo[1] = 0x83; // the datasheet's power-up config (0x8583)
      const cfg16 = () => ((hi[1] << 8) | lo[1]) & 0xffff;
      const mux = () => (cfg16() >> 12) & 0x07;
      const pga = () => (cfg16() >> 9) & 0x07;
      const fullScale = () => [6.144, 4.096, 2.048, 1.024, 0.512, 0.256, 0.256, 0.256][pga()];
      const vdiff = () => {
        const m = mux();
        return m < 4 ? ain[DIFF_PAIRS[m][0]] - ain[DIFF_PAIRS[m][1]] : ain[m - 4];
      };
      const code = () => {
        const fs = fullScale();
        return Math.max(-32768, Math.min(32767, Math.round((vdiff() / fs) * 32768)));
      };
      const round6 = (v) => Math.round(v * 1e6) / 1e6;
      const reads = [];
      let ptr = 0;
      let phase = 0; // 0 = the register's MSB, 1 = its LSB (then the pointer advances)
      let first = true;
      const advance = () => { phase = 1 - phase; if (phase === 0) ptr = (ptr + 1) & 0x03; };
      map.set(addr, {
        kind: 'ads1115',
        onStart(write) { if (write) first = true; },
        writeByte(b) {
          b &= 0xff;
          if (first) { ptr = b & 0x03; phase = 0; first = false; return; }
          // The conversion register is read-only; the others are stored.
          if (ptr !== 0x00) {
            if (phase === 0) hi[ptr] = b; else lo[ptr] = b;
          }
          advance();
        },
        readByte() {
          let v;
          if (ptr === 0x00) {
            // One entry per conversion word read, recorded when its LSB completes the word
            // (so a driver that reads only the MSB is the documented blind spot).
            if (phase === 1) {
              reads.push({
                mux: mux(), pga: pga(), full_scale_v: fullScale(),
                code: code(), volts: round6((code() / 32768) * fullScale()),
              });
            }
            v = phase === 0 ? ((code() >> 8) & 0xff) : (code() & 0xff);
          } else {
            v = phase === 0 ? hi[ptr] : lo[ptr];
          }
          advance();
          return v;
        },
        summary: () => ({
          kind: 'ads1115', address: addr, config: cfg16(),
          mux: mux(), mux_mode: (mux() < 4 ? 'differential' : 'single-ended'),
          pga: pga(), full_scale_v: fullScale(),
          ain: ain.map(round6), reads, conversions: reads.length,
        }),
      });
    } else if (s.kind === 'ssd1306') {
      // SSD1306 OLED on I2C: each write transaction's first byte is a control byte
      // (bit6 = D/C: 0 = command, 1 = data) that tags the rest of the transaction; the
      // shared `makeSsd1306` core turns the tagged stream into GDDRAM.
      const cols = Math.max(1, Number(s.cols ?? 128));
      const nPages = Math.max(1, Number(s.pages ?? 8));
      const core = makeSsd1306(cols, nPages);
      let isData = false;
      let first = true;
      map.set(addr, {
        kind: 'ssd1306',
        onStart(write) { if (write) first = true; },
        writeByte(b) {
          b &= 0xff;
          if (first) { isData = (b & 0x40) !== 0; first = false; return; }
          if (isData) core.writeData(b);
          else core.writeCommand(b);
        },
        readByte() { return 0x00; },
        summary: () => ({ kind: 'ssd1306', address: addr, ...core.fields() }),
      });
    } else if (s.kind === 'tof_vl53l0x') {
      // VL53L0X time-of-flight: a tiny register file. Chip ID (0xEE) at 0xC0 and the
      // measured distance in millimetres at 0x1A..0x1B (16-bit, MSB first), with a
      // pointer + auto-increment shape like the MPU-6050. Only the result registers and
      // the model ID are modelled; calibration, ranging modes and the interrupt/GPIO
      // behaviour are not.
      const dist = Math.max(0, Math.min(2000, Number(s.distance_mm ?? 300)));
      const regs = new Uint8Array(0x100);
      regs[0xc0] = 0xee; // model ID
      regs[0x1a] = (dist >> 8) & 0xff;
      regs[0x1b] = dist & 0xff;
      let ptr = 0;
      let first = true;
      map.set(addr, {
        kind: 'tof_vl53l0x',
        onStart(write) { if (write) first = true; },
        writeByte(b) {
          b &= 0xff;
          if (first) { ptr = b & 0xff; first = false; }
          else { regs[ptr & 0xff] = b; ptr = (ptr + 1) & 0xff; }
        },
        readByte() {
          const v = regs[ptr & 0xff];
          ptr = (ptr + 1) & 0xff;
          return v;
        },
        summary: () => ({
          kind: 'tof_vl53l0x', address: addr, model_id: regs[0xc0],
          distance_mm: dist, pointer: ptr,
        }),
      });
    } else if (s.kind === 'ccs811') {
      // CCS811 eCO2/TVOC: a small register file. Chip ID (0x81) at 0x20, status at 0x00,
      // eCO2 (ppm) at 0x02..0x03 and TVOC (ppb) at 0x04..0x05 (both 16-bit MSB first).
      // Pointer + auto-increment like the MPU-6050. Only these registers are modelled.
      const eco2 = Math.max(400, Math.min(8192, Number(s.eco2 ?? 400)));
      const tvoc = Math.max(0, Math.min(1187, Number(s.tvoc ?? 0)));
      const regs = new Uint8Array(0x30);
      regs[0x20] = 0x81;
      regs[0x02] = (eco2 >> 8) & 0xff; regs[0x03] = eco2 & 0xff;
      regs[0x04] = (tvoc >> 8) & 0xff; regs[0x05] = tvoc & 0xff;
      regs[0x00] = 0x90; // APP_VALID + DATA_READY
      let ptr = 0;
      let first = true;
      map.set(addr, {
        kind: 'ccs811',
        onStart(write) { if (write) first = true; },
        writeByte(b) {
          b &= 0xff;
          if (first) { ptr = b & 0xff; first = false; }
          else { regs[ptr & 0xff] = b; ptr = (ptr + 1) & 0xff; }
        },
        readByte() {
          const v = regs[ptr & 0xff];
          ptr = (ptr + 1) & 0xff;
          return v;
        },
        summary: () => ({
          kind: 'ccs811', address: addr, chip_id: regs[0x20],
          eco2, tvoc, status: regs[0x00], pointer: ptr,
        }),
      });
    } else if (s.kind === 'scd40') {
      // SCD40 CO2 sensor: command-driven like the SHT31. Command 0x21B1 triggers a
      // single-shot measurement; a read returns 9 bytes - CO2 (MSB/LSB + CRC), temp
      // (MSB/LSB + CRC), humidity (MSB/LSB + CRC) - using the same CRC-8 (poly 0x31,
      // init 0xFF). Values come from `co2`/`temp_c`/`humidity`.
      const crc8 = (a, b) => {
        let crc = 0xff;
        for (const byte of [a, b]) {
          crc ^= byte & 0xff;
          for (let i = 0; i < 8; i++) {
            crc = crc & 0x80 ? ((crc << 1) ^ 0x31) & 0xff : (crc << 1) & 0xff;
          }
        }
        return crc;
      };
      const co2 = Math.max(0, Math.min(40000, Number(s.co2 ?? 400)));
      const tempC = Math.max(-10, Math.min(60, Number(s.temp_c ?? 23)));
      const humPct = Math.max(0, Math.min(100, Number(s.humidity ?? 48)));
      const tempRaw = Math.max(0, Math.min(65535, Math.round(((tempC + 45) / 175) * 65535)));
      const humRaw = Math.max(0, Math.min(65535, Math.round((humPct / 100) * 65535)));
      const out = [
        (co2 >> 8) & 0xff, co2 & 0xff, 0,
        (tempRaw >> 8) & 0xff, tempRaw & 0xff, 0,
        (humRaw >> 8) & 0xff, humRaw & 0xff, 0,
      ];
      out[2] = crc8(out[0], out[1]);
      out[5] = crc8(out[3], out[4]);
      out[8] = crc8(out[6], out[7]);
      let idx = 0;
      let cmdHi = null;
      let command = -1;
      let reads = 0;
      map.set(addr, {
        kind: 'scd40',
        onStart(write) { if (write) cmdHi = null; else { idx = 0; reads++; } },
        writeByte(b) {
          b &= 0xff;
          if (cmdHi === null) { cmdHi = b; return; }
          command = (cmdHi << 8) | b;
          cmdHi = null;
        },
        readByte() {
          const v = out[idx] ?? 0xff;
          idx = (idx + 1) % out.length;
          return v;
        },
        summary: () => ({
          kind: 'scd40', address: addr, command, co2, temp_c: tempC,
          humidity: humPct, reads,
        }),
      });
    } else if (s.kind === 'bme280' || s.kind === 'bmp280') {
      // BME280/BMP280 environmental sensor: a small register file. Chip ID at 0xD0
      // (0x60 for BME280, 0x58 for BMP280), status at 0xF3, and the raw data at
      // 0xF7..0xFE (pressure 3 bytes, temperature 3 bytes, humidity 2 bytes for the BME280).
      // Only the chip ID and the raw data registers are modelled; the calibration
      // coefficients (0x88..0xA1, 0xE1..0xE7) are zeroed, so a driver that applies the
      // datasheet compensation will compute a (consistent but uncalibrated) value. The
      // values come from `temp_c`/`humidity`/`pressure`.
      const isBme = s.kind === 'bme280';
      const chipId = isBme ? 0x60 : 0x58;
      const tempC = Number(s.temp_c ?? 23);
      const humPct = Number(s.humidity ?? 48);
      const pressHpa = Number(s.pressure ?? 1013.25);
      const tempRaw = Math.max(0, Math.min(0xfffff, Math.round(((tempC + 45) / 175) * 0xfffff));
      const pressRaw = Math.max(0, Math.min(0xfffff, Math.round((pressHpa / 1013.25) * 0x60000)));
      const humRaw = Math.max(0, Math.min(0xffff, Math.round((humPct / 100) * 0xffff)));
      const regs = new Uint8Array(0x100);
      regs[0xd0] = chipId;
      regs[0xf7] = (pressRaw >> 12) & 0xff;
      regs[0xf8] = (pressRaw >> 4) & 0xff;
      regs[0xf9] = (pressRaw & 0x0f) << 4;
      regs[0xfa] = (tempRaw >> 12) & 0xff;
      regs[0xfb] = (tempRaw >> 4) & 0xff;
      regs[0xfc] = (tempRaw & 0x0f) << 4;
      if (isBme) {
        regs[0xfd] = (humRaw >> 8) & 0xff;
        regs[0xfe] = humRaw & 0xff;
      }
      regs[0xf3] = 0x00; // measuring done
      let ptr = 0;
      let first = true;
      map.set(addr, {
        kind: s.kind,
        onStart(write) { if (write) first = true; },
        writeByte(b) {
          b &= 0xff;
          if (first) { ptr = b & 0xff; first = false; }
          else { regs[ptr & 0xff] = b; ptr = (ptr + 1) & 0xff; }
        },
        readByte() {
          const v = regs[ptr & 0xff];
          ptr = (ptr + 1) & 0xff;
          return v;
        },
        summary: () => ({
          kind: s.kind, address: addr, chip_id: chipId,
          temp_c: tempC, humidity: humPct, pressure_hpa: pressHpa,
          pointer: ptr,
        }),
      });
    } else if (s.kind === 'sht31') {
      // SHT31 temperature/humidity: 16-bit commands (0x2400/0x2406/0x240b measure,
      // 0xf32d soft reset, 0x306d/0xe000 heater) and a 6-byte read of
      // temperature + CRC, humidity + CRC. The CRC-8 is the part's own (poly 0x31,
      // init 0xFF). Values come from `temp_c`/`humidity`; `corrupt_crc` flips the
      // temperature checksum so a driver's validation path can be exercised.
      const crc8 = (a, b) => {
        let crc = 0xff;
        for (const byte of [a, b]) {
          crc ^= byte & 0xff;
          for (let i = 0; i < 8; i++) {
            crc = crc & 0x80 ? ((crc << 1) ^ 0x31) & 0xff : (crc << 1) & 0xff;
          }
        }
        return crc;
      };
      const tempC = Math.max(-40, Math.min(125, Number(s.temp_c ?? 23)));
      const humPct = Math.max(0, Math.min(100, Number(s.humidity ?? 48)));
      const tempRaw = Math.max(0, Math.min(65535, Math.round(((tempC + 45) / 175) * 65535)));
      const humRaw = Math.max(0, Math.min(65535, Math.round((humPct / 100) * 65535)));
      const corrupt = Number(s.corrupt_crc ?? 0) !== 0;
      const out = [
        (tempRaw >> 8) & 0xff, tempRaw & 0xff, 0,
        (humRaw >> 8) & 0xff, humRaw & 0xff, 0,
      ];
      out[2] = corrupt ? crc8(out[0], out[1]) ^ 0xff : crc8(out[0], out[1]);
      out[5] = crc8(out[3], out[4]);
      let idx = 0;
      let cmdHi = null;
      let command = -1;
      let reads = 0;
      let resets = 0;
      let heater = false;
      map.set(addr, {
        kind: 'sht31',
        onStart(write) { if (write) cmdHi = null; else { idx = 0; reads++; } },
        writeByte(b) {
          b &= 0xff;
          if (cmdHi === null) { cmdHi = b; return; }
          command = (cmdHi << 8) | b;
          cmdHi = null;
          if (command === 0xf32d) resets++;
          else if (command === 0x306d) heater = true;
          else if (command === 0xe000) heater = false;
        },
        readByte() {
          const v = out[idx] ?? 0xff;
          idx = (idx + 1) % out.length;
          return v;
        },
        summary: () => ({
          kind: 'sht31', address: addr, command,
          temp_c: Math.round(tempC * 1000) / 1000,
          humidity: Math.round(humPct * 1000) / 1000,
          temp_raw: tempRaw, humidity_raw: humRaw,
          temp_crc: out[2], humidity_crc: out[5], crc_ok: !corrupt,
          heater, reads, resets,
        }),
      });
    }
  }
  return map;
}

const devices = buildDevices();
const i2c = [];
class TraceTWI {
  constructor(twi) {
    this.twi = twi;
    this.txn = null;
    this.dev = null;
  }
  start(repeated) {
    this._flush();
    this.txn = { repeated: !!repeated, address: null, write: null, bytes: [] };
    this.twi.completeStart();
  }
  stop() {
    this._flush();
    if (this.dev && this.dev.onStop) this.dev.onStop();
    this.dev = null;
    this.twi.completeStop();
  }
  connectToSlave(address, write) {
    const addr = address & 0x7f;
    if (this.txn) {
      this.txn.address = addr;
      this.txn.write = !!write;
    }
    this.dev = devices.get(addr) || null;
    if (this.dev && this.dev.onStart) this.dev.onStart(!!write);
    this.twi.completeConnect(true);
  }
  writeByte(value) {
    const b = value & 0xff;
    if (this.txn) this.txn.bytes.push(b);
    if (this.dev) this.dev.writeByte(b);
    this.twi.completeWrite(true);
  }
  readByte(ack) {
    const b = this.dev ? this.dev.readByte() : 0xff;
    if (this.txn) this.txn.bytes.push(b);
    this.twi.completeRead(b);
  }
  _flush() {
    if (this.txn && this.txn.address !== null) i2c.push(this.txn);
    this.txn = null;
  }
  flush() {
    this._flush();
  }
}
const twi = new AVRTWI(cpu, twiConfig, F_CPU);
const twiTracer = new TraceTWI(twi);
twi.eventHandler = twiTracer;

// SPI traffic monitor: record MOSI bytes; MISO returns 0x00 unless an SPI device answers.
// Any SPI device (CF_DEVICES) is fed each transfer live, tagged by its DC/CS line levels -
// the two lines a driver uses to say "this byte is a command / data" and "you are selected".
// The raw trace is useful for small sketches, but a full-screen frame is 150k+ bytes, so the
// reply carries at most CF_SPI_LIMIT (default 4096) bytes and always the true total in
// `spi_byte_count` - a trimmed trace is never passed off as the whole one.
const SPI_LIMIT = Math.max(0, Number(process.env.CF_SPI_LIMIT ?? 4096));
const spi = [];
const spiDevice = new AVRSPI(cpu, spiConfig, F_CPU);
spiDevice.onByte = (value) => {
  const b = value & 0xff;
  spi.push(b);
  // MISO is shared: whichever device is selected drives it (an unselected one ignores
  // the byte). The CS high -> low edge is where a device starts a fresh transaction.
  let miso = 0x00;
  for (const d of spiDevices) {
    if (d.cs >= 0 && levelOfPin(d.cs) === 1) {
      d.deselected++;
      d.selected = false;
      continue;
    }
    if (!d.selected) {
      d.selected = true;
      if (d.select) d.select();
    }
    d.bytes++;
    miso |= d.onByte(b) & 0xff;
  }
  spiDevice.completeTransfer(miso);
};

// ADC: analog inputs. `CF_ADC` is a JSON object mapping ADC channel -> volts, e.g.
// {"0":2.5} makes analogRead(A0) read a 2.5 V input (device/circuit -> firmware
// analog feedback). Channels not listed read 0 V. Reference is AVcc (default 5 V).
const adc = new AVRADC(cpu, adcConfig);
function loadAdcChannels() {
  const raw = process.env.CF_ADC;
  const out = {};
  if (!raw) return out;
  let spec;
  try {
    spec = JSON.parse(raw);
  } catch {
    return out;
  }
  for (const [ch, v] of Object.entries(spec ?? {})) {
    const channel = Number(ch);
    const volts = Number(v);
    if (Number.isFinite(channel) && Number.isFinite(volts)) {
      adc.channelValues[channel] = volts;
      out[channel] = volts;
    }
  }
  return out;
}
const adcChannels = loadAdcChannels();

const UNO_PIN = {
  B0: 8, B1: 9, B2: 10, B3: 11, B4: 12, B5: 13,
  C0: 14, C1: 15, C2: 16, C3: 17, C4: 18, C5: 19,
  D0: 0, D1: 1, D2: 2, D3: 3, D4: 4, D5: 5, D6: 6, D7: 7,
};

const transitions = [];
for (const [letter, port] of Object.entries(ports)) {
  port.addListener((value, oldValue) => {
    const changed = value ^ oldValue;
    for (let bit = 0; bit < 8; bit++) {
      if (changed & (1 << bit)) {
        const key = `${letter}${bit}`;
        transitions.push({
          t_ms: Math.round((cpu.cycles / F_CPU) * 1000 * 1000) / 1000,
          port: letter,
          bit,
          digital_pin: UNO_PIN[key] ?? null,
          level: (value >> bit) & 1,
        });
      }
    }
  });
}

// ---- Timing-driven pin devices ----------------------------------------------
// Four kinds, all driving MCU *input* pins:
//  * HC-SR04: the MCU drives TRIG; on its falling edge (after a >= 5 us high pulse)
//    the sensor waits a short propagation delay and then drives ECHO high for a
//    distance-proportional time (58 us per cm round-trip), so pulseIn(ECHO) measures it.
//  * Rotary encoder: drives the A/B quadrature pair through a Gray sequence, one pin
//    changing per count, so a polling decoder sees every step.
//  * DHT11/DHT22: a *bidirectional* one-wire part. The MCU pulls the line low as a start
//    signal and releases it; the harness then plays the sensor's response bit train at
//    datasheet timings (80 us low + 80 us high handshake, then 40 bits of 50 us low with
//    a 27 us or 70 us high), sub-100 us pulses that a bit-banged reader times with
//    micros(). The line is held high by the module pull-up whenever the MCU releases it.
//  * DS18B20: a *bidirectional 1-Wire slave* over real bit slots - the master pulls the line
//    low to start every bit and releases it, and the slave both decodes the master's slots
//    (by low time) and drives the line itself to serve bytes. See its case below.
// Edges are queued and applied from the run loop (never from inside the GPIO write,
// so we don't re-enter the port model).
const pinByNumber = new Map();
for (const [key, pin] of Object.entries(UNO_PIN)) {
  pinByNumber.set(pin, { port: key[0], bit: Number(key[1]) });
}
const scheduledPins = [];
// 1-Wire slaves are polled from the run loop instead of hooking the port: their edges depend
// on the *master's* DDR/PORT registers (the slave's own drive changes the line level too),
// and polling the registers each instruction is both simpler and sub-microsecond accurate.
const wirePolls = [];
const ECHO_PROPAGATION_US = 200;
const QUAD_SEQ = [[0, 0], [1, 0], [1, 1], [0, 1]]; // (A,B) for one CW detent

// DHT payload bytes for the configured model, in wire order (MSB first).
function dhtBytes(model, tempC, humidity) {
  if (model === 'dht11') {
    const hum = Math.max(0, Math.min(100, Math.round(humidity)));
    const tmp = Math.max(0, Math.min(100, Math.round(tempC)));
    return [hum, 0, tmp, 0, (hum + tmp) & 0xff];
  }
  const hum = Math.round(Math.abs(humidity) * 10) & 0xffff; // tenths of %
  let tmp = Math.round(Math.abs(tempC) * 10) & 0x7fff; // tenths of degC, bit15 = sign
  if (tempC < 0) tmp |= 0x8000;
  const b = [(hum >> 8) & 0xff, hum & 0xff, (tmp >> 8) & 0xff, tmp & 0xff];
  return [b[0], b[1], b[2], b[3], (b[0] + b[1] + b[2] + b[3]) & 0xff];
}

// Dallas/Maxim CRC-8: reflected polynomial 0x8C, initial value 0, no final XOR - the same
// algorithm the 1-Wire library uses (its catalogue check value for "123456789" is 0xA1). It
// checksums both the DS18B20's 64-bit ROM and its 9-byte scratchpad, so the model serves
// values a real driver's CRC check accepts.
function dallasCrc8(bytes) {
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
  return crc & 0xff;
}

// The ROM this model serves: family code 0x28 (DS18B20) plus a fixed serial. A real part has
// a unique laser ROM and the app passes no ROM parameter (catalog parameters are numeric),
// so one fixed *CRC-valid* ID is served and the verifier recomputes the checksum.
const DS_ROM_BODY = [0x28, 0x8a, 0x1b, 0x2c, 0x3d, 0x4e, 0x5f];
function dsRom() {
  return [...DS_ROM_BODY, dallasCrc8(DS_ROM_BODY)];
}

// The DS18B20's 9-byte scratchpad for a temperature at the resolution the config byte
// selects: [temp LSB, temp MSB, TH, TL, config, 0xFF, 0xFF, 0xFF, CRC8]. The temperature is a
// 12-bit two's-complement count of 0.0625 degC; a coarser resolution clears the unused low
// bits (the part does the same), so a 10-bit read of 23.1 C reports 23.0 C.
function dsScratchpad(tempC, alarmHigh, alarmLow, config) {
  const resolution = 9 + ((config >> 5) & 0x03);
  let raw = Math.round(tempC / 0.0625) & 0xffff;
  const dropped = 12 - resolution;
  if (dropped > 0) raw = (raw & ~((1 << dropped) - 1)) & 0xffff;
  const body = [
    raw & 0xff, (raw >> 8) & 0xff, alarmHigh & 0xff, alarmLow & 0xff, config & 0xff,
    0xff, 0xff, 0xff,
  ];
  return { bytes: [...body, dallasCrc8(body)], raw, resolution };
}

for (const d of pinDevices) {
  if (d.kind === 'encoder') {
    const a = pinByNumber.get(d.a);
    const b = pinByNumber.get(d.b);
    if (!a || !b) { d.error = 'a/b pin out of range'; continue; }
    if (a.port === b.port && a.bit === b.bit) { d.error = 'a and b must be different pins'; continue; }
    // Walk the canonical one-bit-at-a-time Gray cycle forwards or backwards from the
    // power-on state (A,B) = (0,0), so exactly one pin changes per count.
    d.edges = [];
    let phase = 0;
    let tUs = d.start_us;
    for (let i = 0; i < d.counts; i++) {
      const from = QUAD_SEQ[phase];
      phase = (phase + d.direction + 4) & 3;
      const to = QUAD_SEQ[phase];
      tUs += d.step_us;
      const at = Math.round((tUs / 1e6) * F_CPU);
      if (to[0] !== from[0]) scheduledPins.push({ at, port: a.port, bit: a.bit, level: to[0] });
      if (to[1] !== from[1]) scheduledPins.push({ at, port: b.port, bit: b.bit, level: to[1] });
      d.edges.push({ t_us: tUs, state: to[0] * 2 + to[1] });
    }
    scheduledPins.sort((x, y) => x.at - y.at);
    continue;
  }
  if (d.kind === 'dht') {
    const p = pinByNumber.get(d.pin);
    if (!p) { d.error = 'pin out of range'; continue; }
    const port = ports[p.port];
    port.setPin(p.bit, true); // module pull-up: the line idles high when released
    const bytes = dhtBytes(d.model, d.temp_c, d.humidity);
    const bits = [];
    for (const b of bytes) for (let i = 7; i >= 0; i--) bits.push((b >> i) & 1);
    d.reads = [];
    const scheduleResponse = (t0Cycles) => {
      let us = 20; // the sensor waits, then pulls the line low for 80 us
      const add = (atUs, level) =>
        scheduledPins.push({
          at: t0Cycles + Math.round((atUs / 1e6) * F_CPU), port: p.port, bit: p.bit, level,
        });
      add(us, 0); us += 80;
      add(us, 1); us += 80;
      for (const bit of bits) {
        add(us, 0); us += 50; // each bit: 50 us low ...
        add(us, 1); us += bit ? 70 : 27; // ... then 27 us (0) or 70 us (1) high
      }
      add(us, 0); us += 50;
      add(us, 1); // release: back to idle high
      scheduledPins.sort((x, y) => x.at - y.at);
      d.reads.push({ model: d.model, temp_c: d.temp_c, humidity: d.humidity, bytes, total_us: us });
    };
    // Trigger on the line going from driven-low (the start signal) to released. The port
    // listener catches PORT writes; the DDR hook catches pinMode() changes (releasing the
    // line with the pull-up), so both driver styles are supported.
    let lowSince = null;
    const check = () => {
      const st = port.pinState(p.bit); // 0 = PinState.Low (driven low)
      if (st === 0) {
        if (lowSince === null) lowSince = cpu.cycles;
        return;
      }
      if (lowSince === null) return;
      const lowUs = ((cpu.cycles - lowSince) / F_CPU) * 1e6;
      lowSince = null;
      if (lowUs < 500 || d.reads.length >= 4) return;
      scheduleResponse(cpu.cycles);
    };
    port.addListener(() => check());
    const ddrAddr = port.portConfig.DDR;
    const prevDdrHook = cpu.writeHooks[ddrAddr];
    cpu.writeHooks[ddrAddr] = (value, oldValue, addr, mask) => {
      if (prevDdrHook) prevDdrHook(value, oldValue, addr, mask);
      check();
      return true;
    };
    continue;
  }
  if (d.kind === 'ds18b20') {
    // DS18B20 1-Wire digital thermometer: a *bidirectional bit-slot* slave, which the DHT's
    // start-pulse model cannot express. 1-Wire has one wire and one master: for every bit the
    // master pulls the line low and releases it (the pull-up then takes it high), and the
    // slave tells slots apart by the master's *low time* - a low of ~60 us is a 0, a short
    // low is a 1 or a read slot - and, when it is serving a byte, drives the line itself
    // right after the master's release so the master samples the bit ~15 us later.
    //
    // The master's edges come from its DDR/PORT registers, not from the line level (the
    // slave drives the same line), so a poll in the run loop watches those registers and no
    // listener is hijacked. A reset (any low of >= 480 us) always answers with a presence
    // pulse and restarts the transaction - even for a device muted by a failed 0x55 MATCH
    // ROM, exactly as a real part does. The commands the model implements (READ ROM, SKIP
    // ROM, MATCH ROM, CONVERT T, READ/WRITE SCRATCHPAD, COPY/RECALL) are decoded and
    // reported; SEARCH ROM/ALARM SEARCH are counted, not modelled.
    const p = pinByNumber.get(d.pin);
    if (!p) { d.error = 'pin out of range'; continue; }
    const port = ports[p.port];
    const bitMask = 1 << p.bit;
    const PIN_REG = port.portConfig.PIN;
    d.rom = dsRom();
    port.setPin(p.bit, true); // bus pull-up: the line idles high whenever both ends release
    if (d.absent) continue;   // pull-up only: no part answers, so the master sees no presence
    const RESET_US = 480;     // a low at least this long is a reset pulse
    // A write slot's low is 60-120 us for a 0 and 1-15 us for a 1, and the datasheet lets the
    // slave sample anywhere 15-60 us after the falling edge, so the model samples at 40 us:
    // far from both ends of the spec. (A stray interrupt can stretch a 1 by a few us - the
    // slot log of a real 16 MHz run shows 12-13 us for 1s and 65-68 us for 0s - so the
    // threshold must not sit right next to the fast case.)
    const ZERO_US = 40;
    const PRESENCE_DELAY_US = 30;
    const PRESENCE_US = 120;
    const BIT_HOLD_US = 60;   // how long a served 0 is held low
    let master = null;        // what the *master* does with the line: low | high | release
    let tLow = 0;
    let mode = 'command';     // command | match | config | output | muted
    let rxByte = 0, rxBits = 0;
    let matchBytes = [];
    let configBytes = [];
    let out = [], outIndex = 0, outByte = 0, outBits = 0, outKind = '';
    const clearScheduled = () => {
      for (let i = scheduledPins.length - 1; i >= 0; i--) {
        const ev = scheduledPins[i];
        if (ev.port === p.port && ev.bit === p.bit) scheduledPins.splice(i, 1);
      }
    };
    const schedule = (atUs, level) => {
      scheduledPins.push({
        at: cpu.cycles + Math.round((atUs / 1e6) * F_CPU),
        port: p.port, bit: p.bit, level,
      });
      scheduledPins.sort((x, y) => x.at - y.at);
    };
    const beginOutput = (bytes, kind) => {
      out = bytes;
      outIndex = 0;
      outByte = bytes[0] ?? 0xff;
      outBits = 0;
      outKind = kind;
      mode = 'output';
    };
    // Serve the next bit (LSB first, as 1-Wire orders bytes): a 0 is held low long enough
    // for the master's sample, a 1 is just released. When the queue runs out the model keeps
    // answering 0xFF until the next reset, so an over-long read cannot be mistaken for a
    // command stream.
    const serveBit = () => {
      const bit = (outByte >> outBits) & 1;
      clearScheduled();
      if (bit) {
        port.setPin(p.bit, true);
      } else {
        port.setPin(p.bit, false);
        schedule(BIT_HOLD_US, 1);
      }
      outBits++;
      if (outBits < 8) return;
      outBits = 0;
      if (outIndex + 1 < out.length) {
        outIndex++;
        outByte = out[outIndex];
        return;
      }
      if (outKind === 'scratchpad') {
        const served = out.slice();
        d.reads.push({
          bytes: served,
          temp_c: d.temp_c,
          resolution: d.resolution,
          crc_ok: dallasCrc8(served.slice(0, 8)) === served[8],
        });
      }
      out = [0xff];
      outIndex = 0;
      outByte = 0xff;
    };
    const onReset = () => {
      d.resets++;
      d.presence++;
      mode = 'command';
      rxByte = 0;
      rxBits = 0;
      matchBytes = [];
      configBytes = [];
      out = [];
      outIndex = 0;
      outBits = 0;
      outKind = '';
      clearScheduled();
      port.setPin(p.bit, true);
      schedule(PRESENCE_DELAY_US, 0);
      schedule(PRESENCE_DELAY_US + PRESENCE_US, 1);
    };
    const onByte = (value) => {
      d.commands.push(value);
      if (mode === 'muted') return;
      if (mode === 'match') {
        matchBytes.push(value);
        if (matchBytes.length === 8) {
          const same = matchBytes.every((b, i) => b === d.rom[i]);
          if (same) {
            mode = 'command';
          } else {
            // A different ROM: a real part stays silent for the rest of the transaction.
            mode = 'muted';
            d.muted = true;
            port.setPin(p.bit, true);
          }
        }
        return;
      }
      if (mode === 'config') {
        configBytes.push(value);
        if (configBytes.length === 3) {
          d.alarm_high = configBytes[0];
          d.alarm_low = configBytes[1];
          d.config = configBytes[2];
          d.resolution = 9 + ((d.config >> 5) & 0x03);
          d.writes_config++;
          configBytes = [];
          mode = 'command';
        }
        return;
      }
      if (mode === 'output') return; // the master cannot write while we shift out
      switch (value) {
        case 0x33: beginOutput(d.rom, 'rom'); break; // READ ROM
        case 0xcc: break;                            // SKIP ROM: the next byte is a command
        case 0x55: mode = 'match'; matchBytes = []; break; // MATCH ROM
        case 0xec: d.search++; break;                // ALARM SEARCH: counted, not modelled
        case 0xf0: d.search++; break;                // SEARCH ROM: counted, not modelled
        case 0x44: d.converts++; break;              // CONVERT T: the payload is ready at once
        case 0xbe: {                                 // READ SCRATCHPAD
          const sp = dsScratchpad(d.temp_c, d.alarm_high, d.alarm_low, d.config);
          d.resolution = sp.resolution;
          beginOutput(sp.bytes, 'scratchpad');
          break;
        }
        case 0x4e: mode = 'config'; configBytes = []; break; // WRITE SCRATCHPAD (TH/TL/config)
        case 0x48: d.copies++; break;                // COPY SCRATCHPAD: nothing persists
        case 0xb8: d.recalls++; break;               // RECALL E2: nothing to recall
        default: d.unknown++; break;
      }
    };
    const poll = () => {
      const ddr = cpu.data[port.portConfig.DDR] & bitMask;
      const prt = cpu.data[port.portConfig.PORT] & bitMask;
      const now = ddr ? (prt ? 'high' : 'low') : 'release';
      if (now === master) return;
      const was = master;
      master = now;
      if (now === 'low') {
        tLow = cpu.cycles;
        return;
      }
      if (was !== 'low') return;
      const lowUs = ((cpu.cycles - tLow) / F_CPU) * 1e6;
      if (lowUs >= RESET_US) {
        onReset();
        return;
      }
      if (mode === 'output') {
        serveBit();
        return;
      }
      if (mode === 'muted') return;
      // A received bit: the master holds the line low for a 0 and releases it quickly for a
      // 1 (it samples the same way). A read slot cannot occur while we are not serving.
      const bit = lowUs >= ZERO_US ? 0 : 1;
      rxByte |= bit << rxBits;
      rxBits++;
      if (rxBits === 8) {
        const byte = rxByte;
        rxByte = 0;
        rxBits = 0;
        onByte(byte);
      }
    };
    wirePolls.push(poll);
    continue;
  }
  if (d.kind === 'hx711') {
    const doutP = pinByNumber.get(d.dout);
    const sckP = pinByNumber.get(d.sck);
    if (!doutP || !sckP) { d.error = 'pin out of range'; continue; }
    const portDout = ports[doutP.port];
    const portSck = ports[sckP.port];
    const doutMask = 1 << doutP.bit;
    const sckMask = 1 << sckP.bit;
    portDout.setPin(doutP.bit, false); // data ready: DOUT low
    let bitIndex = 0;
    let sckLevel = 0;
    let gainPulses = 0;
    const poll = () => {
      const sckDdr = cpu.data[portSck.portConfig.DDR] & sckMask;
      const sckPort = cpu.data[portSck.portConfig.PORT] & sckMask;
      const now = sckDdr ? (sckPort ? 1 : 0) : 0;
      if (now === sckLevel) return;
      const was = sckLevel;
      sckLevel = now;
      if (was === 1 || now !== 1) return; // rising edge only
      if (bitIndex < 24) {
        const bit = (d.value >> (23 - bitIndex)) & 1;
        portDout.setPin(doutP.bit, bit === 1);
        bitIndex++;
        if (bitIndex === 24) {
          d.reads++;
          bitIndex = 0;
        }
      }
    };
    wirePolls.push(poll);
    continue;
  }
  const trig = pinByNumber.get(d.trig);
  const echo = pinByNumber.get(d.echo);
  if (!trig || !echo) {
    d.error = 'trig/echo pin out of range';
    continue;
  }
  let rise = null;
  ports[trig.port].addListener((value, oldValue) => {
    if (!((value ^ oldValue) & (1 << trig.bit))) return;
    const high = (value >> trig.bit) & 1;
    if (high) {
      rise = cpu.cycles;
      return;
    }
    if (rise === null) return;
    const widthUs = ((cpu.cycles - rise) / F_CPU) * 1e6;
    rise = null;
    if (widthUs < 5) return;
    const echoUs = Math.round(d.distance_cm * 58);
    const startAt = cpu.cycles + Math.round((ECHO_PROPAGATION_US / 1e6) * F_CPU);
    const endAt = startAt + Math.round((echoUs / 1e6) * F_CPU);
    scheduledPins.push({ at: startAt, port: echo.port, bit: echo.bit, level: 1 });
    scheduledPins.push({ at: endAt, port: echo.port, bit: echo.bit, level: 0 });
    scheduledPins.sort((a, b) => a.at - b.at);
    d.echoes.push({ trig_us: Math.round(widthUs * 1000) / 1000, echo_us: echoUs });
  });
}

const maxCycles = Math.round((msLimit / 1000) * F_CPU);
while (cpu.cycles < maxCycles) {
  avrInstruction(cpu);
  cpu.tick();
  while (scheduledPins.length && scheduledPins[0].at <= cpu.cycles) {
    const ev = scheduledPins.shift();
    ports[ev.port].setPin(ev.bit, ev.level === 1);
  }
  if (wirePolls.length) {
    for (const poll of wirePolls) poll();
  }
}
twiTracer.flush();

// PWM summary: for digital pins that toggle rapidly (analogWrite), report the
// average duty cycle so the app can model the pin as an average analog voltage.
function computePwm(edges, totalMs) {
  const byPin = new Map();
  for (const tr of edges) {
    if (tr.digital_pin == null) continue;
    if (!byPin.has(tr.digital_pin)) byPin.set(tr.digital_pin, []);
    byPin.get(tr.digital_pin).push(tr);
  }
  const out = {};
  for (const [pin, list] of byPin) {
    if (list.length < 4) continue; // too few edges to be PWM
    list.sort((a, b) => a.t_ms - b.t_ms);
    let level = 0; // AVR pins start low before the first change
    let last = 0;
    let high = 0;
    let rising = 0;
    for (const e of list) {
      if (level === 1) high += e.t_ms - last;
      if (e.level === 1) rising++;
      level = e.level;
      last = e.t_ms;
    }
    if (level === 1) high += totalMs - last;
    const total = Math.max(1, totalMs);
    out[pin] = {
      duty: Math.round((high / total) * 1e6) / 1e6,
      ms_high: Math.round(high * 1000) / 1000,
      ms_total: totalMs,
      edges: list.length,
      freq_hz: rising > 0 ? Math.round(rising / (totalMs / 1000)) : null,
    };
  }
  return out;
}
const pwm = computePwm(transitions, msLimit);

process.stdout.write(
  JSON.stringify(
    {
      ok: true,
      mcu: 'atmega328p',
      f_cpu: F_CPU,
      hex: hexPath,
      ms: msLimit,
      cycles: cpu.cycles,
      serial: Buffer.from(serialBytes).toString('utf8'),
      serial_bytes: serialBytes.length,
      serial_raw: Array.from(serialBytes),
      i2c,
      devices: [...devices.values()]
        .map((d) => (d.summary ? d.summary() : { kind: d.kind }))
        .concat(spiDevices.map((d) => d.summary())),
      pin_devices: pinDevices.map((d) => {
        if (d.kind === 'encoder') {
          return {
            kind: d.kind, a: d.a, b: d.b, counts: d.counts, direction: d.direction,
            start_us: d.start_us, step_us: d.step_us, states: d.edges.length, error: d.error,
          };
        }
        if (d.kind === 'dht') {
          return {
            kind: d.kind, pin: d.pin, model: d.model, temp_c: d.temp_c,
            humidity: d.humidity, reads: d.reads.length, bytes: d.reads[0]?.bytes ?? [],
            error: d.error,
          };
        }
        if (d.kind === 'ds18b20') {
          const hex = (b) => (b & 0xff).toString(16).padStart(2, '0');
          if (d.absent) return { kind: d.kind, pin: d.pin, absent: true, error: d.error };
          const rom = d.rom ?? [];
          const scratchpad = dsScratchpad(d.temp_c, d.alarm_high, d.alarm_low, d.config).bytes;
          return {
            kind: d.kind, pin: d.pin, temp_c: d.temp_c,
            rom_hex: rom.map(hex).join(' '),
            rom_crc_ok: rom.length === 8 && dallasCrc8(rom.slice(0, 7)) === rom[7],
            resets: d.resets, presence: d.presence, converts: d.converts,
            commands: d.commands, muted: d.muted,
            config: d.config, resolution: d.resolution,
            alarm_high: d.alarm_high, alarm_low: d.alarm_low,
            writes_config: d.writes_config, copies: d.copies, recalls: d.recalls,
            search: d.search, unknown_commands: d.unknown,
            scratchpad_hex: scratchpad.map(hex).join(' '),
            scratchpad_crc_ok: dallasCrc8(scratchpad.slice(0, 8)) === scratchpad[8],
            scratchpad_reads: d.reads.length, reads: d.reads, error: d.error,
          };
        }
        if (d.kind === 'hx711') {
          return {
            kind: d.kind, dout: d.dout, sck: d.sck, value: d.value,
            reads: d.reads, error: d.error,
          };
        }
        if (d.kind === 'ws2812b') {
          // Decode the WS2812B bitstream from the pin's transition record: each bit is
          // ~1.25 us total, with a short high (~0.4 us) for 0 and a long high (~0.8 us)
          // for 1; a low gap > 50 us is a reset. 24 bits (GRB) per LED.
          const pinTrs = transitions
            .filter((t) => t.digital_pin === d.pin)
            .sort((a, b) => a.t_ms - b.t_ms);
          const bits = [];
          let i = 0;
          // build high-pulse durations
          const pulses = [];
          for (let k = 0; k < pinTrs.length - 1; k++) {
            if (pinTrs[k].level === 1 && pinTrs[k + 1].level === 0) {
              pulses.push(pinTrs[k + 1].t_ms - pinTrs[k].t_ms);
            }
          }
          for (const dur of pulses) {
            const us = dur * 1000.0;
            if (us > 50.0) continue; // reset gap, not a bit
            bits.push(us >= 0.5 ? 1 : 0);
          }
          const leds = [];
          for (let off = 0; off + 24 <= bits.length; off += 24) {
            let v = 0;
            for (let b = 0; b < 24; b++) v = (v << 1) | bits[off + b];
            leds.push({
              g: (v >> 16) & 0xff,
              r: (v >> 8) & 0xff,
              b: v & 0xff,
            });
          }
          return {
            kind: d.kind, pin: d.pin, count: d.count,
            bits: bits.length, leds, error: d.error,
          };
        }
        return {
          kind: d.kind, trig: d.trig, echo: d.echo, distance_cm: d.distance_cm,
          echoes: d.echoes, error: d.error,
        };
      }),
      adc: adcChannels,
      spi_bytes: spi.slice(0, SPI_LIMIT),
      spi_byte_count: spi.length,
      pwm,
      transitions,
    },
    null,
    2,
  ) + '\n',
);
