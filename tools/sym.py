"""Symbolize kernel addresses against a Mach-O XNU kernel (no macOS toolchain needed).

    python tools/sym.py kernel.development.songyuan 0xfffffff007359e3c 0xfffffff007359d84

Prints `symbol+0xoffset` for the nearest preceding symbol, plus the section it lives in.
handy for panic screens: pc / lr / caller / backtrace frames.
"""
import struct
import sys

MH_MAGIC_64 = 0xfeedfacf
LC_SYMTAB = 0x2
LC_SEGMENT_64 = 0x19
LC_FUNCTION_STARTS = 0x26
N_STAB = 0xe0


def load(path):
    data = open(path, 'rb').read()
    magic, cputype, cpusub, filetype, ncmds, sizeofcmds, flags, _ = struct.unpack_from('<IiiIIIII', data, 0)
    if magic != MH_MAGIC_64:
        raise SystemExit('not a 64-bit Mach-O')
    off = 32
    syms = []
    sections = []          # (addr, size, segname, sectname)
    fun_starts = []
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from('<II', data, off)
        if cmd == LC_SYMTAB:
            symoff, nsyms, stroff, strsize = struct.unpack_from('<IIII', data, off + 8)
            strtab = data[stroff:stroff + strsize]
            for i in range(nsyms):
                p = symoff + i * 16
                n_strx, n_type, n_sect, n_desc, n_value = struct.unpack_from('<IBBHQ', data, p)
                if n_type & N_STAB:
                    continue
                end = strtab.find(b'\0', n_strx)
                name = strtab[n_strx:end].decode('utf-8', 'replace')
                if name:
                    syms.append((n_value, name, n_type & 0x0e))
        elif cmd == LC_SEGMENT_64:
            segname = data[off + 8:off + 24].split(b'\0')[0].decode()
            nsects = struct.unpack_from('<I', data, off + 64)[0]
            so = off + 72
            for _s in range(nsects):
                sectname = data[so:so + 16].split(b'\0')[0].decode()
                addr, size = struct.unpack_from('<QQ', data, so + 32)
                sections.append((addr, size, segname, sectname))
                so += 80
        elif cmd == LC_FUNCTION_STARTS:
            dataoff, datasize = struct.unpack_from('<II', data, off + 8)
            # ULEB128 deltas from __TEXT start
            base = None
            for a, _sz, seg, _s in sections:
                if seg == '__TEXT':
                    base = a if base is None else min(base, a)
            cur = base or 0
            p, end = dataoff, dataoff + datasize
            while p < end:
                delta = 0
                shift = 0
                while True:
                    b = data[p]
                    p += 1
                    delta |= (b & 0x7f) << shift
                    shift += 7
                    if not b & 0x80:
                        break
                if delta == 0:
                    break
                cur += delta
                fun_starts.append(cur)
        off += cmdsize
    syms.sort()
    return syms, sections, fun_starts


def section_of(addr, sections):
    for a, size, seg, sect in sections:
        if a <= addr < a + size:
            return f'{seg},{sect}'
    return '?'


def lookup(addr, syms, fun_starts):
    lo, hi = 0, len(syms)
    while lo < hi:
        mid = (lo + hi) // 2
        if syms[mid][0] <= addr:
            lo = mid + 1
        else:
            hi = mid
    cand = syms[lo - 1] if lo else None
    start = None
    for f in fun_starts:
        if f <= addr:
            start = f
        else:
            break
    if cand and (start is None or cand[0] >= start):
        return cand[1], addr - cand[0]
    if start is not None:
        return '<local>', addr - start
    return '?', 0


def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    syms, sections, fun_starts = load(sys.argv[1])
    for a in sys.argv[2:]:
        addr = int(a, 16)
        name, delta = lookup(addr, syms, fun_starts)
        print(f'{addr:#018x}  {name}+{delta:#x}  [{section_of(addr, sections)}]')


if __name__ == '__main__':
    main()
