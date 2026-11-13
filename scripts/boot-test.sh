#!/usr/bin/env bash
set -euo pipefail

artifacts="${1:?usage: boot-test.sh ARTIFACTS_DIR QA_DIR OUT_DIR VARIANT}"
qa="${2:?usage: boot-test.sh ARTIFACTS_DIR QA_DIR OUT_DIR VARIANT}"
out="${3:?usage: boot-test.sh ARTIFACTS_DIR QA_DIR OUT_DIR VARIANT}"
variant="${4:-unknown}"

[[ "$(id -u)" -eq 0 ]] || { echo "boot-test.sh must run as root" >&2; exit 1; }
mkdir -p "${out}"
work="$(mktemp -d)"
report="${out}/boot-report.md"
: >"${report}"
rootfs="${work}/rootfs"
serial=""
mounted=0

cleanup() {
  if [[ "${mounted}" -eq 1 ]]; then
    umount "${rootfs}/dev/pts" 2>/dev/null || true
    umount "${rootfs}/dev" 2>/dev/null || true
    umount "${rootfs}/sys" 2>/dev/null || true
    umount "${rootfs}/proc" 2>/dev/null || true
  fi
  rm -rf "${work}"
}
trap cleanup EXIT

record() {
  printf '%s\n' "$*" >>"${report}"
}

fail() {
  record "- FAILED: $*"
  echo "boot test failed: $*" >&2
  if [[ -n "${serial}" && -f "${serial}" ]]; then
    tail -n 250 "${serial}" >&2 || true
  fi
  exit 1
}

shopt -s nullglob
image_deb="$(find "${artifacts}" -maxdepth 1 -type f -name 'linux-image-*.deb' ! -name '*-dbg*' | sort -V | head -n1)"
[[ -n "${image_deb}" ]] || fail "no linux-image package in ${artifacts}"
test_ko="${qa}/cachydeb_test.ko"
[[ -f "${test_ko}" ]] || fail "missing out-of-tree test module in ${qa}"

mkdir -p "${work}/image"
dpkg-deb -x "${image_deb}" "${work}/image"
release="$(find "${work}/image/lib/modules" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | head -n1)"
[[ -n "${release}" ]] || fail "image package has no kernel release"
vmlinuz="${work}/image/boot/vmlinuz-${release}"
[[ -f "${vmlinuz}" ]] || fail "missing vmlinuz-${release}"

record "# Debian 13 boot matrix"
record ""
record "- Variant: ${variant}"
record "- Kernel release: ${release}"
record "- Root filesystems: ext4, btrfs"
record "- Firmware: BIOS direct kernel and UEFI systemd-boot"
record ""

keyring_deb="${work}/debian-archive-keyring.deb"
curl -fsSL --retry 3 --retry-delay 5 \
  https://deb.debian.org/debian/pool/main/d/debian-archive-keyring/debian-archive-keyring_2025.1_all.deb \
  -o "${keyring_deb}" || fail "could not download the Debian archive keyring"
dpkg-deb -x "${keyring_deb}" "${work}/keyring"
keyring="${work}/keyring/usr/share/keyrings/debian-archive-keyring.gpg"
[[ -s "${keyring}" ]] || fail "Debian archive keyring is missing"

mmdebstrap --mode=root --variant=minbase --components=main \
  --keyring="${keyring}" \
  --aptopt='Acquire::Retries "3"' \
  --include=bash,systemd-sysv,initramfs-tools,kmod,udev,e2fsprogs,util-linux,iproute2,procps,linux-base,ca-certificates \
  trixie "${rootfs}" http://deb.debian.org/debian >"${out}/mmdebstrap.log" 2>&1 \
  || fail "could not build a Debian 13 root filesystem"

mkdir -p "${rootfs}/tmp/debs" "${rootfs}/root"
cp "${image_deb}" "${rootfs}/tmp/debs/"
cp "${test_ko}" "${rootfs}/root/cachydeb_test.ko"
printf 'virtio_pci\nvirtio_blk\nvirtio_net\nvirtio_console\next4\nbtrfs\n' >"${rootfs}/etc/initramfs-tools/modules"
echo "${release}" >"${rootfs}/etc/cachydeb-release"

