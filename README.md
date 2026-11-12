<div style="border: 3px solid #6effaf; border-radius: 5px; overflow: hidden; display: inline-block;">
  <img src="assets/cachydebian.png" alt="image" style="display: block;">
</div>

# CachyOS Kernel for Debian 13

This repository builds the CachyOS Linux kernel as Debian 13 (trixie) packages.
It is a CI pipeline, not a distribution. The build, package QA, CVE scan, boot
matrix, and release all run in GitHub Actions.

The target is a Debian 13 desktop on x86-64. Debian 12 is not supported.

## What the pipeline does

One workflow run builds one kernel variant.

1. **Build.** A Debian 13 container fetches the CachyOS kernel source, verifies
   the upstream GPG signature, applies a Debian desktop configuration, compiles
   the kernel, and creates `.deb` packages.
2. **Package QA.** Debian 13 validates the packages with `lintian`, installs
   them, generates an initramfs, checks module dependencies, and builds a test
   module against the packaged headers.
3. **CVE scan.** The official Linux kernel CVE dataset is checked against the
   built upstream version. The report is attached to the release.
4. **Boot matrix.** A clean Debian 13 root filesystem boots the kernel on BIOS
   with ext4 and btrfs, and on UEFI systemd-boot with a warm reboot. A guest
   script checks modules, the initramfs, the root filesystem, and dmesg.
5. **Release.** Only after every gate passes, the workflow publishes a GitHub
   Release with the packages, checksums, reports, and build provenance.

A failed build, QA check, CVE scan step, or boot test blocks the release. The
workflow does not publish a partial release.

The design and gate rationale are in [`docs/pipeline.md`](docs/pipeline.md).

## Automatic builds and releases

