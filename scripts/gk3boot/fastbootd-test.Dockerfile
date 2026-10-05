# gk3-fastbootd（S7a）的构建与离线测试环境：静态编译 + loop 盘夹具 + 真 fastboot 主机工具。
# 由 scripts/gk3boot/test-fastbootd.sh 调用；镜像名 fbd-gk3-fastbootd-test。
# ★ 与 gk3boot-build.Dockerfile 同一个 Debian 13 基础镜像（arm64，Mac 上原生）。
# ★ fastboot 主机工具用 Debian 包里的真 fastboot（android-platform-tools），不是我们自己写的客户端 ——
#   测的是"官方主机端看我们的设备端"。img2simg / simg2img 来自 android-sdk-libsparse-utils（libsparse 本体）。
FROM debian@sha256:9cc080028c43b27d2074d63a5f9caf7166d731494965616c1a6d2827a004585c
ARG GK3_DEBIAN_MIRROR=
RUN if [ -n "$GK3_DEBIAN_MIRROR" ]; then \
      sed -i "s|http://deb.debian.org/debian|$GK3_DEBIAN_MIRROR|g" /etc/apt/sources.list.d/debian.sources; fi \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      gcc libc6-dev make binutils python3 \
      fastboot android-sdk-libsparse-utils \
      gdisk fdisk dosfstools mtools util-linux file xxd \
 && rm -rf /var/lib/apt/lists/*
