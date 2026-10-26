"""Build 0213-songyuan-vm-fault-null-map.patch.

The ring proves vm_fault_internal() is entered with map == NULL (it faults on
ldrb w8,[x0,#0x9e]) and recurses.  Catch that first entry and print the caller.
"""
import os
import shutil
import subprocess
import sys

SRC = r'E:\songyuan\dl\xnu'
WORK = os.path.join(r'E:\songyuan\work', 'vmfbuild-' + str(os.getpid()))
VM_FAULT_C = 'osfmk/vm/vm_fault.c'

GUARD = '''#if defined(SWEET)
\textern void panic(const char *, ...) __printflike(1, 2) __dead2;
\tif (__improbable(map == NULL)) {
\t\tpanic("SONGYUAN: vm_fault_internal map=NULL vaddr=%p caller=%p",
\t\t    (void *)vaddr, __builtin_return_address(0));
\t}
#endif
'''


def main():
    if os.path.exists(WORK):
        shutil.rmtree(WORK)
    os.makedirs(os.path.join(WORK, 'osfmk/vm'))

    src = open(os.path.join(SRC, 'vm_fault.c'), encoding='utf-8').read()
    open(os.path.join(WORK, VM_FAULT_C), 'w', encoding='utf-8', newline='').write(src)

    subprocess.run(['git', 'init', '-q'], cwd=WORK, check=True)
    subprocess.run(['git', 'add', '-A'], cwd=WORK, check=True)
    subprocess.run(['git', '-c', 'user.name=x', '-c', 'user.email=x@x', 'commit', '-qm', 'base'],
                   cwd=WORK, check=True)

    anchor = '{\n\tvm_map_version_t        version;        /* Map version for verificiation */'
    assert src.count(anchor) == 1, 'vm_fault.c: prologue anchor not unique'
    src = src.replace(anchor, '{\n' + GUARD + '\tvm_map_version_t        version;        /* Map version for verificiation */', 1)
    open(os.path.join(WORK, VM_FAULT_C), 'w', encoding='utf-8', newline='').write(src)

    diff = subprocess.run(['git', 'diff', '--no-color'], cwd=WORK, capture_output=True, text=True,
                          encoding='utf-8', check=True).stdout
    out = sys.argv[1]
    open(out, 'w', encoding='utf-8', newline='').write(diff)
    print(diff)

    subprocess.run(['git', 'checkout', '--', '.'], cwd=WORK, check=True)
    check = subprocess.run(['git', 'apply', '--check', os.path.abspath(out)], cwd=WORK,
                           capture_output=True, text=True)
    print('APPLY-CHECK:', 'ok' if check.returncode == 0 else 'FAILED')
    if check.returncode != 0:
        print(check.stderr)
        sys.exit(1)


if __name__ == '__main__':
    main()
