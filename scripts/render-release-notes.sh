#!/usr/bin/env bash
set -euo pipefail

release_dir="${1:?usage: render-release-notes.sh RELEASE_DIR VARIANT UPSTREAM DEB SOURCE KERNEL_RELEASE OUT}"
variant="${2:?}"
upstream="${3:?}"
deb_version="${4:?}"
source_url="${5:?}"
kernel_release="${6:?}"
out="${7:?}"

cat >"${out}" <<EOF
# CachyOS \`${variant}\` ${upstream} for Debian 13 (trixie)

Unofficial CachyOS kernel packages built from the GPG-verified upstream source.
Debian package version: \`${deb_version}\`. Kernel release: \`${kernel_release}\`.

## Packages

EOF
for deb in "${release_dir}"/linux-image-*.deb "${release_dir}"/linux-headers-*.deb; do
  [[ -f "${deb}" ]] && printf -- '- `%s`\n' "$(basename "${deb}")" >>"${out}"
done

cat >>"${out}" <<EOF

## Verification

The release was published only after every gate passed.

### Package QA

EOF
cat "${release_dir}/qa-report.md" >>"${out}" 2>/dev/null || echo "QA report unavailable." >>"${out}"

cat >>"${out}" <<EOF

### Boot matrix

EOF
cat "${release_dir}/boot-report.md" >>"${out}" 2>/dev/null || echo "Boot report unavailable." >>"${out}"

cat >>"${out}" <<EOF

### Kernel CVE scan

EOF
cat "${release_dir}/cve-report.md" >>"${out}" 2>/dev/null || echo "CVE report unavailable." >>"${out}"

cat >>"${out}" <<EOF

A version-only CVE scan cannot tell whether the vulnerable code is compiled into
this configuration. Treat the report as triage input, not an exploitability
verdict.

## Install on Debian 13

\`\`\`bash
sudo apt install ./linux-image-*.deb ./linux-headers-*.deb
sudo update-grub
sudo reboot
\`\`\`

Keep a Debian kernel installed as a fallback. Confirm the running kernel with
\`uname -r\`.

## NVIDIA and firmware

GPU firmware is not bundled. Enable \`non-free-firmware\` and install the packages
that match the hardware:

\`\`\`bash
sudo apt install firmware-linux-free firmware-misc-nonfree firmware-nvidia-gsp
\`\`\`

Nouveau uses the GSP firmware for Turing and newer cards. For the proprietary
driver, enable the \`non-free\` component and install \`nvidia-driver\`; DKMS builds
the module against the packaged headers. Module signing is disabled in this
kernel so unsigned DKMS modules load.

## Secure Boot

This kernel is unsigned. Secure Boot must be disabled, or the kernel and its
modules signed locally with keys enrolled in the firmware. Do not enable Secure
Boot with this artifact unless you have signed it.

## Source and checksums

Source: <${source_url}>

EOF
cat "${release_dir}/SHA256SUMS" >>"${out}"
