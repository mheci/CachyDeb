# Debian 13 kernel pipeline

This document records the design of the reworked CachyDeb pipeline and the
reasons behind each gate. It is the audit trail for the change.

## Goal

Build CachyOS kernel variants for Debian 13 (trixie), prove the packages install
and boot on Debian 13, and publish a GitHub Release automatically only after
every gate passes.

The falsifiable predicate is:

> For every published release, the attached image package installs on a clean
> Debian 13 root filesystem, boots through the packaged initramfs on BIOS and
> UEFI, survives a warm reboot, loads its modules and a module built against its
> packaged headers, and the release notes link the CVE report and checksums.

## Why Debian 13

The build runs inside `debian:13`. The package QA job runs inside `debian:13`.
The boot tests use a Debian 13 root filesystem. A Debian 12 userland cannot
satisfy the kernel 7.x toolchain assumptions, and Ubuntu artifacts are not the
target. The runner host only supplies CPU, disk, and QEMU. It does not define
the artifact.

## Pipeline

One workflow run handles one kernel variant. This keeps a failed variant from
blocking the other three and keeps release tags and state updates simple.

```
dispatch (scheduler or manual)
  |
  +-- build            Debian 13 container, GPG-verified source, .deb packages
  +-- package-qa       lintian, install test, initramfs, headers, out-of-tree module
  +-- cve-scan         official Linux kernel CVE dataset, report attached to release
  +-- boot-test        Debian 13 rootfs, BIOS ext4, BIOS btrfs, UEFI reboot
  |
  +-- release          rechecks upstream, publishes GitHub Release, records state
```

### Build gate

- Source comes from `CachyOS/linux-cachyos` at `master`.
- The source tarball signature is verified against the `validpgpkeys` in the
  variant PKGBUILD. A missing key or a bad signature fails the build.
- The kernel builds with the Debian 13 GCC toolchain.
- The default CPU target is `x86-64-v3` with `znver3` tuning. The build can be
  switched to `x86-64-v3`, `znver3`, or `generic`. The default does not boot on
  pre-v3 x86-64 hardware.
- `CONFIG_MODULE_SIG_FORCE` and `CONFIG_MODULE_SIG_ALL` are disabled so Debian
  DKMS modules, including the proprietary NVIDIA driver, load without a locally
  trusted key. Lockdown still selects `MODULE_SIG`, so a missing signature taints
  the kernel instead of refusing the module.
- Debug info and BTF are disabled through `DEBUG_INFO_NONE`. This is a runtime
  kernel, not a debug build, and the reduced size keeps the release usable.
- Rust kernel drivers are disabled. The CachyOS desktop kernel and its required
  drivers are C. This keeps the build on the Debian 13 C toolchain and removes a
  compiler-version failure mode.
- Package control fields are post-processed to add the Debian dependencies and
  firmware recommendations that the in-tree `bindeb-pkg` target omits.
- `linux-libc-dev` and the debug package are not published. Debian owns the
  former, and the latter is empty with debug info disabled.

### Package QA gate

- `lintian --fail-on error` on every published `.deb`.
- `depmod -e` over the extracted module tree.
- Required modules checked with `modinfo` for storage, netfilter, WireGuard,
  encryption, NVIDIA, AMD, Intel, and virtualisation.
- Kernel config assertions for boot, firmware, NVIDIA, AppArmor, and DKMS
  requirements.
- Headers package must contain `Module.symvers`, generated config, and the
  external module build scripts.
- A trivial out-of-tree module builds against the packaged headers. Its vermagic
  must match the kernel release. This is the DKMS proxy for the NVIDIA driver.
- The packages are installed into a Debian 13 environment. The post-install
  script must produce an initramfs, and the btrfs module must be includable for
  the btrfs boot scenario.

### CVE gate

The scan uses the official Linux kernel CVE dataset at
`git.kernel.org/pub/scm/linux/security/vulns.git`. It evaluates the semver
ranges in the published JSON records against the upstream kernel version.

The report is a required release asset. The default policy does not block a
release when an affected CVE exists. A version-only scan cannot prove whether
the vulnerable code is compiled in, and blocking publication does not remove an
upstream bug. The report makes the risk visible. A maintainer can set
`fail_on_critical_cve` when a strict block is wanted.

### Boot gate

The boot test builds a clean Debian 13 rootfs with `mmdebstrap`, installs the
image package, and lets the package generate the initramfs. It boots three
scenarios:

1. BIOS direct kernel boot on ext4.
2. BIOS direct kernel boot on btrfs.
3. UEFI systemd-boot on ext4 with a warm reboot.

The guest checks:

- running release matches the package
- root filesystem type matches the scenario
- `systemctl is-system-running` returns `running`
- netfilter, btrfs, xfs, vfat, WireGuard, dm-crypt, and NVMe modules load
- AMD, Intel, and Nouveau modules exist
- a module built against the packaged headers loads and unloads
- an Ethernet interface and a virtio block device exist
- dmesg has no oops, BUG, panic, WARN, UBSAN, or refcount failure
- an unsigned module built against the packaged headers loads and unloads

Any failure stops the run and blocks the release.

### Release gate

- Upstream is fetched again. If `pkgver-pkgrel` moved while the build ran, the
  release is refused. The next scheduled check builds the new version.
- QA, CVE, and boot jobs must have succeeded. Skipping boot tests skips the
  release.
- Provenance is attested with GitHub's build provenance action.
- The release includes the `.deb` files, `BUILD-MANIFEST.txt`, `SHA256SUMS`,
  `kernel.env`, QA report, boot report, CVE report, and release notes.
- The state file is updated only after the release succeeds. A failed release
  therefore does not mark the version as built, and the next poll retries it.

## Scheduling

The checker polls upstream every three hours. It also forces a rebuild every
Monday at 04:00 UTC so toolchain and Debian 13 point-release fixes reach users
even when the kernel version is unchanged.

Duplicate dispatch protection reads recent workflow run titles. A build already
queued or running for the same variant and version is not dispatched again.
State is no longer written before a build completes.

## Pull-request behavior

The build workflow also runs on pull requests that touch the workflow or the
`scripts/` directory. Release and state update are disabled on pull requests.
This is how the pipeline itself is tested before it lands.

## Known limitations

- Secure Boot is not supported. The kernel and modules are unsigned. Users must
  disable Secure Boot or sign the artifacts themselves.
- The CVE report cannot map source files to the built configuration. It may
  report CVEs for drivers that are not compiled in.
- The boot test proves the kernel on QEMU virtual hardware. It cannot prove
  every physical GPU, Wi-Fi card, or firmware blob.
- The NVIDIA test is a generic out-of-tree module, not a build of the
  proprietary driver. Debian `nvidia-driver` DKMS builds against the headers
  with the same mechanism.
- Only x86-64 is built.
- Blacksmith runners are optional. Use `ubuntu-24.04` if the integration is not
  configured.
