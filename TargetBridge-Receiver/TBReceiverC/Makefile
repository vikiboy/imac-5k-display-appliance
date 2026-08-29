# TBReceiver pure-C build (macOS target).
#
# Prerequisites on the iMac (Intel) running OCLP macOS 14:
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
#   brew install ffmpeg sdl2 pkgconf
#
# Build:
#   make
#
# Run:
#   ./tbreceiver              # fullscreen
#   ./tbreceiver --windowed   # debug windowed
#
# Linux target (later): identical sources, swap LDFLAGS to pkgconf on
#   libavcodec libavutil sdl2 ; drop -framework lines.

CC       ?= clang
PKG      ?= pkgconf
APP_VERSION ?= 3.5.1
APP_BUILD   ?= dev
CODEC       = ../../TargetBridge-Shared/codec

MACOSX_DEPLOYMENT_TARGET ?= 11.0
export MACOSX_DEPLOYMENT_TARGET

CFLAGS   += -O2 -g -Wall -Wextra -Wno-unused-parameter -std=c11
CFLAGS   += $(shell $(PKG) --cflags libavcodec libavutil libswscale sdl2)
CFLAGS   += -DTB_RECEIVER_VERSION=\"$(APP_VERSION)\" -DTB_RECEIVER_BUILD=\"$(APP_BUILD)\"
CFLAGS   += -DTB_LANGUAGE_SOURCE_DIR=\"$(abspath ../../TargetBridge-Shared/Languages)\"

LDFLAGS  += $(shell $(PKG) --libs libavcodec libavutil libswscale sdl2)

UNAME_S  := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
CFLAGS += -I$(CODEC)
LDFLAGS  += -framework ApplicationServices -framework AppKit -framework CoreFoundation -framework CoreGraphics -framework CoreText -framework VideoToolbox -framework CoreMedia -framework CoreVideo -framework IOSurface -framework CoreServices -framework CoreAudio -framework SystemConfiguration -framework Metal -framework QuartzCore -lc++
endif

C_SRC = src/main.c src/net.c src/decoder.c src/display.c src/input_queue.c src/receiver_profile.c src/renderer_policy.c src/raw_nv12.c src/tb_i18n.c
OBJC_SRC = src/tb_gesture_bridge.m src/tb_display_tweaks.m
OBJCXX_SRC =
CODEC_OBJ =
ifeq ($(UNAME_S),Darwin)
OBJCXX_SRC += src/tb_native_metal_renderer.m
CODEC_OBJ += tb_dpcm.o
endif
OBJ = $(C_SRC:.c=.o) $(OBJC_SRC:.m=.o) $(OBJCXX_SRC:.m=.o) $(CODEC_OBJ)
BIN = tbreceiver

all: $(BIN)

$(BIN): $(OBJ)
	$(CC) -o $@ $(OBJ) $(LDFLAGS)

%.o: %.c
	$(CC) $(CFLAGS) -c -o $@ $<

%.o: %.m
	$(CC) $(CFLAGS) -fobjc-arc -c -o $@ $<

src/tb_native_metal_renderer.o: src/tb_native_metal_renderer.m src/tb_native_metal_renderer.h $(CODEC)/tb_dpcm.h
	$(CC) $(filter-out -std=c11,$(CFLAGS)) -I$(CODEC) -std=c++17 -x objective-c++ -fobjc-arc -c -o $@ $<

tb_dpcm.o: $(CODEC)/tb_dpcm.c $(CODEC)/tb_dpcm.h
	$(CC) $(CFLAGS) -I$(CODEC) -c -o $@ $<

clean:
	rm -f $(OBJ) tb_dpcm_native.o tb_dpcm_universal.o $(BIN) $(TEST_BIN) $(TEST_DPCM_BIN) $(TEST_DPCM_GPU_BIN) $(TEST_INPUT_QUEUE_BIN) $(TEST_RECEIVER_PROFILE_BIN) $(TEST_RENDERER_POLICY_BIN) $(TEST_RAW_NV12_BIN) $(TEST_PRE_SESSION_BIN) $(TEST_SHUTDOWN_GATE_BIN) $(TEST_NATIVE_METAL_BIN) $(BENCH_NATIVE_METAL_BIN) $(BENCH_NATIVE_METAL_UNIVERSAL_BIN) $(BENCH_NETWORK_METAL_UNIVERSAL_BIN) $(BENCH_PROTOCOL_METAL_UNIVERSAL_BIN) $(BENCH_TB_LINK_UNIVERSAL_BIN) $(BENCH_OPENGL_BIN)

