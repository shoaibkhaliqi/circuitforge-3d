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
  AVRIOPort,
  timer0Config,
  timer1Config,
  timer2Config,
  usart0Config,
  twiConfig,
  spiConfig,
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
        summary: () => ({ kind: 'eeprom', address: addr, size, pointer: ptr }),
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

// SPI traffic monitor: record MOSI bytes; MISO returns 0x00 (no device attached).
const spi = [];
const spiDevice = new AVRSPI(cpu, spiConfig, F_CPU);
spiDevice.onByte = (value) => {
  spi.push(value & 0xff);
  spiDevice.completeTransfer(0x00);
};

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

const maxCycles = Math.round((msLimit / 1000) * F_CPU);
while (cpu.cycles < maxCycles) {
  avrInstruction(cpu);
  cpu.tick();
}
twiTracer.flush();

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
      i2c,
      devices: [...devices.values()].map((d) => (d.summary ? d.summary() : { kind: d.kind })),
      spi_bytes: spi,
      transitions,
    },
    null,
    2,
  ) + '\n',
);
