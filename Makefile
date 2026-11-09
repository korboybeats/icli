.DEFAULT_GOAL := all
SHELL    := /bin/sh
SDK      ?= $(shell xcrun --sdk iphoneos --show-sdk-path)
SDK_VERSION ?= $(shell xcrun --sdk iphoneos --show-sdk-version)
TARGET   ?= arm64-apple-ios15.0
ARM64E_TARGET ?= arm64e-apple-ios15.0
SWIFT    ?= swift
LDID     ?= ldid
INSTALL  ?= /var/jb/usr/bin/icli

BUILD    := .build
BIN      := $(BUILD)/icli
ENT      := Resources/icli.entitlements

# The probe agent: `icli probe` inside somebody else's app, injected per
# launch by `icli app launch --probe`. It is its own Mach-O, compiled from the
# same engine and bridge the CLI uses, with no Swift and nothing linked but
# Foundation and UIKit. Both slices in one invocation, the way an app's own dylib is
# built: dyld picks arm64e where the app runs it.
AGENT         := $(BUILD)/icli-probe-agent.dylib
AGENT_SOURCES := Agent/IcliProbeAgent.m Agent/IcliObjectInspection.m Agent/ICLIFlexBridge.m Sources/IcliProbe/IcliProbeContext.m Sources/IcliProbe/IcliProbeBridge.m
AGENT_FLAGS   := -dynamiclib -arch arm64 -arch arm64e -isysroot $(SDK) -miphoneos-version-min=15.0 \
	-Os -std=gnu11 -fobjc-arc -fobjc-weak -Wall -Wextra -Werror \
	-ISources/IcliProbe -ISources/IcliProbe/include -I.build/flexultra-src \
	-install_name @rpath/icli-probe-agent.dylib -framework Foundation -framework UIKit

ifeq ($(DEBUG),1)
CONFIGURATION := debug
else
CONFIGURATION := release
endif

SWIFT_FLAGS := --configuration $(CONFIGURATION) --triple $(TARGET) --sdk $(SDK) \
	--scratch-path $(BUILD)/swiftpm-$(firstword $(subst -, ,$(TARGET))) --product icli --force-resolved-versions

# Authenticated target thread state requires an authenticated caller. Keep
# arm64 for older devices and let dyld select arm64e where it is supported.
# Swift does not emit signed class_ro_t metadata; match that in ObjC objects.
ARM64E_FLAGS := --configuration $(CONFIGURATION) --triple $(ARM64E_TARGET) --sdk $(SDK) \
	--scratch-path $(BUILD)/swiftpm-arm64e --product icli --force-resolved-versions \
	-Xcc -fno-ptrauth-objc-class-ro

TVOS_SDK         ?= $(shell xcrun --sdk appletvos --show-sdk-path)
TVOS_SDK_VERSION ?= $(shell xcrun --sdk appletvos --show-sdk-version)
TVOS_TARGET      ?= arm64-apple-tvos15.0
TVOS_BIN         := $(BUILD)/icli-tvos
TVOS_STUBS       := $(BUILD)/tvos-stubs
TVOS_FLAGS := --configuration $(CONFIGURATION) --triple $(TVOS_TARGET) --sdk $(TVOS_SDK) \
	--scratch-path $(BUILD)/swiftpm --product icli --force-resolved-versions \
	-Xcc -F$(TVOS_STUBS) -Xswiftc -F$(TVOS_STUBS) -Xlinker -F$(TVOS_STUBS)

.PHONY: all agent debug resolve install clean deb deb-rootless deb-roothide deb-rootful tvos deb-tvos

all:
	python3 scripts/prepare-flexultra.py
	$(SWIFT) build $(SWIFT_FLAGS)
	cp "$$($(SWIFT) build $(SWIFT_FLAGS) --show-bin-path)/icli" $(BIN)
ifneq ($(TARGET),$(ARM64E_TARGET))
	$(SWIFT) build $(ARM64E_FLAGS)
	cp "$$($(SWIFT) build $(ARM64E_FLAGS) --show-bin-path)/icli" $(BUILD)/icli-arm64e
	xcrun lipo -create $(BIN) $(BUILD)/icli-arm64e -output $(BUILD)/icli-universal
	mv $(BUILD)/icli-universal $(BIN)
endif
	# SwiftPM can stamp the triple's version as the SDK too. Frameworks branch
	# on the linked SDK (NSURL's parser, UIKit and Swift runtime behaviour), so
	# the binary says the SDK it was really built with, as 0.8.0 did (sdk 26.5).
	xcrun vtool -set-build-version ios 15.0 $(SDK_VERSION) -replace -output $(BIN) $(BIN)
	$(LDID) -S$(ENT) $(BIN)
	python3 scripts/verify-binary.py

agent:
	python3 scripts/prepare-flexultra.py
	$(MAKE) -C Vendor/FLEX -j8 SDK="$(SDK)"
	python3 scripts/verify-binary.py --platform flex
	$(MAKE) -C Agent/FlexUltra -j8 SDK="$(SDK)"
	python3 scripts/verify-binary.py --platform engine
	$(MAKE) -C Agent/FlexUltra -f Makefile.metadata -j2 SDK="$(SDK)"
	python3 scripts/verify-binary.py --platform reflex
	mkdir -p $(BUILD)
	xcrun --sdk iphoneos clang $(AGENT_FLAGS) $(AGENT_SOURCES) -o $(AGENT)
	$(LDID) -S $(AGENT)
	python3 scripts/verify-binary.py --platform agent

debug:
	$(MAKE) DEBUG=1 all

resolve:
	$(SWIFT) package --scratch-path $(BUILD)/swiftpm-$(firstword $(subst -, ,$(TARGET))) resolve

install: all
	sudo mkdir -p $(dir $(INSTALL))
	sudo cp $(BIN) $(INSTALL)
	sudo $(LDID) -S$(ENT) $(INSTALL)

clean:
	rm -rf $(BUILD) packaging/root

deb: all agent
	./packaging/build-deb.sh rootless

deb-rootless: deb

deb-roothide: all agent
	./packaging/build-deb.sh roothide

deb-rootful: all agent
	./packaging/build-deb.sh rootful

# tvOS: the same sources against the AppleTVOS SDK, as their own binary.
tvos:
	./scripts/tvos-iokit-stub.sh $(TVOS_STUBS)
	$(SWIFT) build $(TVOS_FLAGS)
	cp "$$($(SWIFT) build $(TVOS_FLAGS) --show-bin-path)/icli" $(TVOS_BIN)
	xcrun vtool -set-build-version tvos 15.0 $(TVOS_SDK_VERSION) -replace -output $(TVOS_BIN) $(TVOS_BIN)
	$(LDID) -S$(ENT) $(TVOS_BIN)
	python3 scripts/verify-binary.py --platform tvos

deb-tvos: tvos
	./packaging/build-deb.sh tvos