# Unit tests for the packet parser and wire codec. Both are pure C, so these
# need no ffmpeg/SDL/pkgconf and run anywhere, including CI, without hardware.
TEST_CFLAGS = -O2 -g -Wall -Wextra -Wno-unused-parameter -std=c11
TEST_LDFLAGS =
ifeq ($(UNAME_S),Darwin)
TEST_LDFLAGS += -framework CoreFoundation -framework SystemConfiguration
endif
TEST_BIN = test_net_parser
TEST_DPCM_BIN = test_dpcm
TEST_DPCM_GPU_BIN = test_dpcm_gpu_lifecycle
TEST_INPUT_QUEUE_BIN = test_input_queue
TEST_RECEIVER_PROFILE_BIN = test_receiver_profile
TEST_RENDERER_POLICY_BIN = test_renderer_policy
TEST_RAW_NV12_BIN = test_raw_nv12
TEST_PRE_SESSION_BIN = test_pre_session
TEST_SHUTDOWN_GATE_BIN = test_shutdown_gate
TEST_NATIVE_METAL_BIN = test_native_metal_renderer
BENCH_NATIVE_METAL_BIN = benchmark_native_metal_renderer
BENCH_NATIVE_METAL_UNIVERSAL_BIN = benchmark_native_metal_renderer_universal
BENCH_NETWORK_METAL_UNIVERSAL_BIN = benchmark_network_metal_receiver_universal
BENCH_PROTOCOL_METAL_UNIVERSAL_BIN = benchmark_targetbridge_raw_receiver_universal
BENCH_TB_LINK_UNIVERSAL_BIN = benchmark_tb_link_universal
BENCH_OPENGL_BIN = benchmark_sdl_opengl_renderer
TEST_PLATFORM_BINS =
ifeq ($(UNAME_S),Darwin)
TEST_PLATFORM_BINS += $(TEST_DPCM_GPU_BIN) $(TEST_NATIVE_METAL_BIN)
endif

tb_dpcm_native.o: $(CODEC)/tb_dpcm.c $(CODEC)/tb_dpcm.h
	$(CC) $(TEST_CFLAGS) -I$(CODEC) -c -o $@ $<

tb_dpcm_universal.o: $(CODEC)/tb_dpcm.c $(CODEC)/tb_dpcm.h
	$(CC) -arch arm64 -arch x86_64 -mmacosx-version-min=11.0 \
		$(TEST_CFLAGS) -I$(CODEC) -c -o $@ $<

test_net_parser: tests/test_net_parser.c src/net.c src/net.h src/proto.h
	$(CC) $(TEST_CFLAGS) -Isrc tests/test_net_parser.c src/net.c $(TEST_LDFLAGS) -o $@

$(TEST_DPCM_BIN): tests/test_dpcm.c $(CODEC)/tb_dpcm.c $(CODEC)/tb_dpcm.h
	$(CC) $(TEST_CFLAGS) -I$(CODEC) tests/test_dpcm.c $(CODEC)/tb_dpcm.c -o $@

$(TEST_DPCM_GPU_BIN): tests/test_dpcm_gpu_lifecycle.m $(CODEC)/tb_dpcm_gpu.m $(CODEC)/tb_dpcm_gpu.h $(CODEC)/tb_dpcm.c $(CODEC)/tb_dpcm.h
	$(CC) -O2 -g -Wall -Wextra -Werror -std=gnu11 -fobjc-arc -DTB_DPCM_GPU_TESTING \
		-I$(CODEC) tests/test_dpcm_gpu_lifecycle.m $(CODEC)/tb_dpcm_gpu.m $(CODEC)/tb_dpcm.c \
		-framework Foundation -framework Metal -o $@

$(TEST_INPUT_QUEUE_BIN): tests/test_input_queue.c src/input_queue.c src/input_queue.h
	$(CC) $(TEST_CFLAGS) -Isrc tests/test_input_queue.c src/input_queue.c -o $@