cat >"${rootfs}/usr/local/sbin/cachydeb-boot-check" <<'EOF'
#!/bin/bash
set -uo pipefail
exec >/dev/console 2>&1

fail() {
	echo "CACHYDEB_BOOT_FAIL reason=$*"
	systemctl poweroff -f
	exit 1
}

expected_release="$(cat /etc/cachydeb-release)"
expected_fs="$(sed -n 's/.*cachydeb.rootfs=\([^ ]*\).*/\1/p' /proc/cmdline)"
expected_reboot="$(sed -n 's/.*cachydeb.reboot=\([^ ]*\).*/\1/p' /proc/cmdline)"
attempt=1
if [[ -f /var/lib/cachydeb-boot-count ]]; then
	attempt=$(( $(cat /var/lib/cachydeb-boot-count) + 1 ))
fi
echo "${attempt}" >/var/lib/cachydeb-boot-count

actual_release="$(uname -r)"
[[ "${actual_release}" == "${expected_release}" ]] || fail "release=${actual_release} expected=${expected_release}"

actual_fs="$(findmnt -n -o FSTYPE /)"
[[ "${actual_fs}" == "${expected_fs}" ]] || fail "rootfs=${actual_fs} expected=${expected_fs}"

state="starting"
for _ in $(seq 1 60); do
	state="$(systemctl is-system-running || true)"
	[[ "${state}" == "running" || "${state}" == "degraded" ]] && break
	sleep 1
done
[[ "${state}" == "running" ]] || {
	systemctl --failed --no-legend || true
	fail "system-state=${state}"
}

for module in btrfs xfs vfat nf_tables wireguard dm_crypt nvme; do
	modprobe "${module}" || fail "modprobe=${module}"
done
for module in amdgpu i915 nouveau; do
	modinfo "${module}" >/dev/null || fail "modinfo=${module}"
done

insmod /root/cachydeb_test.ko || fail "insmod out-of-tree module"
rmmod cachydeb_test || fail "rmmod out-of-tree module"

ip -o link show | grep -q 'link/ether' || fail "no ethernet interface"
[[ -b /dev/vda || -b /dev/vdb ]] || fail "no virtio block device"

bad="$(dmesg | grep -E 'kernel BUG at|Oops:|general protection fault|BUG: unable to handle|Kernel panic|WARNING: CPU:|UBSAN:|refcount_t: underflow|list_del corruption' || true)"
[[ -z "${bad}" ]] || fail "dmesg=${bad}"

echo "CACHYDEB_BOOT_OK release=${actual_release} rootfs=${actual_fs} attempt=${attempt}"

if [[ "${attempt}" -eq 1 && "${expected_reboot}" == "1" ]]; then
	systemctl reboot
else
	echo "CACHYDEB_POWEROFF"
	systemctl poweroff -f
fi
EOF
chmod 755 "${rootfs}/usr/local/sbin/cachydeb-boot-check"

cat >"${rootfs}/etc/systemd/system/cachydeb-boot-check.service" <<'EOF'
[Unit]
Description=CachyDeb boot verification
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/cachydeb-boot-check
StandardOutput=journal+console
StandardError=journal+console
EOF
cat >"${rootfs}/etc/systemd/system/cachydeb-boot-check.timer" <<'EOF'
[Unit]
Description=CachyDeb boot verification timer

[Timer]
OnBootSec=25s
Unit=cachydeb-boot-check.service

[Install]
WantedBy=timers.target
EOF
mkdir -p "${rootfs}/etc/systemd/system/timers.target.wants"
ln -sf /etc/systemd/system/cachydeb-boot-check.timer \
  "${rootfs}/etc/systemd/system/timers.target.wants/cachydeb-boot-check.timer"

mount --bind /proc "${rootfs}/proc"
mount --bind /sys "${rootfs}/sys"
mount --bind /dev "${rootfs}/dev"
mount --bind /dev/pts "${rootfs}/dev/pts"
mounted=1

