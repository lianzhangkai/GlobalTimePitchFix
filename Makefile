ARCHS = arm64 arm64e
TARGET = iphone:clang:13.7:13.0
INSTALL_TARGET_PROCESSES = Bilibili

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = GlobalTimePitchFix
GlobalTimePitchFix_FILES = Tweak.xm
GlobalTimePitchFix_CFLAGS = -fobjc-arc
GlobalTimePitchFix_FRAMEWORKS = Foundation AudioToolbox

include $(THEOS_MAKE_PATH)/tweak.mk
