# libgk3core 的主机构建与测试（macOS clang / Linux clang 都能跑）。
#
#   make test            主机单测（ASan + UBSan），向量在 test/vectors/
#   make upstream        与真正的 libboot_control.cpp 逐字节对拍（要 refs/，先跑 scripts/clone-refs.sh）
#   make freestanding    按 UEFI 的条件编 aarch64 目标文件，并断言没有任何外部符号依赖（T9）
#   make gk3-misc        主机版只读 CLI（dump misc / gpt / boot.img）
#   make check           以上全部
#
# 可覆盖：REFS=<refs 目录>  BOOTIMG=<完整 boot.img，用来复算整份 SHA1(id)>

ROOT     := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../..)
REFS     ?= $(ROOT)/refs
BOOTIMG  ?= $(wildcard $(ROOT)/out/issues-1791053208/boot.img)
CC       ?= cc
CXX      ?= c++
B        := build

CORE_SRC := $(wildcard core/src/*.c)
WARN     := -Wall -Wextra -Wshadow -Wstrict-prototypes -Wmissing-prototypes -Wno-unused-parameter
SAN      := -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer
HOSTFLAGS:= -std=c11 -O1 -g $(WARN) -Werror -Icore/include $(SAN)

TEST_SRC := $(wildcard test/*.c)

.PHONY: all test upstream freestanding check clean
all: check

$(B):
	mkdir -p $(B)

$(B)/test_core: $(CORE_SRC) $(TEST_SRC) core/include/gk3core.h test/t.h | $(B)
	$(CC) $(HOSTFLAGS) -Wno-missing-prototypes -Itest -o $@ $(CORE_SRC) $(TEST_SRC) -lz

test: $(B)/test_core
	GK3_BOOTIMG="$(BOOTIMG)" ./$(B)/test_core test/vectors

# —— 上游对拍 ——
# -include sys/stat.h：libboot_control.cpp:138 用了 struct stat 却没 include（bionic 里是被间接带进来的）
HI       := $(REFS)/aosp-hardware-interfaces/boot/1.1/default/boot_control
REC      := $(REFS)/lineage-bootable-recovery/bootloader_message/include
UPSTREAM_OK := $(and $(wildcard $(HI)/libboot_control.cpp),$(wildcard $(REC)/bootloader_message/bootloader_message.h))

$(B)/core_san.a: $(CORE_SRC) core/include/gk3core.h | $(B)
	rm -rf $(B)/san && mkdir -p $(B)/san
	cd $(B)/san && for f in $(CORE_SRC); do $(CC) $(HOSTFLAGS) -I$(ROOT)/tools/gk3boot/core/include -c $(ROOT)/tools/gk3boot/$$f || exit 1; done
	ar rcs $@ $(B)/san/*.o

$(B)/test_upstream: test/upstream/test_upstream.cpp $(B)/core_san.a | $(B)
	$(CXX) -std=c++17 -O1 -g $(SAN) -Wall -Wno-unused-parameter \
	    -DBOARD_RECOVERY_BLDRMSG_OFFSET=0 -include sys/stat.h \
	    -Itest/upstream/shim -I$(HI)/include -I$(REC) -Icore/include \
	    -o $@ test/upstream/test_upstream.cpp $(HI)/libboot_control.cpp $(B)/core_san.a

upstream:
ifeq ($(UPSTREAM_OK),)
	@echo "SKIP upstream：$(HI) 或 $(REC) 不在（先跑 bash scripts/clone-refs.sh，或 make REFS=…）"
else
	$(MAKE) $(B)/test_upstream
	./$(B)/test_upstream
endif

# —— freestanding：UEFI（aarch64、无 libc、不用 FP/SIMD 寄存器）的编译条件 ——
FS_TARGET ?= aarch64-unknown-none-elf
FSFLAGS  := --target=$(FS_TARGET) -std=c11 -Os -ffreestanding -fno-builtin -nostdlibinc \
            -fno-stack-protector -fshort-wchar -mgeneral-regs-only -fPIC $(WARN) -Werror -Icore/include

freestanding: | $(B)
	rm -rf $(B)/fs && mkdir -p $(B)/fs
	for f in $(CORE_SRC); do $(CC) $(FSFLAGS) -c $$f -o $(B)/fs/$$(basename $$f .c).o || exit 1; done
	@for o in $(B)/fs/*.o; do nm -u $$o; done | awk '{print $$NF}' | sort -u > $(B)/fs/undef.txt; \
	for o in $(B)/fs/*.o; do nm -g --defined-only $$o; done | awk '{print $$NF}' | sort -u > $(B)/fs/def.txt; \
	undef=$$(comm -23 $(B)/fs/undef.txt $(B)/fs/def.txt); \
	if [ -n "$$undef" ]; then echo "freestanding：目标文件依赖外部符号：$$undef"; exit 1; fi; \
	echo "freestanding：$(FS_TARGET) 目标文件 $$(ls $(B)/fs/*.o | wc -l | tr -d ' ') 个，未定义符号全部在库内解决（不依赖 libc / memcpy / memset）"; \
	size=$$(cat $(B)/fs/*.o | wc -c | tr -d ' '); echo "  目标文件合计 $$size 字节"

# —— CLI ——
$(B)/gk3-misc: misc/gk3-misc.c $(CORE_SRC) core/include/gk3core.h | $(B)
	$(CC) -std=c11 -O2 $(WARN) -Werror -Wno-missing-prototypes -Icore/include -o $@ misc/gk3-misc.c $(CORE_SRC)

gk3-misc: $(B)/gk3-misc

check: test upstream freestanding gk3-misc

clean:
	rm -rf $(B)
