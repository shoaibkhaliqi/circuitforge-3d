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
  AVRIOPort,
  timer0Config,
  timer1Config,
  timer2Config,
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
  console.error('usage: node run.mjs <hexPath> [msLimit]');
  process.exit(2);
}
const msLimit = Number(msArg ?? 3000);

const cpu = new CPU(loadHexProgram(hexPath));
new AVRTimer(cpu, timer0Config);
new AVRTimer(cpu, timer1Config);
new AVRTimer(cpu, timer2Config);

const ports = {
  B: new AVRIOPort(cpu, portBConfig),
  C: new AVRIOPort(cpu, portCConfig),
  D: new AVRIOPort(cpu, portDConfig),
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

process.stdout.write(
  JSON.stringify(
    {
      mcu: 'atmega328p',
      f_cpu: F_CPU,
      hex: hexPath,
      ms: msLimit,
      cycles: cpu.cycles,
      transitions,
    },
    null,
    2,
  ) + '\n',
);
