# Upright multi-mouse: hardware smoke test

Setup: one MX Vertical, used over a Unifying receiver and over Bluetooth.

Only the MX Vertical can be checked on real hardware. Everything about other models, and about two mice at once, has only been checked in the simulator. Expect about 30-40 minutes.

**Never run `upright-probe --divert` for this checklist.**

**Highest priority: section 4 (interface opening, audit item A2).** It checks the only hardware-verified path, which the wave 7 audit changed (the IOHIDManager is no longer opened). If you only have ten minutes, do sections 0, 3 and 4 first.

Each section ends with a **Paste back** list: what to copy into the session (or into the commit message / `NEXT-STEPS.md`) so the result is recorded. Related: [`NEXT-STEPS.md`](NEXT-STEPS.md), [`DESIGN-multimouse.md`](DESIGN-multimouse.md) section G-4.

## 0. Prepare (2.x still installed)

1. Note your current setup in Upright 2.x:
   - screenshot the Buttons pane, including every app profile;
   - note the pointer speed and whether "Remap buttons" is on.
2. Back up your settings (read-only export):
   `defaults export io.github.upright.Upright ~/Desktop/upright-2x-backup.plist`
3. Check whether Upright is already listed under System Settings > Privacy & Security > Input Monitoring. Note "listed / not listed". If it is listed, the "no prompt" check below is only partly meaningful.
4. Quit Upright 2.x from the menu bar.
5. Build the new version:
   `git checkout multi-mouse && make test && make app`
   The app is at `build/Build/Products/Release/Upright.app`.
   - It is ad-hoc signed and in a different location, so macOS may ask you to grant Accessibility again for this copy. Grant it, otherwise shortcuts won't fire.

**Paste back:** the last line of `make test` ("Executed N tests, with 0 failures").

## 1. Probe over the Unifying receiver (Upright must NOT be running)

Quit Upright first: the probe and the app share the same HID++ interface and the same software ID (0x0A), so each could take the other's replies. Without `--divert` the probe is read-only for button reporting (it never writes it), so it does not undo a diversion left by another process, but it still must not run next to Upright.

1. Put the MX Vertical on its Unifying channel (Easy-Switch button underneath) and click a button so it is awake.
2. Run `make probe ARGS=--all`. If asked, allow your terminal under Input Monitoring.
3. Wait for the `[MX Vertical · Unifying slot N]` block, about 5 s, then press Ctrl-C.

Expected:

- the header lines `Watching for Logitech HID++ interfaces` and `Input Monitoring access: …` (the manager is no longer opened, so there is no `IOHIDManagerOpen` line any more);
- a `→` line for the receiver's HID++ interface saying Upright serves it as a Unifying receiver, with **no `✗` line** under it (a `✗` line is the per-interface open failing; a successful open prints nothing extra);
- a `✓ MX Vertical: Upright supports this device` line;
- `Model: MX Vertical (046D:B020)`;
- `Unit ID:` 8 hex digits, not "none reported";
- `Device ID: u:046D:B020:XXXXXXXX`;
- controls 0x0053, 0x0056 and 0x00FD marked `*`, with their `raw XY` flags shown;
- `Ignoring …` lines for the receiver's keyboard and mouse interfaces;
- no prompt asking to let the terminal or Upright "receive keystrokes", other than the terminal's own first-time Input Monitoring request.

**Paste back:** the whole output, or at least the header lines (`Watching…`, `Input Monitoring access:`), every `→` line and any `✗` line, every `Ignoring` line, and the full MX Vertical block (Identity, Features, Controls).

## 2. Probe over Bluetooth (same-unit identity)

1. Switch the MX Vertical to its Bluetooth channel. Pair it in System Settings > Bluetooth if it isn't paired yet.
2. Run `make probe ARGS=--all` again and press Ctrl-C once the `[MX Vertical · Bluetooth]` block is printed.

Expected:

- a `→` line for the Bluetooth interface (served as a mouse connected by Bluetooth) with no `✗` line;
- the Model is the same `046D:B020`;
- the `Unit ID` and `Device ID` are **identical** to step 1, which confirms same-unit dedupe across transports;
- the receiver slot shows as not answering or asleep.

