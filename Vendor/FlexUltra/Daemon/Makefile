include $(THEOS)/makefiles/common.mk

FLEXULTRA_AGENT_BUILD_ID := $(shell python3 ../scripts/agent_build_id.py --root ..)

TOOL_NAME = flexultrad
flexultrad_FILES = main.m ../Shared/FUProtocol.m
flexultrad_CFLAGS = -fobjc-arc -I../Shared -DFU_EXPECTED_AGENT_BUILD_ID='@"$(FLEXULTRA_AGENT_BUILD_ID)"'
flexultrad_FRAMEWORKS = Foundation
flexultrad_INSTALL_PATH = /usr/libexec

include $(THEOS_MAKE_PATH)/tool.mk
