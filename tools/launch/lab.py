#!/usr/bin/env python3
"""Drive the runtime's lab mode (BG3MFX_LAB) during a live investigation.

Start BG3 with BG3MFX_LAB=<dir> (see docs/dev/lab.md), then (watch lines in
control.txt are kept):
  lab.py --dir <dir> skip TEXT [TEXT ...]   drop draws/dispatches of matching shaders
  lab.py --dir <dir> clear                  remove every skip rule
  lab.py --dir <dir> census NAME            record the next frame to census-NAME.json
  lab.py --dir <dir> summary NAME           print that census pass by pass
  lab.py --dir <dir> shot NAME              screenshot to shots/NAME.png (needs screen recording access)
  lab.py --dir <dir> probe NAME [TEXT ...]  apply exactly these skip rules, then take shot NAME
  lab.py --dir <dir> rules NAME [LINE ...]  apply exactly these control lines (skip/poke), then shots NAME-a/-b
  lab.py --dir <dir> pad N connect|disconnect|release      virtual controller N (1-4)
  lab.py --dir <dir> pad N press BUTTON... [--hold S]      press together, release after S seconds (0.15)
  lab.py --dir <dir> pad N hold BUTTON...                   keep these held until release
  lab.py --dir <dir> pad N stick left|right X Y [--hold S]  tilt a stick (-1..1), for S seconds if given
  lab.py --dir <dir> pad status                             the pads as the game reports them
Buttons: a b x y lb rb lt rt l3 r3 menu options home up down left right.
Screenshots wait until BG3 is the frontmost app, so a player can switch back to it.
Other commands keep watch and pad lines in control.txt.
"""

import argparse
import json
import os
import re
from pathlib import Path
import subprocess
import time

FORMATS = {
    10: "R8Unorm", 25: "R16Float", 30: "RG8Unorm", 55: "R32Float", 65: "RG16Float",
    70: "RGBA8Unorm", 71: "RGBA8Unorm_sRGB", 80: "BGRA8Unorm", 81: "BGRA8Unorm_sRGB",
    90: "RGB10A2Unorm", 92: "RG11B10Float", 94: "BGR10A2Unorm", 105: "RG32Float",
    115: "RGBA16Float", 125: "RGBA32Float", 252: "Depth32Float", 260: "Depth32Float_Stencil8",
}


def read_control(directory):
    path = directory / "control.txt"
    lines = path.read_text().splitlines() if path.exists() else []
    skips = [line[5:] for line in lines if line.startswith("skip ")]
    census = [line[7:] for line in lines if line.startswith("census ")]
    return skips, census[-1] if census else None


def write_control(directory, skips, census):
    path = directory / "control.txt"
    kept = [line for line in path.read_text().splitlines() if line.startswith(("watch ", "pad "))] if path.exists() else []
    lines = kept + [f"skip {text}" for text in skips]
    if census:
        lines.append(f"census {census}")
    (directory / "control.txt").write_text("\n".join(lines) + "\n")


def wait_applied(directory, timeout=5.0):
    """Wait until status.json reports a newer generation than before."""
    status = directory / "status.json"
    before = json.loads(status.read_text())["generation"] if status.exists() else 0
    deadline = time.time() + timeout
    while time.time() < deadline:
        if status.exists():
            current = json.loads(status.read_text())
            if current["generation"] > before:
                return current
        time.sleep(0.1)
    raise SystemExit("The game did not apply the change (is it running in lab mode and in focus?)")


def pad_state(directory, number):
    """Controller `number`'s lines in control.txt: (connected, held buttons, sticks)."""
    path = directory / "control.txt"
    lines = path.read_text().splitlines() if path.exists() else []
    connected, held, sticks = False, [], {}
    for line in lines:
        words = line.split()
        if words[:2] != ["pad", str(number)]:
            continue
        connected = True
        if len(words) == 6 and words[2] == "stick":
            sticks[words[3]] = (float(words[4]), float(words[5]))
        else:
            held += [word for word in words[2:] if word not in held]
    return connected, held, sticks


def write_pad(directory, number, connected, held, sticks):
    path = directory / "control.txt"
    lines = path.read_text().splitlines() if path.exists() else []
    lines = [line for line in lines if line.split()[:2] != ["pad", str(number)]]
    if connected:
        lines.append(" ".join(["pad", str(number)] + held))
        lines += [f"pad {number} stick {side} {x:g} {y:g}" for side, (x, y) in sorted(sticks.items()) if (x, y) != (0, 0)]
    path.write_text("\n".join(lines) + "\n")
    return wait_applied(directory)


def pad(directory, args):
    if args.number == "status":
        status = directory / "status.json"
        print(json.dumps(json.loads(status.read_text()).get("pads", []) if status.exists() else [], indent=1))
        return
    number = int(args.number)
    if not 1 <= number <= 4:
        raise SystemExit("Pads are numbered 1 to 4")
    connected, held, sticks = pad_state(directory, number)
    action, rest = args.action, args.rest
    if action == "connect":
        status = write_pad(directory, number, True, held, sticks)
    elif action == "disconnect":
        status = write_pad(directory, number, False, [], {})
    elif action == "release":
        status = write_pad(directory, number, True, [], {})
    elif action == "hold":
        status = write_pad(directory, number, True, held + [b for b in rest if b not in held], sticks)
    elif action == "press":
        write_pad(directory, number, True, held + [b for b in rest if b not in held], sticks)
        time.sleep(0.15 if args.hold is None else args.hold)
        status = write_pad(directory, number, True, held, sticks)
    elif action == "stick":
        if len(rest) != 3 or rest[0] not in ("left", "right"):
            raise SystemExit("Usage: pad N stick left|right X Y [--hold S]")
        moved = dict(sticks, **{rest[0]: (float(rest[1]), float(rest[2]))})
        status = write_pad(directory, number, True, held, moved)
        if args.hold is not None:
            time.sleep(args.hold)
            status = write_pad(directory, number, True, held, sticks)
    else:
        raise SystemExit(f"Unknown pad action {action}")
    print(json.dumps(status.get("pads", [])))


