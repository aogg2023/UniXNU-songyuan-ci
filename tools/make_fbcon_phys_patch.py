"""Build 0214-songyuan-fbcon-phys.patch.

fbcon_init() runs at STARTUP_RANK_FIRST, before pmap_bootstrap, so
ml_io_map_wcomb() hands back an IO KVA that has no page table entry yet; the first
clear-row write faults (QEMU: pc=_fbcon_init+0xb4 far=0xfffffff082300000), the fault
handler calls vm_fault(NULL), and that recurses until the exception stack overflows.
The framebuffer sits inside the DRAM window the loader mapped 1:1, so use the
physical address as the early console pointer for SONGYUAN.
"""
import os
import shutil
import subprocess
import sys

WORK = os.path.join(r'E:\songyuan\work', 'fbconbuild-' + str(os.getpid()))
SRC = r'E:\\songyuan\\work\\pebuild\\pexpert\\arm\\pe_serial.c'
PEX = 'pexpert/arm/pe_serial.c'

OLD = '\tfbcon_base = (volatile uint32_t *)ml_io_map_wcomb(reg[0], reg[1]);\n'
NEW = '''#if defined(SONGYUAN)
\t/*
\t * fbcon_init runs before pmap_bootstrap: ml_io_map_wcomb() returns a KVA with no
\t * page table entry yet and the first clear-row write faults.  The framebuffer is
\t * inside the DRAM window the loader mapped 1:1, so use the physical address.
\t */
\tfbcon_base = (volatile uint32_t *)(uintptr_t)reg[0];
#else
\tfbcon_base = (volatile uint32_t *)ml_io_map_wcomb(reg[0], reg[1]);
#endif
'''


def main():
    if not os.path.exists(SRC):
        raise SystemExit(f'missing {SRC}')
    src = open(SRC, encoding='utf-8').read()
    if src.count(OLD) != 1:
        raise SystemExit(f'anchor count {src.count(OLD)}')

    if os.path.exists(WORK):
        shutil.rmtree(WORK)
    os.makedirs(os.path.join(WORK, 'pexpert/arm'))
    open(os.path.join(WORK, PEX), 'w', encoding='utf-8', newline='').write(src)
    subprocess.run(['git', 'init', '-q'], cwd=WORK, check=True)
    subprocess.run(['git', 'add', '-A'], cwd=WORK, check=True)
    subprocess.run(['git', '-c', 'user.name=x', '-c', 'user.email=x@x', 'commit', '-qm', 'base'],
                   cwd=WORK, check=True)

    open(os.path.join(WORK, PEX), 'w', encoding='utf-8', newline='').write(src.replace(OLD, NEW, 1))
    diff = subprocess.run(['git', 'diff', '--no-color'], cwd=WORK, capture_output=True, text=True,
                          encoding='utf-8', check=True).stdout
    out = sys.argv[1]
    open(out, 'w', encoding='utf-8', newline='').write(diff)
    print(diff)
    subprocess.run(['git', 'checkout', '--', '.'], cwd=WORK, check=True)
    chk = subprocess.run(['git', 'apply', '--check', os.path.abspath(out)], cwd=WORK,
                         capture_output=True, text=True)
    print('APPLY-CHECK:', 'ok' if chk.returncode == 0 else 'FAILED')
    if chk.returncode:
        print(chk.stderr)
        sys.exit(1)


if __name__ == '__main__':
    main()
