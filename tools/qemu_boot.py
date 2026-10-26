"""Run the songyuan payload under qemu-system-aarch64 and turn the kernel's
framebuffer console into a PNG, so the kernel can be debugged without the phone.

    python tools/qemu_boot.py [--seconds 20] [--kernel PATH] [--out STEM]

What it does:
  ADT (--qemu-gic: QEMU GIC/timer, phone RAM window) -> payload -> loader built
  with QEMU=1 (serial + QEMU RAM range) -> qemu -kernel loader/Image -> wait ->
  QMP pmemsave of the phone framebuffer -> PNG.

Outputs (under E:\\songyuan\\work\\qemu): <stem>.png, <stem>.serial.txt, <stem>.fb.bin
"""
import argparse
import json
import os
import re
import shutil
import socket
import struct
import subprocess
import sys
import time
import zlib

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORK = os.environ.get('SONGYUAN_QEMU_WORK', r'E:\songyuan\work\qemu')
PAYLOAD = os.path.join(WORK, 'payload')
KERNEL_DEFAULT = r'E:\songyuan\bringup_work\songyuan\kernel\kernel.development.songyuan'

# The framebuffer is the phone's in both modes: the loader always draws at
# 0xfc800000 (shim/loader/loader.c) and QEMU's 0x50000000+0xb0000000 window covers
# it, so mkadt_songyuan.py declares the same region for the QEMU twin as well.
# 0x2b00000 (43 MiB) and 1200x2608 are from the live FDT / DRM mode, not from sweep.
FB_BASE = 0xfc800000
FB_SIZE = 0x2b00000
FB_W, FB_H, FB_STRIDE = 1200, 2608, 1200 * 4
QEMU = r'E:\Android\qemu\qemu-system-aarch64.exe'
QMP_PORT = 4444


def run(cmd, env=None, cwd=None):
    print('+', ' '.join(str(c) for c in cmd), flush=True)
    p = subprocess.run(cmd, env=env, cwd=cwd, capture_output=True, text=True)
    if p.returncode:
        print(p.stdout[-3000:])
        print(p.stderr[-3000:])
        raise SystemExit(f'command failed: {cmd[0]}')
    if p.stderr.strip():
        print(p.stderr.strip()[-2000:])
    return p.stdout


def build(args):
    os.makedirs(PAYLOAD, exist_ok=True)
    env = dict(os.environ)
    env['SONGYUAN_DRAM_BASE'] = '0x50000000'
    env['SONGYUAN_DRAM_SIZE'] = '0xb0000000'
    if getattr(args, 'no_fbcon', False):
        env['SONGYUAN_NO_FBCON'] = '1'
    else:
        env.pop('SONGYUAN_NO_FBCON', None)
    py = sys.executable
    adt = os.path.join(WORK, 'qemu.adt')
    payload = os.path.join(PAYLOAD, 'payload.bin')
    run([py, os.path.join(REPO, 'tools/mkadt_songyuan.py'), adt, '--qemu-gic' if getattr(args,'phone_fb',False) else '--qemu'], env=env)
    run([py, os.path.join(REPO, 'tools/mkpayload.py'), args.kernel, adt, payload,
         '--cmdline', args.cmdline], env=env)
    run([py, os.path.join(REPO, 'shim/loader/build.ps1').replace('.ps1', '.ps1')], env=env) \
        if False else None
    # loader build: powershell script, QEMU=1
    ps = ('& "{}" -Out "{}" -Qemu'.format(os.path.join(REPO, 'shim/loader/build.ps1'), PAYLOAD))
    shell = 'pwsh' if shutil.which('pwsh') else 'powershell'
    run([shell, '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', ps], env=env)
    return os.path.join(PAYLOAD, 'loader', 'Image')


def qmp(cmd_list):
    s = socket.create_connection(('127.0.0.1', QMP_PORT), timeout=10)
    f = s.makefile('rwb')
    json.loads(f.readline().decode())          # greeting
    for cmd in cmd_list:
        f.write((json.dumps(cmd) + '\n').encode())
        f.flush()
        while True:
            line = f.readline()
            if not line:
                raise SystemExit('qmp closed')
            obj = json.loads(line.decode())
            if 'return' in obj or 'error' in obj:
                if 'error' in obj:
                    raise SystemExit(f"qmp error: {obj['error']}")
                break
    s.close()


def regs():
    s = socket.create_connection(('127.0.0.1', QMP_PORT), timeout=10)
    f = s.makefile('rwb')
    json.loads(f.readline().decode())
    f.write((json.dumps({'execute': 'qmp_capabilities'}) + '\n').encode()); f.flush()
    f.readline()
    f.write((json.dumps({'execute': 'human-monitor-command',
                         'arguments': {'command-line': 'info registers'}}) + '\n').encode()); f.flush()
    out = json.loads(f.readline().decode()).get('return', '')
    s.close()
    return out




