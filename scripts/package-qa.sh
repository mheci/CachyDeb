#!/usr/bin/env bash
set -euo pipefail

artifacts="${1:?usage: package-qa.sh ARTIFACTS_DIR OUT_DIR VARIANT}"
out="${2:?usage: package-qa.sh ARTIFACTS_DIR OUT_DIR VARIANT}"
variant="${3:-unknown}"

mkdir -p "${out}"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
report="${out}/qa-report.md"
: >"${report}"

record() {
  printf '%s\n' "$*" >>"${report}"
}

fail() {
  record "- FAILED: $*"
  echo "package QA failed: $*" >&2
  exit 1
}

# shellcheck disable=SC2154
trap 'status=$?; if [[ ${status} -ne 0 ]]; then printf -- "- FAILED: command exited with status %s\n" "${status}" >>"${report}"; fi' EXIT

shopt -s nullglob
debs=("${artifacts}"/*.deb)
[[ ${#debs[@]} -gt 0 ]] || fail "no .deb files in ${artifacts}"

mapfile -t images < <(find "${artifacts}" -maxdepth 1 -type f -name 'linux-image-*.deb' ! -name '*-dbg*' | sort)
mapfile -t headers < <(find "${artifacts}" -maxdepth 1 -type f -name 'linux-headers-*.deb' | sort)
[[ ${#images[@]} -eq 1 ]] || fail "expected one linux-image package, found ${#images[@]}"
[[ ${#headers[@]} -eq 1 ]] || fail "expected one linux-headers package, found ${#headers[@]}"
image_deb="${images[0]}"
headers_deb="${headers[0]}"

record "# Debian 13 package QA"
record ""
record "- Variant: ${variant}"
record "- Image package: $(basename "${image_deb}")"
record "- Headers package: $(basename "${headers_deb}")"

record ""
record "## lintian"
for deb in "${debs[@]}"; do
  if ! lintian --fail-on error --suppress-tags unstripped-binary-or-object "${deb}" >>"${out}/lintian.txt" 2>&1; then
    fail "lintian rejected $(basename "${deb}")"
  fi
done
record "- pass"

record ""
record "## package layout"
mkdir -p "${work}/image" "${work}/headers"
dpkg-deb -x "${image_deb}" "${work}/image"
dpkg-deb -x "${headers_deb}" "${work}/headers"

release="$(find "${work}/image/lib/modules" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | head -n1)"
[[ -n "${release}" ]] || fail "image package has no kernel release directory"
record "- Kernel release: ${release}"
[[ -f "${work}/image/boot/vmlinuz-${release}" ]] || fail "missing /boot/vmlinuz-${release}"
[[ -f "${work}/image/boot/System.map-${release}" ]] || fail "missing /boot/System.map-${release}"
[[ -f "${work}/image/boot/config-${release}" ]] || fail "missing /boot/config-${release}"
[[ -d "${work}/image/lib/modules/${release}" ]] || fail "missing module tree"
[[ -s "${work}/image/lib/modules/${release}/modules.builtin" ]] || fail "missing modules.builtin"
record "- vmlinuz, System.map, config, modules.builtin: present"

if ! depmod -e -b "${work}/image" "${release}" >"${out}/depmod.txt" 2>&1; then
  cat "${out}/depmod.txt" >&2
  fail "depmod reported unresolved symbols"
fi
record "- depmod: clean"

missing=0
required_modules=(
  btrfs xfs vfat nf_tables wireguard dm_crypt nvme
  amdgpu i915 nouveau kvm overlay squashfs erofs cifs
)
for module in "${required_modules[@]}"; do
  if ! modinfo -b "${work}/image" -k "${release}" "${module}" >/dev/null 2>&1; then
    record "- missing module: ${module}"
    missing=1
  fi
done
[[ "${missing}" -eq 0 ]] || fail "required kernel modules are missing"
record "- required modules: ${required_modules[*]}"

config="${work}/image/boot/config-${release}"
assert_cfg() {
  local sym="$1" want="$2" line
  line="$(grep -E "^(# )?CONFIG_${sym}(=| is not set)" "${config}" | head -n1 || true)"
  case "${want}" in
    y|m) [[ "${line}" == "CONFIG_${sym}=${want}" ]] || fail "config ${sym} wanted ${want}, got '${line:-missing}'" ;;
    n) [[ "${line}" == "# CONFIG_${sym} is not set" ]] || fail "config ${sym} wanted off, got '${line:-missing}'" ;;
  esac
}

assert_cfg MODULES y
assert_cfg BLK_DEV_INITRD y
assert_cfg SERIAL_8250_CONSOLE y
assert_cfg EFI_STUB y
assert_cfg NETFILTER y
assert_cfg NETFILTER_ADVANCED y
assert_cfg NF_TABLES m
assert_cfg NF_CONNTRACK m
assert_cfg NETFILTER_XTABLES m
assert_cfg WIREGUARD m
assert_cfg DRM_AMDGPU m
assert_cfg DRM_I915 m
assert_cfg DRM_NOUVEAU m
assert_cfg FW_LOADER y
assert_cfg FW_LOADER_COMPRESS_ZSTD y
assert_cfg EXT4_FS y
assert_cfg BTRFS_FS m
assert_cfg XFS_FS m
assert_cfg MODULE_COMPRESS_ZSTD y
assert_cfg HZ 1000
assert_cfg ZSWAP y
assert_cfg KVM m
assert_cfg DM_CRYPT m
assert_cfg SECURITY_APPARMOR y
assert_cfg MODULE_SIG_ALL n
assert_cfg MODULE_SIG_FORCE n
assert_cfg DEBUG_INFO_NONE y
assert_cfg WERROR n
grep -qx 'CONFIG_LOCALVERSION="-cachyos-debian"' "${config}" || fail "LOCALVERSION is not -cachyos-debian"
record "- kernel config: required Debian desktop, NVIDIA, firmware, and DKMS settings present"

headers_dir="$(find "${work}/headers/usr/src" -mindepth 1 -maxdepth 1 -type d -name 'linux-headers-*' -print -quit)"
[[ -n "${headers_dir}" ]] || fail "headers package has no /usr/src/linux-headers-* tree"
[[ -f "${headers_dir}/Makefile" ]] || fail "headers tree has no Makefile"
[[ -f "${headers_dir}/Module.symvers" ]] || fail "headers tree has no Module.symvers"
[[ -f "${headers_dir}/include/config/auto.conf" || -f "${headers_dir}/include/generated/autoconf.h" ]] || fail "headers tree has no generated config"
record "- headers tree: complete"

module_dir="${work}/module-test"
mkdir -p "${module_dir}"
cat >"${module_dir}/cachydeb_test.c" <<'EOF'
#include <linux/module.h>
#include <linux/kernel.h>

static int __init cachydeb_test_init(void)
{
	pr_info("cachydeb test module loaded\n");
	return 0;
}

static void __exit cachydeb_test_exit(void)
{
	pr_info("cachydeb test module unloaded\n");
}

module_init(cachydeb_test_init);
module_exit(cachydeb_test_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("CachyDeb header and module ABI smoke test");
EOF
cat >"${module_dir}/Makefile" <<'EOF'
obj-m := cachydeb_test.o
EOF

if ! make -C "${headers_dir}" M="${module_dir}" KERNELRELEASE="${release}" modules >"${out}/module-build.log" 2>&1; then
  cat "${out}/module-build.log" >&2
  fail "out-of-tree module build against the packaged headers"
fi
ko="${module_dir}/cachydeb_test.ko"
[[ -f "${ko}" ]] || fail "module build produced no cachydeb_test.ko"
vermagic="$(modinfo -F vermagic "${ko}" || true)"
[[ "${vermagic}" == *"${release}"* ]] || fail "module vermagic '${vermagic}' does not match ${release}"
cp "${ko}" "${out}/cachydeb_test.ko"
record "- out-of-tree module build: pass (vermagic ${vermagic%% *})"

apt-get update >>"${out}/install.log" 2>&1
if ! apt-get install -y --no-install-recommends initramfs-tools linux-base kmod linux-libc-dev >>"${out}/install.log" 2>&1; then
  fail "could not install initramfs and header build dependencies"
fi
if ! apt-get install -y --no-install-recommends "./${image_deb}" "./${headers_deb}" >>"${out}/install.log" 2>&1; then
  tail -n 80 "${out}/install.log" >&2
  fail "packages did not install on Debian 13"
fi
record "- install on Debian 13: pass"

[[ -f "/boot/vmlinuz-${release}" ]] || fail "installed image has no /boot/vmlinuz-${release}"
if ! update-initramfs -c -k "${release}" >>"${out}/initramfs.log" 2>&1; then
  fail "update-initramfs failed"
fi
[[ -s "/boot/initrd.img-${release}" ]] || fail "installed image produced no initramfs"
for wanted in virtio_blk ext4; do
  if ! lsinitramfs "/boot/initrd.img-${release}" | grep -q "${wanted}"; then
    fail "initramfs is missing ${wanted}"
  fi
done
record "- initramfs generation: pass (virtio_blk, ext4)"

record ""
record "Result: PASS"