if ! chroot "${rootfs}" /bin/bash -c 'export DEBIAN_FRONTEND=noninteractive; dpkg -i /tmp/debs/*.deb'; then
  chroot "${rootfs}" /bin/bash -c 'export DEBIAN_FRONTEND=noninteractive; apt-get update && apt-get -f install -y' \
    >>"${out}/install.log" 2>&1 || fail "kernel packages did not install in the Debian 13 rootfs"
fi
chroot "${rootfs}" /bin/bash -c 'export DEBIAN_FRONTEND=noninteractive; dpkg --configure -a; sed -i "s/^MODULES=.*/MODULES=most/" /etc/initramfs-tools/initramfs.conf; grep -q "^MODULES=" /etc/initramfs-tools/initramfs.conf || echo "MODULES=most" >> /etc/initramfs-tools/initramfs.conf; update-initramfs -u -k all' \
  >>"${out}/install.log" 2>&1 || fail "initramfs generation failed in the Debian 13 rootfs"

[[ -s "${rootfs}/boot/initrd.img-${release}" ]] || fail "no initramfs for ${release}"
# virtio_blk and ext4 are built in; btrfs is the module this test can observe.
if ! lsinitramfs "${rootfs}/boot/initrd.img-${release}" | grep -q 'btrfs'; then
  fail "initramfs is missing btrfs"
fi

umount "${rootfs}/dev/pts"
umount "${rootfs}/dev"
umount "${rootfs}/sys"
umount "${rootfs}/proc"
mounted=0

rm -f "${rootfs}/var/lib/cachydeb-boot-count"

ext4_img="${work}/root-ext4.img"
btrfs_img="${work}/root-btrfs.img"
truncate -s 3G "${ext4_img}"
mkfs.ext4 -q -F -L cachydeb-root -d "${rootfs}" "${ext4_img}"
truncate -s 3G "${btrfs_img}"
mkfs.btrfs -q -f -L cachydeb-root -r "${rootfs}" "${btrfs_img}"

esp_img="${work}/esp.img"
esp_part="${work}/esp-part.img"
truncate -s 520M "${esp_img}"
parted -s "${esp_img}" mklabel gpt mkpart ESP fat32 1MiB 513MiB
sgdisk -t 1:ef00 "${esp_img}"
mkfs.vfat -F 32 -n ESP -C "${esp_part}" 512M
mmd -i "${esp_part}" ::/EFI ::/EFI/BOOT ::/EFI/systemd ::/loader ::/loader/entries
boot_binary=""
for candidate in /usr/lib/systemd/boot/efi/systemd-bootx64.efi /usr/lib/systemd/boot/efi/systemd-bootx64.efi.signed; do
  if [[ -f "${candidate}" ]]; then
    boot_binary="${candidate}"
    break
  fi
done
[[ -n "${boot_binary}" ]] || fail "systemd-boot EFI binary not found on the host"
mcopy -i "${esp_part}" "${boot_binary}" ::/EFI/BOOT/BOOTX64.EFI
mcopy -i "${esp_part}" "${boot_binary}" ::/EFI/systemd/systemd-bootx64.efi
printf 'default cachydeb.conf\ntimeout 0\n' >"${work}/loader.conf"
mcopy -i "${esp_part}" "${work}/loader.conf" ::/loader/loader.conf
mcopy -i "${esp_part}" "${vmlinuz}" ::/vmlinuz
mcopy -i "${esp_part}" "${rootfs}/boot/initrd.img-${release}" ::/initrd.img

ovmf=""
for candidate in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd; do
  if [[ -f "${candidate}" ]]; then
    ovmf="${candidate}"
    break
  fi
done
[[ -n "${ovmf}" ]] || fail "OVMF firmware not found on the host"

if [[ -e /dev/kvm && -r /dev/kvm && -w /dev/kvm ]]; then
  accel="kvm"
  cpu="host"
else
  accel="tcg"
  cpu="max"
fi
record "- QEMU acceleration: ${accel}"
record ""

qemu_common=(-m 2048 -smp 2 -display none -monitor none
  -netdev "user,id=n0" -device "virtio-net-pci,netdev=n0"
  -device virtio-rng-pci)

