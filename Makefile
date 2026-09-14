ARCHS = arm64 arm64e
TARGET = iphone:clang:13.7:13.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = GlobalTimePitchFix
GlobalTimePitchFix_FILES = Tweak.xm
GlobalTimePitchFix_FRAMEWORKS = Foundation UIKit CoreFoundation
GlobalTimePitchFix_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk

before-package::
	@echo "Building GlobalTimePitchFix 0.2.6 Injection Probe for iOS 13.x (old arm64e ABI toolchain required)."
