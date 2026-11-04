# Glim: build, test and package the menu bar app.
# Needs only the Xcode Command Line Tools (swift 6, codesign, hdiutil, notarytool).
# `make help` lists the targets.

APP_NAME      = Glim
APP           = dist/$(APP_NAME).app
ARCH          = arm64
# DDC/CI goes through IOAVService, which exists only on Apple silicon, so the
# app is built for arm64 alone.
SWIFT_RELEASE = swift build -c release --arch $(ARCH) --product $(APP_NAME)
BIN_DIR       = $(shell $(SWIFT_RELEASE) --show-bin-path)
ENTITLEMENTS  = Support/Glim.entitlements
VERSION       = $(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Support/Info.plist)
# CI passes the run number; local builds count commits so every build differs.
BUILD_NUMBER ?= $(shell git rev-list --count HEAD 2>/dev/null || echo 1)
DMG           = dist/$(APP_NAME)-$(VERSION).dmg

# Signing identity. "-" (the default) is an ad-hoc signature: the app runs on
# this Mac, but Gatekeeper blocks it on others until it is notarized. For a
# distributable build pass a Developer ID identity:
#   make dmg SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
SIGN_IDENTITY ?= -
export SIGN_IDENTITY
# Notarization requires a secure timestamp; an ad-hoc signature has no use for
# one, and skipping it keeps local builds offline.
ifeq ($(SIGN_IDENTITY),-)
TIMESTAMP = --timestamp=none
else
TIMESTAMP = --timestamp
endif

.DEFAULT_GOAL := help
.PHONY: help build test check hardware-test release app run icon dmg notarize verify verify-strict probes clean

help:
	@echo "Glim $(VERSION)"
	@echo ""
	@echo "  make build           debug build"
	@echo "  make test            unit and mock-hardware tests (no monitor needed)"
	@echo "  make check           build and test with warnings as errors (what CI runs)"
	@echo "  make hardware-test   tests against a connected monitor (safe, reversible writes)"
	@echo "  make app             dist/Glim.app: release build, icon, signed"
	@echo "  make run             build the app and launch it"
	@echo "  make dmg             dist/Glim-$(VERSION).dmg"
	@echo "  make notarize        notarize and staple the app and the DMG (needs credentials)"
	@echo "  make verify          check signature, hardened runtime, Gatekeeper and staple"
	@echo "  make glim            the C research CLI (./glim), see docs/ddc-ci-protocol.md"
	@echo "  make probes          the read-only macOS probes in tools/macos-probe"
	@echo "  make clean           remove build output"
	@echo ""
	@echo "  signing identity: $(SIGN_IDENTITY)"

build:
	swift build

test:
	swift test

check:
	swift build -Xswiftc -warnings-as-errors
	swift test -Xswiftc -warnings-as-errors

# Talks to the real monitor. Every write is reversible and restored; see
# Tests/GlimCoreTests/HardwareTests.swift for exactly what is sent.
hardware-test:
	GLIM_HARDWARE_TESTS=1 swift test --filter HardwareTests

release:
	$(SWIFT_RELEASE)

icon: dist/AppIcon.icns

dist/AppIcon.icns: scripts/make-icon.swift
	rm -rf dist/AppIcon.iconset
	mkdir -p dist/AppIcon.iconset
	swift scripts/make-icon.swift dist/AppIcon.iconset
	iconutil -c icns dist/AppIcon.iconset -o $@

app: release icon
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp "$(BIN_DIR)/$(APP_NAME)" $(APP)/Contents/MacOS/$(APP_NAME)
	cp Support/Info.plist $(APP)/Contents/Info.plist
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(BUILD_NUMBER)" $(APP)/Contents/Info.plist
	cp dist/AppIcon.icns $(APP)/Contents/Resources/AppIcon.icns
	codesign --force --options runtime $(TIMESTAMP) \
		--entitlements $(ENTITLEMENTS) --sign "$(SIGN_IDENTITY)" $(APP)
	@echo "built $(APP) $(VERSION) ($(BUILD_NUMBER)), identity: $(SIGN_IDENTITY)"

run: app
	open $(APP)

dmg: app
	scripts/make-dmg.sh $(APP) $(DMG)

notarize:
	scripts/notarize.sh $(APP) $(DMG)

verify:
	scripts/verify.sh $(APP) $(DMG)

verify-strict:
	scripts/verify.sh --strict $(APP) $(DMG)

# The C CLI used for the original reverse engineering. Independent of the app.
glim: tools/glim-cli/glim.c
	$(CC) -O2 -Wall -Wextra -o $@ $< -framework IOKit -framework CoreFoundation

probes:
	$(MAKE) -C tools/macos-probe

clean:
	rm -rf .build dist glim
