---
name: Request support for a mouse
about: Your Logitech mouse isn't listed, shows up as unsupported, or you tried an untested model
title: "New mouse: "
labels: new mouse
assignees: ""
---

<!-- Upright decides what to serve by what a mouse answers: HID++ 2.0 with programmable buttons
(REPROG_CONTROLS_V4). Many models that aren't listed may already work, and only the MX Vertical
has been tested on hardware, so a report from a different mouse is valuable even if everything
works. See docs/DEVICES.md for the list and what each status means. -->

## The mouse

- Name and model number (on the box or the underside):
- Is it listed in `docs/DEVICES.md`? yes (status: ...) / no

## What Upright shows

<!-- Open Settings → Mice with the mouse connected and awake. Tick what you see. -->

- [ ] It is listed as a mouse, with its buttons in Settings → Buttons
- [ ] It is listed as a mouse with an "Untested model" badge
- [ ] It is under "Other Logitech devices", with this reason:
- [ ] It doesn't appear anywhere

## Connection and receivers

- Number of mice connected at the same time (of any model):
- How this mouse connects: USB cable / Bluetooth / Unifying receiver / Bolt receiver / Nano receiver
- Receiver layout: which receiver it is in, the slot number if you know it, the other mice and
  keyboards sharing that receiver, and how many receivers there are. For example: "Bolt
  receiver with this mouse and an MX Keys; a Unifying receiver with an MX Vertical":
- Is it also paired by Bluetooth or cable at the same time? yes / no
- macOS version:
- Mac (Apple silicon or Intel):
- Upright version:

## `make probe ARGS=--all` output

<!-- Required. Quit Upright, connect the mouse the way you use it (wake it by moving it), and run
`make probe ARGS=--all` (or `swift run --package-path UprightKit upright-probe --all`). Paste the
whole output; it lists every Logitech HID++ interface, what Upright does with each, the
mouse's identity, feature table and button table. If you can connect the mouse in more than one
way (receiver and Bluetooth), run it once for each and paste both, because the identity block
can show whether the unit ID is the same on both. Leave the mouse's unit ID and serial number
as they are or replace them with XXXX, but say whether the unit ID matched between runs. -->

```
```

## Device report

<!-- Optional. Settings → Mice → select the mouse → "Copy Device Report". -->

```
```

## Does it work?

<!-- Only if Upright serves the mouse. Set a mapping in Settings → Buttons, for example Forward →
Mission Control, and tick what holds. Try each connection you have. -->

- [ ] A remapped button does what I set
- [ ] The mapping stops when I turn off "Remap this mouse" or quit Upright
- [ ] The mouse reconnects after sleep or after turning it off and on
- [ ] Pointer speed, battery and Easy-Switch show up (if the mouse has them)
- [ ] Nothing changed for my other mice
- Anything that is wrong or strange:

## Helping out

- [ ] I can test builds or pull requests on this mouse
- [ ] I'd like to add the model myself (see "Adding a model from an `upright-probe --all` dump"
      in CONTRIBUTING.md)
