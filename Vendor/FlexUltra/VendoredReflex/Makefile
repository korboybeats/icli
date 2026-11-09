include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = libreflex

REFLEX_SWIFT := $(shell find Sources/Reflex -type f -name '*.swift')
ECHO_SWIFT := $(shell find Sources/Echo -type f -name '*.swift')
CECHO_C := $(shell find Sources/CEcho -maxdepth 1 -type f -name '*.c')

libreflex_FILES = $(REFLEX_SWIFT) $(ECHO_SWIFT) $(CECHO_C)
libreflex_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries
# Theos normally copies library targets into its global SDK library directory
# during `stage`. FlexUltra only needs this private runtime dylib in the package,
# so suppress that behavior and stage the built artifact ourselves below.
libreflex_INSTALL = 0
libreflex_CFLAGS = -ISources/CEcho/include -ISources/FLEX/include
libreflex_SWIFTFLAGS = -ISources/CEcho/include -ISources/FLEX/include
libreflex_LIBRARIES = flex
libreflex_FRAMEWORKS = Foundation
libreflex_SWIFT_VERSION = 5

include $(THEOS_MAKE_PATH)/library.mk

after-libreflex-stage::
	@mkdir -p "$(THEOS_STAGING_DIR)$(libreflex_INSTALL_PATH)"
	@cp "$(THEOS_OBJ_DIR)/libreflex.dylib" "$(THEOS_STAGING_DIR)$(libreflex_INSTALL_PATH)/libreflex.dylib"
	@install_name_tool -change '@rpath/Library/MobileSubstrate/DynamicLibraries/libFLEX.dylib' '/var/jb/usr/lib/flexultra/libFLEX.dylib' "$(THEOS_STAGING_DIR)$(libreflex_INSTALL_PATH)/libreflex.dylib"
	@ldid -S "$(THEOS_STAGING_DIR)$(libreflex_INSTALL_PATH)/libreflex.dylib"
	@mkdir -p "$(THEOS_STAGING_DIR)/usr/share/doc/flexultra/reflex"
	@cp UPSTREAM "$(THEOS_STAGING_DIR)/usr/share/doc/flexultra/reflex/UPSTREAM"
	@cp Licenses/* "$(THEOS_STAGING_DIR)/usr/share/doc/flexultra/reflex/"
