# Security policy

## Supported versions

Security fixes go into the latest release. Please update to the
[newest version](https://github.com/dpdev69/upright/releases/latest) before reporting.

| Version | Supported |
| ------- | --------- |
| 1.1.x   | Yes       |
| < 1.1   | No        |

## Reporting a vulnerability

Please **don't open a public issue** for a security problem. Report it privately through
GitHub instead: open the repository's **Security** tab and choose
[**Report a vulnerability**](https://github.com/dpdev69/upright/security/advisories/new).

Include what you can of the following:

- the Upright version (Settings → About) and your macOS version
- the mouse model and how it's connected (USB cable, Bluetooth, Unifying, Bolt or Nano)
- what an attacker could do, and the steps to reproduce it
- a proof of concept, if you have one

You'll get a reply on the advisory. Once a fix is released, the advisory is published with
credit to you, unless you'd rather stay anonymous.

## Scope

In scope:

- the Upright app: how it opens Logitech HID devices, posts input events, runs the actions you
  assign (Open App, Open URL, Run Shortcut) and imports mapping files
- the build and release workflows in `.github/workflows/`
- the website in `site/`

Out of scope:

- Gatekeeper's warning on first launch. Release builds are ad-hoc signed and not notarized, as
  the [install guide](INSTALL.md#if-macos-blocks-the-app) explains.
- Problems in macOS, in Logitech firmware or in apps that Upright opens for you.

## How Upright limits its reach

- It only opens Logitech HID interfaces. Keyboards are never opened, so it never reads what
  you type.
- It doesn't phone home or collect anything. There's no network code, account or telemetry.
- Nothing is written to a mouse's memory. Buttons are diverted only while Upright runs.
- It uses the hardened runtime. It isn't sandboxed, because posting synthetic input and opening
  HID devices requires that (see [Permissions](README.md#permissions)).
