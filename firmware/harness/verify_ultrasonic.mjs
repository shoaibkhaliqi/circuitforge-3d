// Reproducible check for the HC-SR04 ultrasonic sensor: serve a distance sensor
// (CF_DEVICES) whose ECHO pulse the harness drives as an MCU input, run the
// ultrasonic sketch and assert pulseIn() measured the expected round-trip time and
// distance. Exit 0/1.
//
//   arduino-cli compile --fqbn arduino:avr:uno --output-dir build/ultrasonic \
//     sketches/ultrasonic
//   node verify_ultrasonic.mjs build/ultrasonic/ultrasonic.ino.hex
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const hexPath =
  process.argv[2] ?? join(here, '..', 'build', 'ultrasonic', 'ultrasonic.ino.hex');

const DISTANCE_CM = 30;
const EXPECTED_ECHO_US = DISTANCE_CM * 58; // 1740 us round trip

const raw = execFileSync(process.execPath, [join(here, 'run.mjs'), hexPath, '600'], {
  encoding: 'utf8',
  env: {
    ...process.env,
    CF_DEVICES: `[{"kind":"hc_sr04","trig":9,"echo":10,"distance_cm":${DISTANCE_CM}}]`,
  },
});
const { serial = '', pin_devices: pinDevices = [] } = JSON.parse(raw);

const dev = pinDevices[0] ?? {};
const trig = dev.echoes && dev.echoes[0];
const m = /echo\s+(\d+)\s+dist\s+(\d+)/.exec(serial);
const echoUs = m ? Number(m[1]) : -1;
const distanceCm = m ? Number(m[2]) : -1;

const failures = [];
if (dev.kind !== 'hc_sr04') failures.push(`pin device kind=${dev.kind} (want hc_sr04)`);
if (!trig) failures.push('sensor never saw a trigger pulse');
if (!m) failures.push(`Serial did not report a reading: ${JSON.stringify(serial)}`);
if (m && Math.abs(echoUs - EXPECTED_ECHO_US) > 60) {
  failures.push(`pulseIn() ${echoUs} us (want ~${EXPECTED_ECHO_US} us)`);
}
if (m && (distanceCm < DISTANCE_CM - 1 || distanceCm > DISTANCE_CM + 1)) {
  failures.push(`distance ${distanceCm} cm (want ~${DISTANCE_CM} cm)`);
}

console.log(
  `trig=${trig ? trig.trig_us : '-'} us, echo(served)=${trig ? trig.echo_us : '-'} us, ` +
    `pulseIn=${echoUs} us, distance=${distanceCm} cm`,
);
if (failures.length) {
  console.error(`FAIL:\n  ${failures.join('\n  ')}`);
  process.exit(1);
}
console.log(`PASS: HC-SR04 reported ~${DISTANCE_CM} cm from a harness-driven ECHO pulse`);
