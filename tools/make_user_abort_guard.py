"""Build 0212-songyuan-user-abort-null-map.patch.

handle_user_abort() takes `vm_map_t map = thread->map` and calls vm_fault(map, ...)
without checking it.  A NULL map makes vm_fault_internal read [NULL+0x9e], which faults
again into the same handler: infinite recursion until the exception stack overflows.
Guard it and print the thread/task/pc/far once, so the panic names the culprit.
"""
import os
import shutil
import subprocess
import sys

SRC = r'E:\songyuan\dl\xnu'
WORK = os.path.join(r'E:\songyuan\work', 'guardbuild-' + str(os.getpid()))
SLEH_C = 'osfmk/arm64/sleh.c'

GUARD = '''#if defined(SWEET)
\t\tif (map == NULL) {
\t\t\ttask_t task = current_task();
\t\t\tpanic("SONGYUAN: user fault with NULL thread->map: thread %p task %p task->map %p pc %p far %p",
\t\t\t    (void *)thread, (void *)task, (void *)(task ? task->map : NULL),
\t\t\t    (void *)get_saved_state_pc(state), (void *)fault_addr);
\t\t}
#endif
'''


def main():
    if os.path.exists(WORK):
        shutil.rmtree(WORK)
    os.makedirs(os.path.join(WORK, 'osfmk/arm64'))

    sleh = open(os.path.join(SRC, 'sleh.c'), encoding='utf-8').read()
    open(os.path.join(WORK, SLEH_C), 'w', encoding='utf-8', newline='').write(sleh)

    subprocess.run(['git', 'init', '-q'], cwd=WORK, check=True)
    subprocess.run(['git', 'add', '-A'], cwd=WORK, check=True)
    subprocess.run(['git', '-c', 'user.name=x', '-c', 'user.email=x@x', 'commit', '-qm', 'base'],
                   cwd=WORK, check=True)

    anchor = '\t\tassert(map != kernel_map);\n'
    assert sleh.count(anchor) == 1, 'sleh.c: assert anchor not unique'
    sleh = sleh.replace(anchor, anchor + '\n' + GUARD, 1)
    open(os.path.join(WORK, SLEH_C), 'w', encoding='utf-8', newline='').write(sleh)

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
