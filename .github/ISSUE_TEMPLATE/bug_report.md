---
name: Bug report
about: Something doesn't work, or works differently than expected
title: ""
labels: bug
assignees: ""
---

## What happened

<!-- What did you do, what did you expect, and what happened instead? Say which mouse it
happened on if you use more than one. -->

## Environment

- Upright version (Settings → About, or the DMG name):
- How you installed it (built from source, DMG, Xcode ⌘R):
- macOS version (Apple menu → About This Mac):
- Mac (Apple silicon or Intel):
- Logi Options+, Logitech Options, Solaar or LogiOps installed or running:

## Your mice

<!-- Upright works with several Logitech mice at once, so say what is connected. Only the
MX Vertical has been tested on hardware; if your model is something else, that matters. -->

- Mouse model(s), as shown in Settings → Mice:
- Number of mice connected at the same time:
- How each one connects, and the receiver layout. For example: "MX Vertical on a Unifying
  receiver (slot 1), MX Master 3S on a Bolt receiver, Lift over Bluetooth". Say how many
  receivers you have, which mice share one, and whether a keyboard is paired to the same
  receiver:
- Is the same mouse reachable in two ways at once (for example a cable and its receiver, or
  Bluetooth and a receiver)? yes / no
- Mouse firmware (Settings → Mice → the mouse):
- The mouse the problem is about shows an "Untested model" badge: yes / no

## Permissions

- Accessibility shown as allowed in Settings → Permissions: yes / no
- Settings → Permissions shows a "Reset Permission" button: yes / no
- Input Monitoring needed: yes / no

## Steps to reproduce

1.
2.
3.

## `make probe ARGS=--all` output

<!-- Quit Upright, then run `make probe ARGS=--all` (or
`swift run --package-path UprightKit upright-probe --all`) with all the affected mice
connected and awake, and paste the whole output. It lists every Logitech HID++ interface,
including ones Upright ignores, and every line starts with its mouse, for example
[MX Master 3S · Bolt slot 2]. Add `--divert` instead if the problem is about button events.
The output contains your mice's unit IDs and serial numbers; replace them with XXXX if you
prefer. If you can't run it, say why. -->

```
```

## Device report and log

<!-- Settings → Mice → select the mouse → "Copy Device Report" (leaves the unit ID and serial
number out). Then, under Activity, turn on "Raw HID++ reports" if the problem is about what
the mouse sends, reproduce it, click Copy, and paste both here. -->

```
```

## Anything else

<!-- Screenshots, your mapping setup (Settings → General → Export…), other apps that affect
the mouse. -->