def kernel_symbols(path):
    """name -> value for the few symbols we need (Mach-O nlist)."""
    import struct
    data = open(path, 'rb').read()
    _, _, _, _, ncmds, _, _ = struct.unpack_from('<IiiIIII', data, 0)[0:7] if False else (None,)*7
    magic, cputype, cpusub, ft, ncmds, sizeofcmds, flags = struct.unpack_from('<IiiIIII', data, 0)
    off, out = 32, {}
    for _ in range(ncmds):
        cmd, cs = struct.unpack_from('<II', data, off)
        if cmd == 0x2:
            symoff, nsyms, stroff, strsize = struct.unpack_from('<IIII', data, off + 8)
            st = data[stroff:stroff + strsize]
            for i in range(nsyms):
                n_strx, ntype, nsect, ndesc, nval = struct.unpack_from('<IBBHQ', data, symoff + i * 16)
                e = st.find(b'\0', n_strx)
                name = st[n_strx:e].decode('utf-8', 'replace')
                if name in ('_songyuan_log_buf', '_songyuan_log_len'):
                    out[name] = nval
            break
        off += cs
    return out


def dump_panic(kernel, path):
    syms = kernel_symbols(kernel)
    va = syms.get('_songyuan_log_buf')
    if not va:
        print('no _songyuan_log_buf in kernel')
        return
    pa = va - 0xfffffff006000000 + 0x50000000
    qmp([{'execute': 'qmp_capabilities'},
         {'execute': 'pmemsave', 'arguments': {'val': pa, 'size': 0x2000, 'filename': path}}])
    data = open(path, 'rb').read()
    lines = [m.group().decode() for m in re.finditer(rb'[ -~]{6,}', data)]
    print('--- panic log ---')
    print('\n'.join(lines[:60]))


def dump_fb(path):
    qmp([
        {'execute': 'qmp_capabilities'},
        {'execute': 'pmemsave', 'arguments': {'val': FB_BASE, 'size': FB_SIZE, 'filename': path}},
    ])


def png_from_fb(fb_path, png_path, w=FB_W, h=FB_H, stride=FB_STRIDE):
    data = open(fb_path, 'rb').read()
    rows = []
    for y in range(h):
        row = data[y * stride: y * stride + w * 4]
        if len(row) < w * 4:
            row += b'\0' * (w * 4 - len(row))
        # 32-bit little-endian pixels; console text is drawn in white on black,
        # so channel order only affects colour, not legibility
        rgb = bytearray(w * 3)
        rgb[0::3] = row[2::4]
        rgb[1::3] = row[1::4]
        rgb[2::3] = row[0::4]
        rows.append(b'\x00' + bytes(rgb))

    raw = b''.join(rows)

    def chunk(tag, payload):
        c = struct.pack('>I', len(payload)) + tag + payload
        return c + struct.pack('>I', zlib.crc32(tag + payload) & 0xffffffff)

    png = (b'\x89PNG\r\n\x1a\n'
           + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
           + chunk(b'IDAT', zlib.compress(raw, 6))
           + chunk(b'IEND', b''))
    open(png_path, 'wb').write(png)
    print('png:', png_path, len(png), 'bytes')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--kernel', default=KERNEL_DEFAULT)
    ap.add_argument('--seconds', type=int, default=20)
    ap.add_argument('--cmdline', default='-v debug=0xc cpus=1 keepsyms=1 rd=none')
    ap.add_argument('--stem', default='run')
    ap.add_argument('--no-fbcon', action='store_true', default=True)
    ap.add_argument('--phone-fb', action='store_true')
    args = ap.parse_args()

    img = build(args)
    os.makedirs(WORK, exist_ok=True)
    fb = os.path.join(WORK, args.stem + '.fb.bin')
    serial = os.path.join(WORK, args.stem + '.serial.txt')
    if os.path.exists(fb):
        os.remove(fb)

    qemu_cmd = [QEMU, '-M', 'virt,gic-version=3', '-cpu', 'max', '-smp', '1', '-m', '4G',
                '-nographic', '-serial', 'file:' + serial, '-monitor', 'none', '-no-reboot', '-icount', 'shift=3',
                '-qmp', f'tcp:127.0.0.1:{QMP_PORT},server,nowait',
                '-kernel', img]
    print('+', ' '.join(qemu_cmd), flush=True)
    proc = subprocess.Popen(qemu_cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        time.sleep(2)
        time.sleep(args.seconds)
        dump_fb(fb)
        print(regs())
        dump_panic(args.kernel, os.path.join(WORK, args.stem + '.panic.txt'))
    finally:
        proc.kill()
        try:
            proc.wait(timeout=10)
        except Exception:
            pass
    png_from_fb(fb, os.path.join(WORK, args.stem + '.png'), FB_W, FB_H, FB_STRIDE)
    if os.path.exists(serial):
        print('--- serial tail ---')
        print(open(serial, encoding='utf-8', errors='replace').read()[-2000:])


if __name__ == '__main__':
    main()
