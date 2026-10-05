# gk3boot 的 UEFI 程序（aarch64 PE），在 scripts/gk3boot/gk3boot-build.Dockerfile 的容器里构建：
#
#   make -C tools/gk3boot/efi                 → tools/gk3boot/build/efi/{gk3boot,gk3probe,gk3probe-child,gk3-fake-android}.efi
#   make -C tools/gk3boot/efi VERSION=<串>     探针里打印的版本（scripts/gk3boot/test-probe.sh 传 git 描述）
#   make -C tools/gk3boot/efi BOOT_VERSION=<串> gk3boot 的版本（进 androidboot.bootloader=gk3boot-<串>，
#                                              只准 [A-Za-z0-9._+-]；scripts/gk3boot/test-boot.sh 传 0.2.0-e5.g<提交>）
#
# 工具链选 gnu-efi（Debian 包 gnu-efi 3.0.18）而不是 EDK2，理由见 tools/gk3boot/README.md §9.1：
# 一个包、一条 gcc 命令就能把 freestanding 的 libgk3core 原样链进来；EDK2 要 BaseTools + .inf/.dsc
# 包装，而我们只用它几个协议结构体。这里只用 gnu-efi 的头文件、crt0 与 libgnuefi（自重定位），
# 不链接 libefi（GUID、格式化、设备路径都在 lib/gk3efi.c 自己写）。

GK3      := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/..)
B        := $(GK3)/build/efi
VERSION  ?= dev
BOOT_VERSION ?= dev
# gk3boot 的 BCB 分派开关缺省值（条目 options 里的 gk3.dispatch=0|1 优先）。E-K7：只有与执行端（S7）、迁移
# 同版发布时才改成 1；改了要连同版本串一起变（.version 只跟 BOOT_VERSION，这里改了请先 make clean）
DISPATCH_DEFAULT ?= 0
EFIINC   ?= /usr/include/efi
EFILIB   ?= /usr/lib
CC       := gcc
LD       := ld
OBJCOPY  := objcopy

CFLAGS   := -std=gnu11 -O2 -g -fpic -fshort-wchar -fno-strict-aliasing -ffreestanding -fno-builtin \
            -fno-stack-protector -fno-stack-check -fno-merge-all-constants -fno-asynchronous-unwind-tables \
            -fno-unwind-tables -mgeneral-regs-only -mstrict-align \
            -Wall -Wextra -Wno-unused-parameter -Wno-missing-field-initializers -Werror \
            -I$(EFIINC) -I$(EFIINC)/aarch64 -I$(GK3)/core/include -I$(GK3)/efi/lib -I$(GK3)/efi/probe
LDFLAGS  := -nostdlib -znocombreloc -z noexecstack -T $(EFILIB)/elf_aarch64_efi.lds -shared -Bsymbolic \
            --no-undefined --build-id=sha1 -L$(EFILIB) $(EFILIB)/crt0-efi-aarch64.o
LIBS     := -lgnuefi
# 只拷进 PE 的段（gnu-efi 的惯例）；--subsystem=10 = EFI application
SECTIONS := -j .text -j .sdata -j .data -j .dynamic -j .rodata -j .rel -j .rela -j .rel.* -j .rela.* -j .reloc

