BUILD_DIR := build
APP := $(BUILD_DIR)/Build/Products/Release/Upright.app

.PHONY: test app verify dmg probe open clean

## Run the UprightKit unit tests (works on macOS and Linux).
test:
	swift test --package-path UprightKit

## Build Upright.app (Release, universal, ad-hoc signed with the hardened runtime).
app:
	xcodebuild -project Upright.xcodeproj -scheme Upright -configuration Release \
		-derivedDataPath $(BUILD_DIR) \
		CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO \
		ENABLE_HARDENED_RUNTIME=YES OTHER_CODE_SIGN_FLAGS="--options=runtime" \
		ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO build

## Verify the built app's signature and show its flags and entitlements.
verify:
	codesign --verify --deep --strict --verbose=2 $(APP)
	codesign -dvvv --entitlements - $(APP) 2>&1 | grep -E 'flags=|Identifier=|Authority=|TeamIdentifier=|Signature=|\[|<key>|<true|<false|<string' || true

## Package the built app into dist/Upright.dmg.
dmg: app
	scripts/make_dmg.sh $(APP) dist/Upright.dmg

## Talk to connected Logitech mice from the terminal: prints each mouse's identity, HID++ features and controls,
## every line prefixed with its device, e.g. [MX Master 3S · Bolt slot 2].
##   make probe ARGS=--all                 also read interfaces Upright doesn't use (keyboards, Lightspeed receivers, unknown mice)
##   make probe ARGS=--divert              watch button events of every mouse (Ctrl-C restores the buttons)
##   make probe ARGS='--divert="bolt slot 2"'  the same for the mice whose label contains that text
##   make probe ARGS=--help                all options
probe:
	swift run --package-path UprightKit upright-probe $(ARGS)

## Launch the freshly built app.
open: app
	open $(APP)

clean:
	rm -rf $(BUILD_DIR) dist UprightKit/.build
