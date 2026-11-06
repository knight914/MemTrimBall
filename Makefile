# Independent official rootless / roothide toolchains; Xcode SDK on macOS.
ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME ?= rootless

MTB_VERSION := $(strip $(shell cat VERSION))
MTB_CONTROL_VERSION := $(strip $(shell python3 -c 'from pathlib import Path; print(next(x.split(":",1)[1].strip() for x in Path("control").read_text().splitlines() if x.startswith("Version:")))'))
ifeq ($(MTB_VERSION),)
$(error VERSION must not be empty)
endif
ifneq ($(MTB_VERSION),$(MTB_CONTROL_VERSION))
$(error VERSION and control Version differ; synchronize before a new build attempt)
endif
ifeq ($(filter $(THEOS_PACKAGE_SCHEME),rootless roothide),)
$(error Expected official rootless or roothide scheme)
endif
ifeq ($(strip $(THEOS)),)
$(error Set THEOS to an independently prepared official theos/theos checkout)
endif
PACKAGE_VERSION = $(MTB_VERSION)

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = MTBBall MTBPreferences
MTBBall_FILES = MTBBall.m MTBEdgeDock.m
MTBBall_CFLAGS = -fobjc-arc -Wall -Wextra
MTBBall_FRAMEWORKS = UIKit Foundation CoreFoundation
MTBPreferences_FILES = MTBPreferences.m
MTBPreferences_CFLAGS = -fobjc-arc -Wall -Wextra
MTBPreferences_FRAMEWORKS = Foundation CoreFoundation
MTBPreferences_PRIVATE_FRAMEWORKS = Preferences
MTBPreferences_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk
# No automatic install, respring, device connection, SDK download or version mutation.