**Paste back:** the MX Vertical block, and a one-line verdict: Unit ID same / different.

## 3. First launch of the new build (migration, no prompt)

1. Switch the mouse back to Unifying.
2. Run `open build/Build/Products/Release/Upright.app`.

Expected:

- **no Input Monitoring prompt** at launch;
- the menu shows one "MX Vertical" row with its battery;
- Settings > Buttons shows exactly the same mappings and app profiles as the 2.x screenshot, with the model picker on MX Vertical;
- Settings > Mice shows the same pointer speed as 2.x, and "Remap buttons" is in the same state;
- every remapped button does what it did in 2.x;
- buttons you left native still act natively (Back and Forward navigate, the top button cycles DPI).

Then run:

```sh
defaults read io.github.upright.Upright | grep -oE 'mappingProfiles[A-Za-z0-9.]*|devicePreferences\.v1|preferredDPI' | sort -u
```

Expected keys: `mappingProfiles.v2` (still there, never rewritten), `mappingProfiles.v3`, `mappingProfiles.v2.preV3Backup` and `devicePreferences.v1`.

**Paste back:**

- "prompt: yes/no";
- "mappings identical: yes/no" (and which button differs, if any);
- the DPI shown in 2.x and in 3.x;
- the `defaults` key list;
- the Activity log: Mice > Activity > "All devices" > Copy.

## 4. Interface opening without IOHIDManagerOpen (A2, highest priority)

The wave 7 audit stopped calling `IOHIDManagerOpen`. Only the interfaces the classifier accepts are opened, one `IOHIDDeviceOpen` each, and permission failures surface per interface. This changes the only path that was ever verified on hardware, so it needs a real check. Do it with the build from section 0 and the mappings from section 3.

1. With the MX Vertical on the Unifying receiver: Upright finds the mouse (one "MX Vertical" row with its battery) and every remapped button still fires its action.
2. Switch the mouse to Bluetooth (receiver still plugged in): the same, within about 2 s of the switch.
3. Quit Upright, then reset its Input Monitoring decision. This resets Input Monitoring for Upright only:
   `tccutil reset ListenEvent io.github.upright.Upright`
4. Plug in the receiver (unplug and replug it if it is already in), then relaunch Upright (`open build/Build/Products/Release/Upright.app`).

Expected:

- **no Input Monitoring prompt** appears;
- **no "macOS is blocking access" banner** in the menu or in Settings > Permissions;
- the MX Vertical is still found and button presses still arrive (a remapped button fires; the Activity log shows `Diverted controls: …`), on the receiver and on Bluetooth;
- if the app does show a banner or prompt, copy the exact text and the Activity log. The failure to look for is an interface open being refused (`kIOReturnNotPermitted`) for the receiver's mouse interface.

If macOS grants Input Monitoring again after this (you click Allow), note that too: the point is whether the app asks at all.

**Paste back:** "prompt after reset: yes/no", "banner: yes/no", "buttons arrive over receiver: yes/no, over Bluetooth: yes/no", and the Activity log (Mice > Activity > "All devices" > Copy).

## 5. Sleep, wake and power-cycle reconnect latency (Unifying, then Bluetooth)

1. Sleep the Mac (Apple menu > Sleep) for at least 30 s, then wake it.
2. Wait 3 s, then press a remapped button.
   - Expected: it works within about 1-2 s, as fast as 2.x.
   - The log shows `Mac woke up; reapplying button configuration`, then `Reapplied configuration`, or a `Slot N link restored` line.
   - It must **not** show `Slot N now holds another device`.
3. Switch the mouse off with its power switch for 10 s, switch it back on, click once, then press a remapped button.
   - Expected: it works within about 1-2 s.
   - The log shows `Slot N link restored` and `Diverted controls: …`.
4. Leave the mouse idle until it sleeps (a few minutes), then move it and press a remapped button.
   - Expected: it works right away.