$(TEST_RECEIVER_PROFILE_BIN): tests/test_receiver_profile.c src/receiver_profile.c src/receiver_profile.h
	$(CC) $(TEST_CFLAGS) -Isrc tests/test_receiver_profile.c src/receiver_profile.c -o $@

$(TEST_RENDERER_POLICY_BIN): tests/test_renderer_policy.c src/renderer_policy.c src/renderer_policy.h
	$(CC) $(TEST_CFLAGS) -Isrc tests/test_renderer_policy.c src/renderer_policy.c -lm -o $@

$(TEST_RAW_NV12_BIN): tests/test_raw_nv12.c src/raw_nv12.c src/raw_nv12.h
	$(CC) $(TEST_CFLAGS) -Isrc tests/test_raw_nv12.c src/raw_nv12.c -o $@

$(TEST_PRE_SESSION_BIN): tests/test_pre_session.c src/tb_pre_session.c src/tb_pre_session.h
	$(CC) $(TEST_CFLAGS) -Isrc tests/test_pre_session.c src/tb_pre_session.c -o $@

$(TEST_SHUTDOWN_GATE_BIN): tests/test_shutdown_gate.c src/tb_shutdown_gate.c src/tb_shutdown_gate.h
	$(CC) $(TEST_CFLAGS) -Werror -Isrc tests/test_shutdown_gate.c src/tb_shutdown_gate.c -o $@

$(TEST_NATIVE_METAL_BIN): tests/test_native_metal_renderer.m src/tb_native_metal_renderer.m src/tb_native_metal_renderer.h tb_dpcm_native.o
	$(CC) -O2 -g -Wall -Wextra -Isrc -I$(CODEC) -std=c++17 -x objective-c++ -fobjc-arc -DTB_NATIVE_METAL_TESTING \
		tests/test_native_metal_renderer.m src/tb_native_metal_renderer.m -x none tb_dpcm_native.o \
		-framework AppKit -framework CoreVideo -framework IOSurface -framework Metal -framework QuartzCore -lc++ -o $@

$(BENCH_NATIVE_METAL_BIN): benchmarks/benchmark_native_metal_renderer.m src/tb_native_metal_renderer.m src/tb_native_metal_renderer.h src/renderer_policy.c src/renderer_policy.h tb_dpcm_native.o
	$(CC) -O2 -g -Wall -Wextra -Isrc -I$(CODEC) -std=c++17 -x objective-c++ -fobjc-arc \
		benchmarks/benchmark_native_metal_renderer.m src/tb_native_metal_renderer.m src/renderer_policy.c -x none tb_dpcm_native.o \
		-framework AppKit -framework CoreVideo -framework IOSurface -framework Metal -framework QuartzCore -lc++ -o $@

$(BENCH_NATIVE_METAL_UNIVERSAL_BIN): benchmarks/benchmark_native_metal_renderer.m src/tb_native_metal_renderer.m src/tb_native_metal_renderer.h src/renderer_policy.c src/renderer_policy.h tb_dpcm_universal.o
	$(CC) -arch arm64 -arch x86_64 -mmacosx-version-min=11.0 \
		-O2 -g -Wall -Wextra -Isrc -I$(CODEC) -std=c++17 -x objective-c++ -fobjc-arc \
		benchmarks/benchmark_native_metal_renderer.m src/tb_native_metal_renderer.m src/renderer_policy.c -x none tb_dpcm_universal.o \
		-framework AppKit -framework CoreVideo -framework IOSurface -framework Metal -framework QuartzCore -lc++ -o $@

benchmark-metal: $(BENCH_NATIVE_METAL_BIN)
	./$(BENCH_NATIVE_METAL_BIN)

benchmark-metal-universal: $(BENCH_NATIVE_METAL_UNIVERSAL_BIN)
	@file ./$(BENCH_NATIVE_METAL_UNIVERSAL_BIN)

