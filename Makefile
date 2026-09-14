ARCHS = arm64 arm64e
TARGET = iphone:clang:13.7:13.0
INSTALL_TARGET_PROCESSES = Bilibili

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = GlobalTimePitchFix
GlobalTimePitchFix_FILES = Tweak.xm vendor/vlc_scaletempo/GTScaleTempo.cpp
GlobalTimePitchFix_CFLAGS = -fobjc-arc -O3 -Ivendor/vlc_scaletempo
GlobalTimePitchFix_CCFLAGS = -O3 -Ivendor/vlc_scaletempo
GlobalTimePitchFix_LDFLAGS = -lm
GlobalTimePitchFix_FRAMEWORKS = Foundation UIKit

include $(THEOS_MAKE_PATH)/tweak.mk