5. Repeat steps 1-3 with the mouse on its Bluetooth channel.
   - Expected: the same latency.
   - The menu still shows one MX Vertical row, which may read "Bluetooth · Connected · also on Unifying".
6. Long absence, Easy-Switch (receiver link-up, not polling). With the mouse on its Unifying channel, Easy-Switch it to another computer (or to its Bluetooth channel) and leave it there for at least 2 minutes. That is longer than the old 30 s poll, so a slow poll cannot hide a missing link-up. Then switch it back to the receiver channel and press a remapped button.
   - Expected: it works within about 1-2 s.
   - The log shows `Slot N link restored` (or `Slot N sent a report; checking the device there`).
   - What reconnected it must **not** be a `Trying again in 300.0 s` retry.
7. Long absence, power switch. Switch the mouse off with its power switch for at least 2 minutes, switch it back on, click once, then press a remapped button.
   - Expected: the same as step 6 (about 1-2 s, `Slot N link restored`, no `Trying again in 300.0 s` line doing the reconnect).

Why steps 6 and 7 matter: once the receiver's link notifications are on, an absent slot is only polled about every 5 minutes (the backoff caps at about 300 s), so reconnecting has to come from the receiver's 0x41 link-up notification or the mouse's first report. This has only been verified in the simulator.

**Paste back:** the approximate latency for each case (with 2.x for comparison if you remember it), the latency for steps 6 and 7 (how long you were away, and the time from switching back to the remapped button working), and the Activity log copied after this step.

## 6. Easy-Switch between receiver and Bluetooth inside the app (same-unit dedupe)

1. With the receiver plugged in, switch the mouse to Bluetooth, then back to Unifying, using the button underneath.
2. Expected:
   - there is only ever one active MX Vertical row;
   - remapped buttons work on both channels within about 2 s of each switch;
   - nothing fires twice;
   - no row goes red ("failed") for longer than a moment.
3. Optional: with both channels paired, use Mice > Easy-Switch > "Switch…" to change channel from the app.
   - Expected: the mouse moves to that channel, and buttons work there after it reconnects.

**Paste back:** "one row: yes/no", "double actions: yes/no", and the Activity log.

## 7. Quit restores native buttons

1. Choose Quit Upright from the menu.
2. Immediately press each button you had remapped, without unplugging or sleeping anything.
3. Expected: every button is native again (Back/Forward navigate, the top button cycles DPI, nothing fires a shortcut).
4. Repeat on Bluetooth.

**Paste back:** "native after quit: Unifying yes/no, Bluetooth yes/no".

## 8. Remap switch and per-mouse switch (no stuck keys)

1. Relaunch Upright. Hold a button mapped to a shortcut or a mouse button, and turn "Remap buttons" off while holding it.
   - Expected: no stuck modifier or stuck click; the button goes native.
2. Turn it back on.
   - Expected: the remapping returns.
3. Do the same with Mice > "Remap this mouse".

**Paste back:** pass/fail.

## 9. Optional: re-pair to another receiver slot

Only if you have Logitech pairing software.

1. Un-pair the MX Vertical and pair it to the same Unifying receiver again (it usually lands in a new slot).
2. Expected:
   - the log shows `Slot X was unpaired`, or `MX Vertical moved from slot X to slot Y`;
   - mappings and nickname stay the same;
   - buttons work after the re-pair.

**Paste back:** the Activity log.

## 10. Optional: second Logitech mouse

Only if you can borrow one.

1. Connect it alongside the MX Vertical.
2. Expected:
   - two rows;
   - the new model starts fully native (nothing remapped);
   - holding Back on both mice at the same time is independent (each release ends only its own action);
   - changing DPI on one doesn't change the other.

**Paste back:** `make probe ARGS=--all` output for that mouse (with Upright quit), and pass/fail per check.

## Rollback

Quit the new build and run your 2.x app again. It reads the untouched `mappingProfiles.v2`, so it shows your pre-upgrade setup. Changes made in 3.x are not visible there. The backup from section 0 is at `~/Desktop/upright-2x-backup.plist` if you ever need it.