CORE_SRC := $(wildcard $(GK3)/core/src/*.c)
CORE_OBJ := $(patsubst $(GK3)/core/src/%.c,$(B)/core/%.o,$(CORE_SRC))
LIB_OBJ  := $(B)/lib/gk3efi.o

# 夹具用的假内核总是有；探针（S4）、入口（S5）的源码在才编
PROGS    := $(B)/gk3-fake-android.efi $(B)/gk3-fake-windows.efi
ifneq ($(wildcard $(GK3)/efi/probe/gk3probe.c),)
PROGS    += $(B)/gk3probe.efi $(B)/gk3probe-child.efi
endif
ifneq ($(wildcard $(GK3)/efi/boot/gk3boot.c),)
PROGS    += $(B)/gk3boot.efi
endif

.PHONY: all clean check FORCE_BOOT_VERSION
all: $(PROGS) check

$(B)/core/%.o: $(GK3)/core/src/%.c $(GK3)/core/include/gk3core.h
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -c $< -o $@

$(B)/lib/%.o: $(GK3)/efi/lib/%.c $(GK3)/efi/lib/gk3efi.h $(GK3)/core/include/gk3core.h
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -c $< -o $@

$(B)/probe/%.o: $(GK3)/efi/probe/%.c $(GK3)/efi/lib/gk3efi.h $(GK3)/efi/probe/child_abi.h
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -DGK3PROBE_VERSION='"$(VERSION)"' -c $< -o $@

$(B)/boot/%.o: $(GK3)/efi/boot/%.c $(GK3)/efi/lib/gk3efi.h $(GK3)/efi/boot/handoff.h $(GK3)/core/include/gk3core.h
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -I$(GK3)/efi/boot -DGK3BOOT_VERSION='"$(BOOT_VERSION)"' \
	    -DGK3BOOT_DISPATCH_DEFAULT=$(DISPATCH_DEFAULT) -c $< -o $@

# 版本串变了就重编 gk3boot.c（版本进二进制，也进 cmdline）：.version 只在内容变时才换 mtime
$(B)/boot/.version: FORCE_BOOT_VERSION
	@mkdir -p $(dir $@)
	@echo '$(BOOT_VERSION)' | cmp -s - $@ || echo '$(BOOT_VERSION)' > $@
FORCE_BOOT_VERSION:
$(B)/boot/gk3boot.o: $(B)/boot/.version

$(B)/gk3boot.so: $(B)/boot/gk3boot.o $(B)/boot/handoff.o $(LIB_OBJ) $(CORE_OBJ)
	$(LD) $(LDFLAGS) $^ -o $@ $(LIBS)

$(B)/qemu/%.o: $(GK3)/qemu/%.c $(GK3)/efi/lib/gk3efi.h
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -c $< -o $@

# 测试 PE：故意不链 libgk3core / gk3efi，越小越好
$(B)/gk3probe-child.so: $(B)/probe/child.o
	$(LD) $(LDFLAGS) $^ -o $@ $(LIBS)

$(B)/probe/child_blob.o: $(GK3)/efi/probe/child_blob.S $(B)/gk3probe-child.efi
	@mkdir -p $(dir $@)
	$(CC) -c -DCHILD_PE='"$(B)/gk3probe-child.efi"' $< -o $@

$(B)/gk3probe.so: $(B)/probe/gk3probe.o $(B)/probe/child_blob.o $(LIB_OBJ) $(CORE_OBJ)
	$(LD) $(LDFLAGS) $^ -o $@ $(LIBS)

$(B)/gk3-fake-android.so: $(B)/qemu/fake-android.o $(LIB_OBJ) $(CORE_OBJ)
	$(LD) $(LDFLAGS) $^ -o $@ $(LIBS)

# S15：同一份源码换个标记，冒充 ESP 上的 \EFI\Microsoft\Boot\bootmgfw.efi（双系统场景，qemu/run-boot-tests.sh dual-*）
$(B)/qemu/fake-windows.o: $(GK3)/qemu/fake-android.c $(GK3)/efi/lib/gk3efi.h
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -DGK3_FAKE_WHO='"WINDOWS"' -c $< -o $@

$(B)/gk3-fake-windows.so: $(B)/qemu/fake-windows.o $(LIB_OBJ) $(CORE_OBJ)
	$(LD) $(LDFLAGS) $^ -o $@ $(LIBS)

$(B)/%.efi: $(B)/%.so
	$(OBJCOPY) $(SECTIONS) --target efi-app-aarch64 --subsystem=10 $< $@

# 产物自检：PE32+、aarch64、EFI application、段齐全；.so 里没有未解析的符号（--no-undefined 已保证，这里再看一眼）
check: $(PROGS)
	@for f in $^; do \
	    objdump -p $$f | grep -q 'Subsystem.*0000000a' || { echo "✗ $$f 不是 EFI application"; exit 1; }; \
	    objdump -p $$f | grep -q 'file format pei-aarch64-little' || { echo "✗ $$f：$$(file -b $$f)"; exit 1; }; \
	    objdump -p $$f | grep -q 'Magic.*020b' || { echo "✗ $$f 不是 PE32+"; exit 1; }; \
	    echo "✓ $$(basename $$f)  $$(stat -c %s $$f) 字节  $$(sha256sum $$f | cut -c1-16)…"; \
	done

clean:
	rm -rf $(B)