`.github/workflows/check-cachyos-updates.yml` polls
[CachyOS/linux-cachyos](https://github.com/CachyOS/linux-cachyos) every three
hours. When a variant's `pkgver-pkgrel` changes, it dispatches a build for that
variant. It also forces a rebuild every Monday at 04:00 UTC.

The build workflow publishes a release when all gates pass. The state file
`cachyos-kernel-state.json` is updated only after a successful release. A failed
release is retried on the next poll.

Release tags look like this:

```text
cachyos-debian-linux-cachyos-7.3.4-1+cachydeb123.1
```

Each variant releases independently. A broken LTS build does not block the
standard kernel, and the reverse is also true.

## Manual runs

Open **Actions**, select **Build and release Debian 13 kernel packages**, and
choose **Run workflow**.

| Input | Meaning | Default |
| --- | --- | --- |
| `runner` | Host runner for the Debian 13 build container | `blacksmith-16vcpu-ubuntu-2404` |
| `kernel_variant` | CachyOS variant | `linux-cachyos` |
| `cpu_scheduler` | CachyOS scheduler flavor | `cachyos` |
| `expected_version` | Fail if upstream does not match this `pkgver-pkgrel` | empty |
| `publish_release` | Publish after all gates pass | `true` |
| `run_boot_tests` | Run the QEMU boot matrix | `true` |
| `fail_on_critical_cve` | Block a release when an affected CVE scores 9.0 or higher | `false` |

Use `publish_release: false` for a dry run. Use `ubuntu-24.04` if the Blacksmith
integration is not installed.

Pull requests that change the workflow or `scripts/` run the build, QA, CVE, and
boot jobs. They never publish a release or update state.

## Variants

- `linux-cachyos`
- `linux-cachyos-bore`
- `linux-cachyos-eevdf`
- `linux-cachyos-lts`

The scheduler mapping is `cachyos`, `bore`, `eevdf`, and `cachyos` for LTS. The
kernel source and variant config come from the official CachyOS packaging
repository at build time.

## Debian desktop configuration

The build starts from the CachyOS configuration and applies a Debian 13 desktop
pass. The important settings are:

- generic x86-64 target for portability
- initramfs, devtmpfs, serial console, and EFI stub boot
- dynamic preemption, 1000 Hz tick, schedutil CPU frequency governor
- cgroups, BPF, PSI, and AppArmor
- netfilter, nftables, iptables, WireGuard, bridge, and VLAN
- ext4 built in, btrfs, XFS, F2FS, exFAT, NTFS3, NFS, CIFS, OverlayFS,
  SquashFS, EROFS, and FUSE as modules
- NVMe, dm-crypt, LVM device mapper, and RAID
- AMD, Intel, Nouveau, and VirtIO graphics
- firmware loader with XZ and Zstd compressed firmware support
- USB, HID, audio, webcam, Bluetooth, and common Wi-Fi drivers
- KVM, VFIO, VirtIO, and virtiofs

Rust kernel drivers are disabled. The desktop kernel and its required drivers
are C, and this keeps the build on the Debian 13 C toolchain.

## NVIDIA support

There are two supported paths.

**Nouveau.** Install the GSP firmware from Debian `non-free-firmware`.

```bash
sudo apt install firmware-nvidia-gsp firmware-misc-nonfree
```

Nouveau uses GSP on Turing and newer cards when the firmware is present.

**Proprietary driver.** Enable the Debian `non-free` component and install
`nvidia-driver`. DKMS builds the module against the headers package produced by
this pipeline.

```bash
sudo apt install linux-headers-* nvidia-driver
```

The kernel disables module signature enforcement (`CONFIG_MODULE_SIG_FORCE` is
off). Unsigned DKMS modules therefore load without a local signing key, with a
kernel taint for the missing signature. This is deliberate. Secure Boot still
needs manual signing.

## Firmware

The image package recommends these firmware packages:

- `firmware-linux-free`
- `firmware-misc-nonfree`
- `firmware-nvidia-gsp`

The last two require the Debian `non-free-firmware` component. Firmware is not
bundled in the kernel packages. Install the packages that match the hardware.

## Install

Download the image and headers packages from a release, then run:

```bash
sudo apt install ./linux-image-*.deb ./linux-headers-*.deb
sudo update-grub
sudo reboot
```

Keep a Debian kernel installed as a fallback. Confirm the running kernel with
`uname -r`.

The release does not include `linux-libc-dev` or a debug package. Debian owns
the former, and the latter is empty because debug info is disabled.

## Secure Boot

This kernel is unsigned. Secure Boot must be disabled, or you must sign the
kernel and every module with keys enrolled in the firmware. Do not enable Secure
Boot with these artifacts unless you have signed them yourself.

## CVE policy

The CVE report is mandatory. It is attached to every release and linked from the
release notes.

The default policy is report-only. A version-only scan cannot prove whether a
vulnerable driver is compiled into this configuration. Blocking a release does
not fix an upstream kernel bug and would delay every other fix. A maintainer can
enable `fail_on_critical_cve` for a strict gate.

## Verification

The pipeline proves these properties before a release:

- the source tarball signature matches a key in the CachyOS PKGBUILD
- `lintian` reports no errors
- packages install on Debian 13
- the post-install script creates an initramfs with `virtio_blk` and `ext4`
- `depmod` reports no unresolved symbols
- required modules exist
- a module built against the packaged headers loads in the guest
- the kernel boots on BIOS ext4, BIOS btrfs, and UEFI ext4
- a warm reboot succeeds under UEFI
- the guest reaches `systemctl is-system-running: running`
- dmesg has no oops, BUG, panic, WARN, or UBSAN
- upstream has not moved since the build started

The boot matrix uses QEMU with KVM when the runner exposes `/dev/kvm`, and TCG
otherwise.

## Repository layout

```text
.github/workflows/build-release.yml        build, QA, CVE, boot, release
.github/workflows/check-cachyos-updates.yml poll upstream and dispatch
scripts/upstream-version.sh                 read pkgver and pkgrel from a PKGBUILD
scripts/verify-source-signature.sh          verify the CachyOS source signature
scripts/configure-kernel.sh                 apply and assert the Debian 13 config
scripts/postprocess-debs.py                 add Debian dependencies and firmware recommends
scripts/package-qa.sh                       lintian, install, initramfs, headers, module build
scripts/kernel-cve.py                       official kernel CVE range scan
scripts/test-kernel-cve.py                  unit tests for the CVE scanner
scripts/boot-test.sh                        Debian 13 BIOS and UEFI boot matrix
scripts/render-release-notes.sh             release notes from the gate reports
scripts/update-state.py                     safe state file update
docs/pipeline.md                            design and gate rationale
cachyos-kernel-state.json                   last successfully released version
```

## Important notes

- This is not an official CachyOS or Debian project.
- The kernel is built for Debian 13 only.
- The CachyOS source and packaging metadata are fetched at build time.
- Hardware support depends on firmware, bootloader, Secure Boot, and DKMS.
- The boot matrix uses virtual hardware. Physical hardware remains the final
  compatibility check.
- The kernel is unsigned. Secure Boot users must sign it themselves.
