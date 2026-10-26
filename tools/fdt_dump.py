#!/usr/bin/env python3
"""Dump a flattened device tree (FDT/dtb) as text, filtered by path substring.

Why: the phone's live DT is the ground truth for board constants (splash region,
panel timing, UFS/GMU/SMMU/USB base addresses). `/sys/firmware/fdt` is the raw blob:

    adb shell "su -c 'dd if=/sys/firmware/fdt of=/data/local/tmp/fdt.bin'"
    adb pull /data/local/tmp/fdt.bin songyuan-fdt.dtb
    python tools/fdt_dump.py songyuan-fdt.dtb panel display splash usb

Usage:  fdt_dump.py FILE.dtb [substring ...]     (no filter = whole tree)
"""
import struct
import sys


def load(path):
    blob = open(path, 'rb').read()
    magic, _total, off_struct, off_strings, _off_rsv, ver, _last, _cpu, size_strings, _size_struct = \
        struct.unpack('>10I', blob[:40])
    if magic != 0xd00dfeed:
        raise SystemExit('%s: not an FDT (magic 0x%08x)' % (path, magic))
    if ver < 16:
        print('warning: FDT version %d, cells may be missing' % ver, file=sys.stderr)
    return blob, off_struct, blob[off_strings:off_strings + size_strings]


def walk(blob, off_struct, strs):
    """Yield (path, prop_name, raw_bytes) in tree order."""
    pos = off_struct
    stack = []

    def name(off):
        end = strs.index(b'\0', off)
        return strs[off:end].decode('ascii', 'replace')

    while True:
        tag = struct.unpack('>I', blob[pos:pos + 4])[0]
        pos += 4
        if tag == 1:                                        # FDT_BEGIN_NODE
            end = blob.index(b'\0', pos)
            stack.append(blob[pos:end].decode('ascii', 'replace'))
            pos = (end + 4) & ~3
        elif tag == 2:                                      # FDT_END_NODE
            stack.pop()
        elif tag == 3:                                      # FDT_PROP
            ln, nameoff = struct.unpack('>II', blob[pos:pos + 8])
            pos += 8
            data = blob[pos:pos + ln]
            pos = (pos + ln + 3) & ~3
            yield '/' + '/'.join(stack[1:]), name(nameoff), data
        elif tag == 4:                                      # FDT_NOP
            pass
        elif tag == 9:                                      # FDT_END
            return
        else:
            raise SystemExit('bad FDT tag %d at offset %d' % (tag, pos))


def show(path, name, data):
    if not data:
        print('  %-34s <bool true>' % name)
        return
    printable = all((32 <= c < 127) or c == 0 for c in data)
    if printable and b'\0' in data:
        print('  %-34s "%s"' % (name, data.replace(b'\0', b' ').decode().strip()))
    elif len(data) % 4 == 0 and len(data) <= 64:
        words = struct.unpack('>%dI' % (len(data) // 4), data)
        print('  %-34s [%d] %s' % (name, len(data), ' '.join('%x' % w for w in words)))
    else:
        print('  %-34s [%d] %s' % (name, len(data), data.hex()))


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    blob, off_struct, strs = load(sys.argv[1])
    want = [a.lower() for a in sys.argv[2:]]
    seen = None
    for path, name, data in walk(blob, off_struct, strs):
        if want and not any(w in path.lower() for w in want):
            continue
        if path != seen:
            print('\n### %s' % path)
            seen = path
        show(path, name, data)


if __name__ == '__main__':
    main()