$(BENCH_NETWORK_METAL_UNIVERSAL_BIN): benchmarks/benchmark_network_metal_receiver.m src/tb_native_metal_renderer.m src/tb_native_metal_renderer.h tb_dpcm_universal.o
	$(CC) -arch arm64 -arch x86_64 -mmacosx-version-min=11.0 \
		-O2 -g -Wall -Wextra -Werror -Isrc -I$(CODEC) -std=c++17 -x objective-c++ -fobjc-arc \
		benchmarks/benchmark_network_metal_receiver.m src/tb_native_metal_renderer.m -x none tb_dpcm_universal.o \
		-framework AppKit -framework CoreVideo -framework IOSurface -framework Metal -framework QuartzCore -lc++ -o $@

$(BENCH_PROTOCOL_METAL_UNIVERSAL_BIN): benchmarks/benchmark_targetbridge_raw_receiver.m src/raw_nv12.c src/raw_nv12.h src/tb_native_metal_renderer.m src/tb_native_metal_renderer.h src/tb_power_lifecycle.c src/tb_power_lifecycle.h src/tb_pre_session.c src/tb_pre_session.h src/tb_shutdown_gate.c src/tb_shutdown_gate.h tb_dpcm_universal.o
	$(CC) -arch arm64 -arch x86_64 -mmacosx-version-min=11.0 \
		-O2 -g -Wall -Wextra -Werror -Isrc -I$(CODEC) -std=c++17 -x objective-c++ -fobjc-arc \
		benchmarks/benchmark_targetbridge_raw_receiver.m src/raw_nv12.c src/tb_native_metal_renderer.m src/tb_power_lifecycle.c src/tb_pre_session.c src/tb_shutdown_gate.c -x none tb_dpcm_universal.o \
		-framework AppKit -framework CoreVideo -framework IOSurface -framework IOKit -framework Metal -framework QuartzCore -framework SystemConfiguration -lc++ -o $@

$(BENCH_TB_LINK_UNIVERSAL_BIN): benchmark_tb_link.c
	$(CC) -arch arm64 -arch x86_64 -mmacosx-version-min=11.0 \
		-O3 -g -Wall -Wextra -Werror benchmark_tb_link.c -o $@

benchmark-network-metal-universal: $(BENCH_NETWORK_METAL_UNIVERSAL_BIN) $(BENCH_PROTOCOL_METAL_UNIVERSAL_BIN) $(BENCH_TB_LINK_UNIVERSAL_BIN)
	@file ./$(BENCH_NETWORK_METAL_UNIVERSAL_BIN)
	@file ./$(BENCH_PROTOCOL_METAL_UNIVERSAL_BIN)
	@file ./$(BENCH_TB_LINK_UNIVERSAL_BIN)

$(BENCH_OPENGL_BIN): benchmarks/benchmark_sdl_opengl_renderer.c
	$(CC) -O2 -g -Wall -Wextra $(shell $(PKG) --cflags sdl2) \
		benchmarks/benchmark_sdl_opengl_renderer.c $(shell $(PKG) --libs sdl2) -o $@

benchmark-opengl: $(BENCH_OPENGL_BIN)
	./$(BENCH_OPENGL_BIN)

test: $(TEST_BIN) $(TEST_DPCM_BIN) $(TEST_INPUT_QUEUE_BIN) $(TEST_RECEIVER_PROFILE_BIN) $(TEST_RENDERER_POLICY_BIN) $(TEST_RAW_NV12_BIN) $(TEST_PRE_SESSION_BIN) $(TEST_SHUTDOWN_GATE_BIN) $(TEST_PLATFORM_BINS)
	./$(TEST_BIN)
	./$(TEST_DPCM_BIN)
	./$(TEST_INPUT_QUEUE_BIN)
	./$(TEST_RECEIVER_PROFILE_BIN)
	./$(TEST_RENDERER_POLICY_BIN)
	./$(TEST_RAW_NV12_BIN)
	./$(TEST_PRE_SESSION_BIN)
	./$(TEST_SHUTDOWN_GATE_BIN)
	/bin/zsh tests/test_receiver_installer_order.zsh ../scripts/install_targetbridge_5k_receiver_launch_agent.sh
ifeq ($(UNAME_S),Darwin)
	./$(TEST_DPCM_GPU_BIN)
	./$(TEST_NATIVE_METAL_BIN)
endif

.PHONY: all clean test benchmark-metal benchmark-metal-universal benchmark-network-metal-universal benchmark-opengl
