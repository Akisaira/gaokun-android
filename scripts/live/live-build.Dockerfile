# 造 Debian 根文件系统 / initramfs / U 盘镜像的构建环境。由 scripts/live/build-live.sh 调用。
# ★ arm64：Mac（Apple Silicon）上原生，mmdebstrap 造 arm64 根文件系统不需要 qemu。
# gcc libc6-dev：build-rootfs.sh 把 tools/gk3boot/misc/gk3-misc.c 静态编进镜像（安装器初始化 misc 用，S10）
FROM debian@sha256:9cc080028c43b27d2074d63a5f9caf7166d731494965616c1a6d2827a004585c
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      mmdebstrap squashfs-tools cpio file mtools gdisk dosfstools zstd python3 ca-certificates util-linux gcc libc6-dev \
 && rm -rf /var/lib/apt/lists/*
