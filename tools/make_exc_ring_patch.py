"""Build 0211-songyuan-exc-ring.patch from the upstream xnu sources.

The base tree is "upstream + patch 0010's debug.c hunk" (the only earlier patch that
touches the region we edit), so the generated diff applies after the whole series.
"""
import os
import shutil
import subprocess
import sys

SRC = r'E:\songyuan\dl\xnu'
WORK = os.path.join(r'E:\songyuan\work', 'patchbuild-' + str(os.getpid()))

DEBUG_C = 'osfmk/kern/debug.c'
SLEH_C = 'osfmk/arm64/sleh.c'

RING = '''#if defined(SWEET)
/*
 * The panic the console shows after a double fault is the second one: the first
 * fault's esr/far/pc are already gone by then. Keep the last few synchronous
 * exceptions so the panic path can print the one that actually started it.
 */
#define SWEET_EXC_RING 8
struct sweet_exc_rec {
\tuint64_t esr, far, pc, sp, lr, fp;
};
static struct sweet_exc_rec sweet_exc_ring[SWEET_EXC_RING];
static volatile uint32_t sweet_exc_total;

void sweet_exc_record(uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t);
void sweet_exc_dump(void);

void
sweet_exc_record(uint64_t esr, uint64_t far, uint64_t pc, uint64_t sp, uint64_t lr, uint64_t fp)
{
\tuint32_t i = sweet_exc_total++ % SWEET_EXC_RING;
\tsweet_exc_ring[i].esr = esr;
\tsweet_exc_ring[i].far = far;
\tsweet_exc_ring[i].pc = pc;
\tsweet_exc_ring[i].sp = sp;
\tsweet_exc_ring[i].lr = lr;
\tsweet_exc_ring[i].fp = fp;
}

void
sweet_exc_dump(void)
{
\tuint32_t total = sweet_exc_total;
\tuint32_t first = total > SWEET_EXC_RING ? total - SWEET_EXC_RING : 0;

\tprintf("SWEET EXC RING: %u synchronous exceptions, showing %u..%u\\n",
\t    total, first, total - 1);
\tfor (uint32_t n = first; n < total; n++) {
\t\tstruct sweet_exc_rec *r = &sweet_exc_ring[n % SWEET_EXC_RING];
\t\tprintf("SWEET EXC %u: esr=%#llx far=%#llx pc=%#llx sp=%#llx lr=%#llx fp=%#llx\\n",
\t\t    n, r->esr, r->far, r->pc, r->sp, r->lr, r->fp);
\t}
}
#endif /* SWEET */

'''

DUMP_CALL = '''#if defined(SWEET)
\t/* Last synchronous exceptions before this panic: the first fault matters. */
\tsweet_exc_dump();
#endif

'''

RECORD = '''#if defined(SWEET)
\textern void sweet_exc_record(uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t);
\tsweet_exc_record(esr, far, get_saved_state_pc(state), get_saved_state_sp(state),
\t    get_saved_state_lr(state), get_saved_state_fp(state));
#endif
'''


def simulate_0010(text):
    """Apply patch 0010's debug.c hunk: the sweet_early_panic hook."""
    anchor = '#pragma clang diagnostic pop\n\n#if defined(__x86_64__) && (DEVELOPMENT || DEBUG)'
    block = ('#pragma clang diagnostic pop\n\n'
             '#if defined(SWEET)\n'
             '\t/* No CPU/thread/debugger state is required for this first panic copy. */\n'
             '\tsweet_early_panic(panic_format_str, panic_args);\n'
             '#endif\n\n'
             '#if defined(__x86_64__) && (DEVELOPMENT || DEBUG)')
    assert anchor in text, 'debug.c: 0010 anchor not found'
    return text.replace(anchor, block, 1)


def main():
    if os.path.exists(WORK):
        shutil.rmtree(WORK)
    os.makedirs(os.path.join(WORK, 'osfmk/kern'))
    os.makedirs(os.path.join(WORK, 'osfmk/arm64'))

    dbg = open(os.path.join(SRC, 'debug.c'), encoding='utf-8').read()
    sleh = open(os.path.join(SRC, 'sleh.c'), encoding='utf-8').read()
    dbg = simulate_0010(dbg)
    open(os.path.join(WORK, DEBUG_C), 'w', encoding='utf-8', newline='').write(dbg)
    open(os.path.join(WORK, SLEH_C), 'w', encoding='utf-8', newline='').write(sleh)

    subprocess.run(['git', 'init', '-q'], cwd=WORK, check=True)
    subprocess.run(['git', 'add', '-A'], cwd=WORK, check=True)
    subprocess.run(['git', '-c', 'user.name=x', '-c', 'user.email=x@x', 'commit', '-qm', 'base'],
                   cwd=WORK, check=True)

    # 1. ring store + dumper, right before panic_trap_to_debugger's definition
    a = '#endif /* defined (__x86_64__) */\n\n#pragma clang diagnostic push'
    assert dbg.count(a) == 1, 'debug.c: ring anchor not unique'
    dbg = dbg.replace(a, '#endif /* defined (__x86_64__) */\n\n' + RING + '#pragma clang diagnostic push', 1)

    # 2. dump the ring as soon as the panic path runs
    b = ('#if defined(SWEET)\n'
         '\t/* No CPU/thread/debugger state is required for this first panic copy. */\n'
         '\tsweet_early_panic(panic_format_str, panic_args);\n'
         '#endif\n\n')
    assert dbg.count(b) == 1, 'debug.c: dump anchor not unique'
    dbg = dbg.replace(b, b + DUMP_CALL, 1)
    open(os.path.join(WORK, DEBUG_C), 'w', encoding='utf-8', newline='').write(dbg)

    # 3. record every synchronous exception (overwrites are fine: 8-entry ring)
    c = ('\tthread_t               thread  = current_thread();\n'
         '#if MACH_ASSERT\n'
         '\tint                    preemption_level = sleh_get_preemption_level();\n'
         '#endif\n')
    assert sleh.count(c) == 1, 'sleh.c: record anchor not unique'
    sleh = sleh.replace(c, '\tthread_t               thread  = current_thread();\n'
                           + RECORD +
                           '#if MACH_ASSERT\n'
                           '\tint                    preemption_level = sleh_get_preemption_level();\n'
                           '#endif\n', 1)
    open(os.path.join(WORK, SLEH_C), 'w', encoding='utf-8', newline='').write(sleh)

    diff = subprocess.run(['git', 'diff', '--no-color'], cwd=WORK, capture_output=True, text=True,
                          encoding='utf-8', check=True).stdout
    out = sys.argv[1]
    open(out, 'w', encoding='utf-8', newline='').write(diff)
    print(diff)

    # prove the result applies to the base tree it was generated from
    subprocess.run(['git', 'checkout', '--', '.'], cwd=WORK, check=True)
    check = subprocess.run(['git', 'apply', '--check', os.path.abspath(out)], cwd=WORK,
                           capture_output=True, text=True)
    print('APPLY-CHECK:', 'ok' if check.returncode == 0 else 'FAILED')
    if check.returncode != 0:
        print(check.stderr)
        sys.exit(1)
    print('written', out, len(diff), 'bytes')


if __name__ == '__main__':
    main()
