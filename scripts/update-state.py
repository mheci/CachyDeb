#!/usr/bin/env python3
import json
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 4:
        print("usage: update-state.py STATE_FILE VARIANT VERSION", file=sys.stderr)
        return 1
    path = Path(sys.argv[1])
    variant = sys.argv[2]
    version = sys.argv[3]
    state = {}
    if path.is_file():
        state = json.loads(path.read_text())
    if state.get(variant) == version:
        print("unchanged")
        return 0
    state[variant] = version
    path.write_text(json.dumps(state, indent=2, sort_keys=True) + "\n")
    print("changed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
