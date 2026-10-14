## What and why

<!-- What does this change, and why? Link the issue if there is one. -->

## How I tested it

- [ ] `make test` passes
- [ ] `make app` builds (needed if you touched `Upright/` or the Xcode project)
- [ ] New Swift files are added to `Upright.xcodeproj/project.pbxproj` exactly once (the check
      in CONTRIBUTING.md prints nothing)
- [ ] `make snapshots` renders the changed screens (if you touched a view)
- [ ] Tried it on real hardware. Mouse model(s) and connection (USB cable / Unifying / Bolt / Nano
      / Bluetooth), and how many mice at once:
- [ ] Simulator only (no hardware). Which profiles or scenarios:
- macOS version:

<!-- For HID++ changes, paste relevant `make probe ARGS=--all` output or Activity log lines.
For a new model, the `--all` dump the entry is based on. -->

## Checklist

- [ ] Code outside `UprightKit/Sources/UprightKit/Platform/` uses Foundation only (it runs on Linux in CI)
- [ ] Tests cover the change, using the simulator (`SimulatedReceiver` / `SimulatedDirect` with
      `DeviceProfiles`) rather than real hardware
- [ ] Every test method in a `@MainActor` test class is `async` (Linux CI fails otherwise)
- [ ] New HID++ messages are documented in `docs/HIDPP.md`, with whether they were tested on hardware
- [ ] Anything about a model other than the MX Vertical is marked as untested on hardware
      (`.publishedDump`, `docs/DEVICES.md`) unless it was
- [ ] A catalog change keeps existing model keys, and `docs/DEVICES.md` matches `DeviceCatalog`
- [ ] User-facing behavior changes are reflected in `README.md` / `INSTALL.md`
- [ ] Added a line under **Unreleased** in `CHANGELOG.md`
- [ ] No saved-data format was broken (mappings and settings still load; old data is migrated)