def front_app():
    asn = subprocess.run(["lsappinfo", "front"], capture_output=True, text=True).stdout.strip()
    info = subprocess.run(["lsappinfo", "info", "-only", "bundleid", asn], capture_output=True, text=True).stdout
    match = re.search(r'bundleID="([^"]*)"', info)
    return match.group(1) if match else ""


def wait_front(timeout=float(os.environ.get("BG3MFX_LAB_WAIT", "180"))):
    deadline = time.time() + timeout
    while front_app() != "com.larian.bg3":
        if time.time() > deadline:
            raise SystemExit("BG3 did not come to the front")
        time.sleep(0.5)


def shot(directory, name):
    wait_front()
    time.sleep(1.0)  # let a few frames render with the current rules
    shots = directory / "shots"
    shots.mkdir(exist_ok=True)
    path = shots / f"{name}.png"
    subprocess.run(["screencapture", "-x", "-t", "png", str(path)], check=True)
    small = shots / f"{name}-small.png"
    subprocess.run(["sips", "-Z", "1600", str(path), "--out", str(small)], check=True, capture_output=True)
    print(small)


def texture(entry):
    name = FORMATS.get(entry["format"], str(entry["format"]))
    label = f" {entry['label']}" if entry.get("label") else ""
    return f"{entry['width']}x{entry['height']} {name}{label}"


def summary(directory, name):
    census = json.loads((directory / f"census-{name}.json").read_text())
    print(f"census {name}: frame {census['frame']}, skips {census['skip']}")
    for encoder in census["encoders"]:
        targets = ", ".join(texture(t) for t in encoder.get("colors", []))
        depth = f" depth {texture(encoder['depth'])}" if encoder.get("depth") else ""
        work = encoder["draws"] if encoder["kind"] == "render" else encoder["dispatches"]
        total = sum(work.values())
        label = f" '{encoder['label']}'" if encoder.get("label") else ""
        print(f"#{encoder['index']} {encoder['kind']}{label} [{targets}{depth}] {total} call(s)")
        if encoder.get("viewport"):
            print(f"    viewport {encoder['viewport']}")
        for shader, count in sorted(work.items(), key=lambda item: -item[1])[:12]:
            grid = encoder.get("grids", {}).get(shader)
            print(f"    {count:5} {shader}" + (f"  [{grid}]" if grid else ""))
        if len(work) > 12:
            print(f"    ... {len(work) - 12} more shader(s)")
        for call in encoder.get("watched", []):
            where = " ".join(f"{key} {call[key]}" for key in ("viewport", "scissor", "grid") if key in call)
            print(f"    watched {call['shader'].split('|')[-1]} {where}")
            for slot, bound in sorted(call["textures"].items(), key=lambda item: int(item[0])):
                size = f"{bound['width']}x{bound['height']}" + (f"x{bound['depth']}" if bound["depth"] > 1 else "")
                print(f"        t{slot} {bound['id']} {size} {FORMATS.get(bound['format'], bound['format'])} {bound['label']}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dir", type=Path, required=True)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("skip").add_argument("text", nargs="+")
    sub.add_parser("clear")
    sub.add_parser("census").add_argument("name")
    sub.add_parser("summary").add_argument("name")
    sub.add_parser("shot").add_argument("name")
    rules = sub.add_parser("rules")
    rules.add_argument("name")
    rules.add_argument("line", nargs="*")
    pads = sub.add_parser("pad")
    pads.add_argument("number")
    pads.add_argument("action", nargs="?", default="connect")
    pads.add_argument("rest", nargs="*")
    pads.add_argument("--hold", type=float)
    probe = sub.add_parser("probe")
    probe.add_argument("name")
    probe.add_argument("text", nargs="*")
    args = parser.parse_args()
    directory = args.dir.expanduser().resolve()
    directory.mkdir(parents=True, exist_ok=True)
    skips, census = read_control(directory)

    if args.command == "pad":
        pad(directory, args)
    elif args.command == "skip":
        write_control(directory, args.text, census)
        print(json.dumps(wait_applied(directory)))
    elif args.command == "clear":
        write_control(directory, [], census)
        print(json.dumps(wait_applied(directory)))
    elif args.command == "census":
        wait_front()
        target = directory / f"census-{args.name}.json"
        target.unlink(missing_ok=True)
        write_control(directory, skips, args.name)
        deadline = time.time() + 10
        while not target.exists() and time.time() < deadline:
            time.sleep(0.1)
        if not target.exists():
            raise SystemExit("No census was written (is the game rendering in lab mode?)")
        summary(directory, args.name)
    elif args.command == "summary":
        summary(directory, args.name)
    elif args.command == "rules":
        wait_front()
        path = directory / "control.txt"
        kept = [line for line in path.read_text().splitlines() if line.startswith(("watch ", "census ", "pad "))] if path.exists() else []
        path.write_text("\n".join(kept + args.line) + "\n")
        print(json.dumps(wait_applied(directory)))
        shot(directory, f"{args.name}-a")
        time.sleep(0.5)
        shot(directory, f"{args.name}-b")
    elif args.command == "shot":
        shot(directory, args.name)
    else:
        wait_front()
        write_control(directory, args.text, census)
        print(json.dumps(wait_applied(directory)))
        shot(directory, args.name)


if __name__ == "__main__":
    main()
