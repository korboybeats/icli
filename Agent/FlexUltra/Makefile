SHELL := /bin/sh
ROOT := ../..
SDK ?= $(shell xcrun --sdk iphoneos --show-sdk-path)
GENERATED := $(ROOT)/.build/flexultra-src
VENDOR := $(ROOT)/Vendor/FlexUltra
OBJSEE := $(VENDOR)/ThirdParty/ObjSee
BUILD := $(ROOT)/.build/flexultra-objects
OUTPUT := $(ROOT)/.build/libicli-flexultra.dylib
AGENT_SOURCES := $(wildcard $(GENERATED)/Agent/*.m) $(GENERATED)/Shared/IcliFUProtocol.m ICLIFlexPaths.m ICLIFlexLog.m ICLIOSLogController.m
OBJSEE_SOURCES := $(shell find $(OBJSEE)/src/libobjsee -type f \( -name '*.c' -o -name '*.m' \) ! -path '*/injection/*' ! -path '*/springboard/*' ! -path '*/workarounds/*') $(OBJSEE)/dependencies/yyjson/src/yyjson.c $(OBJSEE)/src/libobjsee/interception/arm64.s
SOURCES := $(AGENT_SOURCES) $(OBJSEE_SOURCES)
OBJECTS := $(addprefix $(BUILD)/,$(addsuffix .o,$(notdir $(SOURCES))))
INCLUDES := -I. -I$(GENERATED) -I$(GENERATED)/Agent -I$(GENERATED)/Shared -I$(OBJSEE) -I$(OBJSEE)/dependencies/yyjson/src $(addprefix -I,$(shell find $(OBJSEE)/src/libobjsee -type d))
FLAGS := -arch arm64 -arch arm64e -isysroot $(SDK) -miphoneos-version-min=15.0 -Os $(INCLUDES) -DFU_AGENT_BUILD_ID='@ICLI_FULL_FLEX_BUILD' -include $(GENERATED)/ICLIFlexBuild.h -Wno-deprecated-declarations -Wno-unused-function -Wno-unused-variable -Wno-incompatible-pointer-types-discards-qualifiers

.PHONY: all
all: $(OUTPUT)

# Basenames are unique in the pinned source. Check this during preparation.
define compile
$(BUILD)/$(notdir $(1)).o: $(1) $(GENERATED)/ICLIFlexBuild.h
	@mkdir -p $(BUILD)
	xcrun --sdk iphoneos clang $(FLAGS) $(if $(filter %.m,$(1)),-fobjc-arc -fobjc-weak,) $(if $(filter %.s,$(1)),,-include ICLIFlexCompat.h -include ICLIFlexLog.h -DNSLog=ICLIFlexFileLog) -MMD -MP -c $$< -o $$@
endef
$(foreach source,$(SOURCES),$(eval $(call compile,$(source))))

$(OUTPUT): $(OBJECTS) Makefile
	xcrun --sdk iphoneos clang $(FLAGS) -dynamiclib $(OBJECTS) -framework Foundation -framework UIKit -framework CoreFoundation -framework Security -framework CoreGraphics -install_name @rpath/libicli-flexultra.dylib -o $@
	ldid -S $@

-include $(OBJECTS:.o=.d)
