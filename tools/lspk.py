#!/usr/bin/env python3
"""List or extract files from a Larian LSPK (.pak) archive, version 18.

  lspk.py PAK list [TEXT]            entries whose path contains TEXT
  lspk.py PAK extract OUTDIR TEXT    extract entries whose path contains TEXT

Extracted game data stays in ignored build/ output; do not distribute it.
"""

from pathlib import Path
import struct
import sys
import zlib


def lz4_block(data, size):
    """Decompress one raw LZ4 block (no frame header)."""
    try:
        import lz4.block
        return lz4.block.decompress(data, uncompressed_size=size)
    except ImportError:
        pass
    out = bytearray()
    i, n = 0, len(data)
    while i < n:
        token = data[i]; i += 1
        literal = token >> 4
        if literal == 15:
            while True:
                extra = data[i]; i += 1; literal += extra
                if extra != 255:
                    break
        out += data[i:i + literal]; i += literal
        if i >= n:
            break
        offset = data[i] | data[i + 1] << 8; i += 2
        match = (token & 15) + 4
        if match == 19:
            while True:
                extra = data[i]; i += 1; match += extra
                if extra != 255:
                    break
        start = len(out) - offset
        if offset >= match:
            out += out[start:start + match]
        else:
            for k in range(match):
                out.append(out[start + k])
    if len(out) != size:
        raise ValueError(f"LZ4 block decoded to {len(out)} bytes, expected {size}")
    return bytes(out)


def entries(path):
    with open(path, "rb") as f:
        magic, version, list_offset = struct.unpack("<4sIQ", f.read(16))
        if magic != b"LSPK" or version != 18:
            raise SystemExit(f"unsupported archive: {magic} v{version}")
        f.seek(list_offset)
        count, compressed = struct.unpack("<II", f.read(8))
        table = lz4_block(f.read(compressed), count * 272)
    for i in range(count):
        raw = table[i * 272:(i + 1) * 272]
        name = raw[:256].split(b"\0", 1)[0].decode("utf-8", "replace")
        offset_low, offset_high, part, flags, disk_size, size = struct.unpack("<IHBBII", raw[256:272])
        yield {"name": name, "offset": offset_low | offset_high << 32, "part": part,
               "flags": flags, "disk": disk_size, "size": size}


def read(path, entry):
    if entry["part"]:
        raise SystemExit(f"{entry['name']} is in a multi-part archive")
    with open(path, "rb") as f:
        f.seek(entry["offset"])
        data = f.read(entry["disk"])
    method = entry["flags"] & 0x0F
    if method == 0:
        return data
    if method == 1:
        return zlib.decompress(data)
    if method == 2:
        return lz4_block(data, entry["size"])
    raise SystemExit(f"{entry['name']}: compression method {method} not supported")


def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    pak = sys.argv[1]
    if sys.argv[2] == "list":
        text = sys.argv[3] if len(sys.argv) > 3 else ""
        for entry in entries(pak):
            if text in entry["name"]:
                print(f"{entry['size']:10} {entry['name']}")
        return
    out, text = Path(sys.argv[3]), sys.argv[4]
    for entry in entries(pak):
        if text in entry["name"]:
            target = out / entry["name"]
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(read(pak, entry))
            print(target)


if __name__ == "__main__":
    main()
