// 测试垫片：macOS 没有 <endian.h>。只在小端主机上跑（arm64 / x86_64 都是）。
#pragma once
#if !defined(__LITTLE_ENDIAN__) && !(defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__)
#error "对拍测试只支持小端主机"
#endif
#ifndef htole32
#define htole32(x) (x)
#endif
