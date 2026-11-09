include $(THEOS)/makefiles/common.mk

OBJSEE_ROOT := ../ThirdParty/ObjSee
OBJSEE_INCLUDE_DIRS := $(shell find $(OBJSEE_ROOT)/src/libobjsee -type d)
OBJSEE_INCLUDE_FLAGS := $(OBJSEE_INCLUDE_DIRS:%=-I%)
OBJSEE_CORE_FILES := $(shell find $(OBJSEE_ROOT)/src/libobjsee -type f \( -name '*.c' -o -name '*.m' \) \
	! -path '*/injection/*' ! -path '*/springboard/*' ! -path '*/workarounds/*')
FLEXULTRA_AGENT_BUILD_ID := $(shell python3 ../scripts/agent_build_id.py --root ..)

TWEAK_NAME = FlexUltraAgent
FlexUltraAgent_FILES = FUAgent.m FURequestDispatcher.m FUDefaults.m FUExperiments.m FUHeap.m FUObjectRegistry.m FUObjectSerialization.m FUObjectInspection.m FUSwiftInspection.m FUInvestigation.m FUFlexTools.m FUKeychain.m FURuntime.m FUStorage.m FUTrace.m FUUI.m ../Shared/FUProtocol.m $(OBJSEE_CORE_FILES) \
	$(OBJSEE_ROOT)/dependencies/yyjson/src/yyjson.c \
	$(OBJSEE_ROOT)/src/libobjsee/interception/arm64.s
FlexUltraAgent_CFLAGS = -fobjc-arc -I../Shared -I$(OBJSEE_ROOT) $(OBJSEE_INCLUDE_FLAGS) \
	-I$(OBJSEE_ROOT)/dependencies/yyjson/src -Wno-deprecated-declarations -Wno-unused-function \
	-DFU_AGENT_BUILD_ID='@"$(FLEXULTRA_AGENT_BUILD_ID)"'
FlexUltraAgent_FRAMEWORKS = Foundation UIKit CoreFoundation
msgSend_hook.c_CFLAGS = -fno-objc-arc -O2

include $(THEOS_MAKE_PATH)/tweak.mk
