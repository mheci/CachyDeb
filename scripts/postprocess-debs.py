#!/usr/bin/env python3
import subprocess
import sys
import tempfile
from pathlib import Path

IMAGE_DEPENDS = (
    "kmod, linux-base (>= 4.3~), "
    "initramfs-tools (>= 0.120+deb8u2) | linux-initramfs-tool"
)
IMAGE_RECOMMENDS = "firmware-linux-free, firmware-misc-nonfree, firmware-nvidia-gsp"
HEADERS_DEPENDS = (
    "linux-base (>= 4.3~), libc6-dev | libc-dev, gcc, make, "
    "linux-libc-dev, libelf-dev, libssl-dev, bc"
)


def set_fields(control: Path, fields: dict) -> None:
    lines = control.read_text().splitlines()
    try:
        description_at = next(
            index for index, line in enumerate(lines) if line.lower().startswith("description:")
        )
    except StopIteration:
        description_at = len(lines)
    head = lines[:description_at]
    tail = lines[description_at:]
    for field in fields:
        head = [line for line in head if not line.lower().startswith(f"{field.lower()}:")]
    head.extend(f"{field}: {value}" for field, value in fields.items())
    control.write_text("\n".join(head + tail) + "\n")


def patch_package(deb: Path, fields: dict) -> None:
    with tempfile.TemporaryDirectory() as work:
        root = Path(work) / "root"
        subprocess.run(["dpkg-deb", "-R", str(deb), str(root)], check=True)
        control = root / "DEBIAN" / "control"
        set_fields(control, fields)
        subprocess.run(
            ["dpkg-deb", "--build", "--root-owner-group", str(root), str(deb)],
            check=True,
            stdout=subprocess.DEVNULL,
        )


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: postprocess-debs.py ARTIFACTS_DIR", file=sys.stderr)
        return 1
    artifacts = Path(sys.argv[1])
    if not artifacts.is_dir():
        print(f"missing artifacts directory: {artifacts}", file=sys.stderr)
        return 1

    for pattern in ("linux-libc-dev_*.deb", "*-dbg_*.deb"):
        for path in artifacts.glob(pattern):
            path.unlink()

    images = sorted(
        path for path in artifacts.glob("linux-image-*.deb") if "-dbg" not in path.name
    )
    headers = sorted(artifacts.glob("linux-headers-*.deb"))
    if not images or not headers:
        print("missing linux-image or linux-headers package", file=sys.stderr)
        return 1

    for deb in images:
        patch_package(deb, {"Depends": IMAGE_DEPENDS, "Recommends": IMAGE_RECOMMENDS})
    for deb in headers:
        patch_package(deb, {"Depends": HEADERS_DEPENDS})
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
