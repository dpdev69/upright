## What and why

<!-- What does this change, and why? Link the issue if there is one. -->

## How I tested it

- [ ] `make test` passes
- [ ] `make app` builds (needed if you touched `Upright/` or the Xcode project)
- [ ] New Swift files are added to `Upright.xcodeproj/project.pbxproj`
- [ ] Tried it with a real MX Vertical. Connection: USB cable / Unifying / Bluetooth
- macOS version:

<!-- For HID++ changes, paste relevant `make probe` output or Activity log lines. -->

## Checklist

- [ ] Code outside `UprightKit/Sources/UprightKit/Platform/` uses Foundation only (it runs on Linux in CI)
- [ ] Tests cover the change, using the simulated mouse rather than real hardware
- [ ] New HID++ messages are documented in `docs/HIDPP.md`
- [ ] User-facing behavior changes are reflected in `README.md` / `INSTALL.md`
- [ ] Added a line under **Unreleased** in `CHANGELOG.md`
- [ ] No saved-data format was broken (mappings and settings still load; old data is migrated)
