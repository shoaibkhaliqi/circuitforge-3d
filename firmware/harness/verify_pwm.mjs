// Reproducible check for the PWM surface: run the pwm_out sketch (analogWrite(9,
// 128)) and assert the harness measures D9's duty as ~128/255 and a plausible
// frequency. Exit 0/1.
//
//   arduino-cli compile --fqbn arduino:avr:uno --output-dir build/pwm_out sketches/pwm_out
//   node verify_pwm.mjs build/pwm_out/pwm_out.ino.hex
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const hexPath = process.argv[2] ?? join(here, '..', 'build', 'pwm_out', 'pwm_out.ino.hex');

const raw = execFileSync(process.execPath, [join(here, 'run.mjs'), hexPath, '2000'], {
  encoding: 'utf8',
});
const { pwm } = JSON.parse(raw);

const failures = [];
const p = pwm && pwm['9'];
if (!p) failures.push(`no PWM summary for pin 9: ${JSON.stringify(pwm)}`);
else {
  const want = 128 / 255;
  if (Math.abs(p.duty - want) > 0.02) failures.push(`duty ${p.duty} (want ~${want.toFixed(3)})`);
  if (!(p.freq_hz >= 300 && p.freq_hz <= 700)) failures.push(`freq ${p.freq_hz} Hz (want ~490)`);
}

console.log(`pwm: ${JSON.stringify(p)}`);
if (failures.length) {
  console.error(`FAIL:\n  ${failures.join('\n  ')}`);
  process.exit(1);
}
console.log('PASS: analogWrite(9,128) measured as ~50.2% duty (PWM -> average)');
