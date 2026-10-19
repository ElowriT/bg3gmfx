#!/usr/bin/env python3
"""Extract SPIR-V modules from Larian Vulkan .bshd shader files.

  bshd_spirv.py FILE.bshd OUTDIR   writes OUTDIR/<name>-<n>.spv for each module found
Extracted game shaders stay in ignored build/ output; do not distribute them.
"""
from pathlib import Path
import struct
import sys

MAGIC = 0x07230203


def modules(data):
    start = 0
    while (i := data.find(struct.pack("<I", MAGIC), start)) >= 0:
        words = len(data[i:]) // 4
        pos = 5  # header words
        while pos < words:
            word, = struct.unpack_from("<I", data, i + pos * 4)
            count, opcode = word >> 16, word & 0xFFFF
            if count == 0 or pos + count > words or opcode > 6000:
                break
            pos += count
        yield i, data[i:i + pos * 4]
        start = i + pos * 4


def main():
    source, out = Path(sys.argv[1]), Path(sys.argv[2])
    out.mkdir(parents=True, exist_ok=True)
    for n, (offset, blob) in enumerate(modules(source.read_bytes())):
        target = out / f"{source.stem}-{n}.spv"
        target.write_bytes(blob)
        print(f"{target} offset {offset} {len(blob)} bytes")


if __name__ == "__main__":
    main()