run_bios() {
  local name="$1" image="$2" fstype="$3"
  serial="${out}/${name}.log"
  local cmdline="root=/dev/vda rw console=ttyS0,115200 systemd.journald.forward_to_console=1 systemd.show_status=1 panic=30 oops=panic cachydeb.rootfs=${fstype} cachydeb.reboot=0"
  cp --reflink=auto "${image}" "${work}/${name}.img"
  set +e
  timeout 900 qemu-system-x86_64 -machine "pc,accel=${accel}" -cpu "${cpu}" \
    "${qemu_common[@]}" -drive "file=${work}/${name}.img,if=virtio,format=raw,cache=writeback" \
    -kernel "${vmlinuz}" -initrd "${rootfs}/boot/initrd.img-${release}" -append "${cmdline}" \
    -no-reboot >/dev/null 2>&1
  local status=$?
  set -e
  local ok
  ok="$(grep -c 'CACHYDEB_BOOT_OK' "${serial}" 2>/dev/null || true)"
  [[ "${status}" -eq 0 ]] || fail "${name}: qemu exited with ${status}"
  [[ "${ok}" -ge 1 ]] || fail "${name}: no boot success marker"
  grep -q 'CACHYDEB_POWEROFF' "${serial}" || fail "${name}: guest did not power off"
  if grep -Eq 'Kernel panic|Oops:|kernel BUG at' "${serial}"; then
    fail "${name}: fatal kernel message in serial log"
  fi
  record "- ${name}: PASS (BIOS, ${fstype})"
}

run_uefi() {
  local name="$1" image="$2" fstype="$3"
  serial="${out}/${name}.log"
  local cmdline="root=/dev/vdb rw console=ttyS0,115200 systemd.journald.forward_to_console=1 systemd.show_status=1 panic=30 oops=panic cachydeb.rootfs=${fstype} cachydeb.reboot=1"
  cat >"${work}/entry.conf" <<EOF
title CachyDeb ${variant} ${release}
linux /vmlinuz
initrd /initrd.img
options ${cmdline}
EOF
  mcopy -o -i "${esp_part}" "${work}/entry.conf" ::/loader/entries/cachydeb.conf
  dd if="${esp_part}" of="${esp_img}" bs=1M seek=1 conv=notrunc status=none
  cp --reflink=auto "${image}" "${work}/${name}.img"
  set +e
  timeout 900 qemu-system-x86_64 -machine "q35,accel=${accel}" -cpu "${cpu}" \
    "${qemu_common[@]}" -bios "${ovmf}" \
    -drive "file=${esp_img},if=virtio,format=raw" \
    -drive "file=${work}/${name}.img,if=virtio,format=raw,cache=writeback" >/dev/null 2>&1
  local status=$?
  set -e
  local ok
  ok="$(grep -c 'CACHYDEB_BOOT_OK' "${serial}" 2>/dev/null || true)"
  [[ "${status}" -eq 0 ]] || fail "${name}: qemu exited with ${status}"
  [[ "${ok}" -ge 2 ]] || fail "${name}: expected two successful boots, got ${ok}"
  grep -q 'CACHYDEB_BOOT_OK .*attempt=1' "${serial}" || fail "${name}: first boot marker missing"
  grep -q 'CACHYDEB_BOOT_OK .*attempt=2' "${serial}" || fail "${name}: reboot marker missing"
  grep -q 'CACHYDEB_POWEROFF' "${serial}" || fail "${name}: guest did not power off"
  if grep -Eq 'Kernel panic|Oops:|kernel BUG at' "${serial}"; then
    fail "${name}: fatal kernel message in serial log"
  fi
  record "- ${name}: PASS (UEFI systemd-boot, ${fstype}, warm reboot)"
}

run_bios "bios-ext4" "${ext4_img}" "ext4"
run_bios "bios-btrfs" "${btrfs_img}" "btrfs"
run_uefi "uefi-ext4-reboot" "${ext4_img}" "ext4"

record ""
record "Result: PASS"
