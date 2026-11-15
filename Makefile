# SPDX-License-Identifier: GPL-3.0-or-later
# henge-linux top-level build system (macOS Apple Silicon, macOS Intel x86_64, Linux)

UNAME_S := $(shell uname -s)
UNAME_M := $(shell uname -m)

# Auto-detect Homebrew prefix (/opt/homebrew on Apple Silicon, /usr/local on Intel Mac)
BREW_PREFIX := $(shell if [ -d /opt/homebrew ]; then echo /opt/homebrew; elif [ -d /usr/local/Homebrew ] || [ -d /usr/local/Cellar ]; then echo /usr/local; fi)

# Stage-1 software TLB granularity:
#   12 = 4 KiB compatibility mode (boots both 4 KiB and 16 KiB Linux kernels)
#   14 = 16 KiB fast-path mode (4x TLB reach for CONFIG_ARM64_16K_PAGES=y kernels)
HV_TLB_PAGE_BITS ?= 12

CC ?= cc
CFLAGS_COMMON := -std=c11 -O2 -Wall -Wextra -Werror -DHV_TLB_PAGE_BITS=$(HV_TLB_PAGE_BITS) -Ihost

BUILD_DIR := build
UPSTREAM_DIR := .upstream/WindowsiOS

.PHONY: all clean test-core hvsparse ios-lib sync-upstream ios-project

all: test-core hvsparse

$(BUILD_DIR):
	@mkdir -p $(BUILD_DIR)

HOST_SRCS := host/henge_platform.c host/henge_txm_jit.c host/henge_virtio_gpu.c
HOST_HDRS := host/henge_platform.h host/henge_txm_jit.h host/henge_virtio_gpu.h

$(BUILD_DIR)/test_core: tests/test_core.c $(HOST_SRCS) $(HOST_HDRS) | $(BUILD_DIR)
	$(CC) $(CFLAGS_COMMON) -pthread tests/test_core.c $(HOST_SRCS) -o $(BUILD_DIR)/test_core

$(BUILD_DIR)/hvsparse: tools/hvsparse.c | $(BUILD_DIR)
	$(CC) $(CFLAGS_COMMON) tools/hvsparse.c -o $(BUILD_DIR)/hvsparse

hvsparse: $(BUILD_DIR)/hvsparse

test-core: $(BUILD_DIR)/test_core
	./$(BUILD_DIR)/test_core

ios-lib: $(HOST_SRCS) $(HOST_HDRS) host/henge_brk.S | $(BUILD_DIR)
	@mkdir -p $(BUILD_DIR)/ios
	@if [ "$(UNAME_S)" = "Darwin" ]; then \
		set -euo pipefail; \
		IOS_SDK=$$(xcrun --sdk iphoneos --show-sdk-path); \
		IOS_CFLAGS="-std=c11 -O2 -Wall -Wextra -Werror -arch arm64 -mios-version-min=26.0 -isysroot $$IOS_SDK -DHV_TLB_PAGE_BITS=$(HV_TLB_PAGE_BITS) -Ihost"; \
		xcrun --sdk iphoneos clang $$IOS_CFLAGS -c host/henge_platform.c -o $(BUILD_DIR)/ios/henge_platform.o; \
		xcrun --sdk iphoneos clang $$IOS_CFLAGS -c host/henge_txm_jit.c -o $(BUILD_DIR)/ios/henge_txm_jit.o; \
		xcrun --sdk iphoneos clang -arch arm64 -mios-version-min=26.0 -isysroot "$$IOS_SDK" -c host/henge_brk.S -o $(BUILD_DIR)/ios/henge_brk.o; \
		xcrun --sdk iphoneos clang $$IOS_CFLAGS -c host/henge_virtio_gpu.c -o $(BUILD_DIR)/ios/henge_virtio_gpu.o; \
		rm -f $(BUILD_DIR)/ios/libhengelinux.a; \
		ar rcs $(BUILD_DIR)/ios/libhengelinux.a \
			$(BUILD_DIR)/ios/henge_platform.o \
			$(BUILD_DIR)/ios/henge_txm_jit.o \
			$(BUILD_DIR)/ios/henge_brk.o \
			$(BUILD_DIR)/ios/henge_virtio_gpu.o; \
		echo "[ios-lib] Built $(BUILD_DIR)/ios/libhengelinux.a"; \
	else \
		echo "[ios-lib] Skipping iphoneos static archive on non-Darwin host"; \
	fi

sync-upstream:
	bash ./scripts/sync_upstream.sh

ios-project:
	xcodegen generate --spec ios/project.yml

clean:
	rm -rf $(BUILD_DIR) ios/HengeLinux.xcodeproj
