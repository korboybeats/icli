SHELL := /bin/sh
SDK ?= $(shell xcrun --sdk iphoneos --show-sdk-path)
BUILD := ../../.build/flex
OUTPUT := ../../.build/libicli-flex.dylib
SOURCES := $(shell find Classes -type f \( -name '*.m' -o -name '*.mm' -o -name '*.c' \))
OBJECTS := $(addprefix $(BUILD)/,$(addsuffix .o,$(SOURCES)))
INCLUDES := $(addprefix -I,$(shell find Classes -type d))
FLAGS := -arch arm64 -arch arm64e -isysroot $(SDK) -miphoneos-version-min=15.0 \
	-Os -fobjc-arc -fobjc-weak $(INCLUDES) \
	-Wno-unsupported-availability-guard -Wno-deprecated-declarations \
	-Wno-gnu-folding-constant -Wno-unused-but-set-variable -Wno-duplicate-protocol

.PHONY: all
all: $(OUTPUT)

$(BUILD)/%.o: %
	@mkdir -p $(dir $@)
	xcrun --sdk iphoneos clang $(FLAGS) $(if $(filter %.mm,$<),-std=gnu++11,) -MMD -MP -c $< -o $@

$(OUTPUT): $(OBJECTS) Makefile
	@mkdir -p $(dir $@)
	xcrun --sdk iphoneos clang++ $(FLAGS) -dynamiclib $(OBJECTS) \
		-install_name @rpath/libFLEX.dylib -framework Foundation -framework UIKit \
		-framework CoreGraphics -framework ImageIO -framework QuartzCore -framework WebKit \
		-framework Security -framework SceneKit -lz -lsqlite3 -lc++ -o $@
	ldid -S $@

-include $(OBJECTS:.o=.d)
