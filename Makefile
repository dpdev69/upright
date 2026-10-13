BUILD_DIR := build
APP := $(BUILD_DIR)/Build/Products/Release/Upright.app

.PHONY: test app dmg probe open clean

## Run the UprightKit unit tests (works on macOS and Linux).
test:
	swift test --package-path UprightKit

## Build Upright.app (Release, ad-hoc signed, universal).
app:
	xcodebuild -project Upright.xcodeproj -scheme Upright -configuration Release \
		-derivedDataPath $(BUILD_DIR) \
		CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO \
		ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO build

## Package the built app into dist/Upright.dmg.
dmg: app
	scripts/make_dmg.sh $(APP) dist/Upright.dmg

## Talk to a connected MX Vertical from the terminal. Pass ARGS=--divert to watch button events.
probe:
	swift run --package-path UprightKit upright-probe $(ARGS)

## Launch the freshly built app.
open: app
	open $(APP)

clean:
	rm -rf $(BUILD_DIR) dist UprightKit/.build
