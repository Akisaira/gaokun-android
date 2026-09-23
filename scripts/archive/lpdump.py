import struct, sys
f = open("/dev/nvme0n1p8", "rb")

f.seek(4096); g = f.read(4096)
magic, struct_sz, chk, mmax, slots, lbs = struct.unpack_from("<II32sIII", g, 0)
ok = "OK" if magic == 0x616c4467 else "BAD"
print("geometry magic   0x%08x  %s" % (magic, ok))
print("metadata max     %d" % mmax)
print("slot count       %d" % slots)
print("logical blk size %d" % lbs)

found = False
for off in (4096*2, 4096*3, 4096*2 + mmax*0):
    f.seek(off); h = f.read(512)
    hmagic, maj, mnr, hsz = struct.unpack_from("<IHHI", h, 0)
    if hmagic == 0x414C5030:
        found = True
        print("\nmetadata magic   0x%08x OK  (offset %d)" % (hmagic, off))
        print("version          %d.%d   header size %d" % (maj, mnr, hsz))
        p_off, p_num, p_sz = struct.unpack_from("<III", h, 80)
        print("partition table  off=%d count=%d entrysz=%d" % (p_off, p_num, p_sz))
        f.seek(off + hsz + p_off)
        print("\nlogical partitions:")
        for i in range(p_num):
            e = f.read(p_sz)
            name = e[:36].split(b"\x00")[0].decode("utf-8", "replace")
            attr, fe, ne, grp = struct.unpack_from("<IIII", e, 36)
            print("  %-18s extents=%d group=%d" % (name, ne, grp))
        break
if not found:
    print("\nmetadata header NOT found at expected offsets")
    for off in (4096*2, 4096*3):
        f.seek(off)
        print("  offset %d: %s" % (off, f.read(16).hex()))
