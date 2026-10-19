#!/usr/bin/env python3
"""List or extract functions from a Metal library (.metallib).

  metallib_extract.py LIB list [TEXT]          function names (optionally containing TEXT)
  metallib_extract.py LIB extract OUTDIR NAME...   write NAME.air (LLVM bitcode) for each

Disassemble an extracted module with:
  xcrun clang -S -emit-llvm -x ir NAME.air -o NAME.ll
Extracted game code stays in ignored build/ output; do not distribute it.
"""

from pathlib import Path
import struct
import sys


def functions(data):
    if data[:4] != b"MTLB":
        raise SystemExit("not a metallib")
    list_offset, = struct.unpack_from("<Q", data, 0x18)
    bitcode_offset, = struct.unpack_from("<Q", data, 0x48)
    count, = struct.unpack_from("<I", data, list_offset)
    position = list_offset + 4
    for _ in range(count):
        size, = struct.unpack_from("<I", data, position)
        cursor, end = position + 4, position + size
        entry = {}
        while cursor < end:
            tag = data[cursor:cursor + 4]
            if tag == b"ENDT":
                break
            length, = struct.unpack_from("<H", data, cursor + 4)
            value = data[cursor + 6:cursor + 6 + length]
            cursor += 6 + length
            if tag == b"NAME":
                entry["name"] = value.rstrip(b"\0").decode()
            elif tag == b"TYPE":
                entry["type"] = value[0]
            elif tag == b"MDSZ":
                entry["size"], = struct.unpack("<Q", value[:8])
            elif tag == b"OFFT":
                entry["bitcode"] = bitcode_offset + struct.unpack("<QQQ", value[:24])[2]
        position = end
        yield entry


def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    data = Path(sys.argv[1]).read_bytes()
    entries = list(functions(data))
    if sys.argv[2] == "list":
        text = sys.argv[3] if len(sys.argv) > 3 else ""
        for entry in entries:
            if text in entry.get("name", ""):
                print(f"{entry.get('type', '?')} {entry.get('size', 0):8} {entry['name']}")
        return
    out = Path(sys.argv[3])
    out.mkdir(parents=True, exist_ok=True)
    by_name = {entry.get("name"): entry for entry in entries}
    for name in sys.argv[4:]:
        entry = by_name.get(name)
        if not entry:
            print(f"{name}: not found", file=sys.stderr)
            continue
        blob = data[entry["bitcode"]:entry["bitcode"] + entry["size"]]
        (out / f"{name}.air").write_bytes(blob)
        print(f"{name}: {len(blob)} bytes, magic {blob[:4].hex()}")


if __name__ == "__main__":
    main()
