# Hardware results

Real-hardware checks, newest first. Only the MX Vertical is available for testing. Section numbers refer to [HARDWARE-SMOKE-CHECKLIST.md](HARDWARE-SMOKE-CHECKLIST.md).

## 19 Oct 2026: Upright 1.1.2 (build 4), MX Vertical over Bluetooth LE

- Setup: the release DMG build, ad-hoc signed, running since 17 Oct without a restart. Mouse firmware MPM 16.00.B0009, HID++ 4.5.
- `upright-probe` (read-only, no `--divert`) found the mouse, opened it over Bluetooth LE and read battery 50%, 1200 DPI, Easy-Switch channel 2 of 3 and the 4 remappable controls (Middle, Back, Forward, DPI switch).
- Power cycle (section 5, Bluetooth part): the mouse was switched off and on. The remapped buttons worked again without restarting Upright, and the same Upright process (started 17 Oct) was still running afterwards. A second probe run reconnected and read the battery normally.
- Not measured: reconnect latency, and the activity log wasn't copied. Sleep and wake, the Unifying receiver and Easy-Switch (sections 1 to 4, 6 to 10) were not run.
