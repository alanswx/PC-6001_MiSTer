#!/usr/bin/env python3
"""Write a blank .d88 for the core's disk drives: every track there, 16 sectors of 256 bytes filled with FFh, as
a disk just formatted (no directory yet: format it on the machine before saving to it).

The core keeps an image at the size Main gave it (Main does not let the file grow), so a format can only rewrite
tracks the image already has: an unformatted image (the 688-byte header alone) cannot be formatted in the core.

  blank_d88.py OUT.d88            1D: 40 tracks, the PC-6001's PC-6031 and the PC-6601 (174768 bytes)
  blank_d88.py --1dd OUT.d88      1DD: 80 tracks, the mkIISR's PC-6031SR (348848 bytes)
"""
import argparse
import struct


def blank(tracks, media, name):
    sectors, size = 16, 256
    track_len = sectors * (16 + size)
    data = bytearray()
    table = [0] * 164
    for c in range(tracks):
        table[c * 2] = 0x2b0 + len(data)
        for r in range(1, sectors + 1):
            # C, H, R, N, sectors in the track, density (00h double), deleted, status, reserved, data size
            data += struct.pack('<4BHBBB5xH', c, 0, r, 1, sectors, 0, 0, 0, size)
            data += b'\xff' * size
    assert len(data) == tracks * track_len
    head = name.encode()[:16].ljust(17, b'\0') + bytes(9) + bytes([0, media])
    head += struct.pack('<I', 0x2b0 + len(data)) + struct.pack('<164I', *table)
    return head + data


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--1dd', dest='dd', action='store_true', help='80 tracks (media 10h) for the mkIISR')
    ap.add_argument('out')
    a = ap.parse_args()
    img = blank(80, 0x10, 'BLANK 1DD') if a.dd else blank(40, 0x00, 'BLANK 1D')
    with open(a.out, 'wb') as f:
        f.write(img)
    print(f'{a.out}: {len(img)} bytes')


if __name__ == '__main__':
    main()
