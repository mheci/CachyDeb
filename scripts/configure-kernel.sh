#!/usr/bin/env bash
set -euo pipefail

srctree="${1:?usage: configure-kernel.sh /path/to/linux-source CPU_OPTIMIZATION}"
cpu_optimization="${2:-x86-64-v3-znver3}"
cd "${srctree}"

cfg() {
  scripts/config "$@" >/dev/null 2>&1 || true
}

cfg --set-str LOCALVERSION "-cachyos-debian"
cfg --set-str SYSTEM_TRUSTED_KEYS ""
cfg --set-str SYSTEM_REVOCATION_KEYS ""

disable_signature_enforcement_and_debug() {
  # Lockdown selects MODULE_SIG. Enforcement is what must stay off for DKMS.
  cfg -d MODULE_SIG_ALL
  cfg -d MODULE_SIG_FORCE
  # Debug info and BTF multiply build time and package size; this is a runtime kernel.
  cfg -d DEBUG_INFO
  cfg -d DEBUG_INFO_DWARF5
  cfg -d DEBUG_INFO_DWARF4
  cfg -d DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT
  cfg -d DEBUG_INFO_REDUCED
  cfg -d DEBUG_INFO_COMPRESSED_NONE
  cfg -d DEBUG_INFO_COMPRESSED_ZLIB
  cfg -d DEBUG_INFO_COMPRESSED_ZSTD
  cfg -d DEBUG_INFO_SPLIT
  cfg -d DEBUG_INFO_BTF
  cfg -d DEBUG_INFO_BTF_MODULES
}
disable_signature_enforcement_and_debug
cfg -d WERROR

cfg -e MODULES
cfg -e MODULE_UNLOAD
# The Debian 13 C toolchain is the only compiler this build relies on.
cfg -d RUST
cfg -e KALLSYMS
cfg -e KALLSYMS_ALL
cfg -e IKCONFIG
cfg -e IKCONFIG_PROC
cfg -e CACHY
for cpu_opt in \
  GENERIC_CPU GENERIC_CPU2 GENERIC_CPU3 GENERIC_CPU4 MNATIVE MPSC MATOM MCORE2 \
  MNEHALEM MWESTMERE MSILVERMONT MGOLDMONT MGOLDMONTPLUS MSKYLAKE \
  MSKYLAKEX MCANNONLAKE MICELAKE MCASCADELAKE MCOOPERLAKE \
  MTIGERLAKE MSAPPHIRERAPIDS MROCKETLAKE MALDERLAKE MRAPTORLAKE \
  MMETEORLAKE MEMERALDRAPIDS MZEN MZEN2 MZEN3 MZEN4 MZEN5; do
  cfg -d "${cpu_opt}"
done
case "${cpu_optimization}" in
  generic)
    cfg -e GENERIC_CPU
    cfg --set-val X86_64_VERSION 1
    ;;
  x86-64-v3|x86-64-v3-znver3)
    cfg -e GENERIC_CPU3
    cfg --set-val X86_64_VERSION 3
    ;;
  znver3)
    cfg -e MZEN3
    cfg --set-val X86_64_VERSION 3
    ;;
  *)
    echo "unsupported CPU optimization: ${cpu_optimization}" >&2
    exit 1
    ;;
esac
cfg -e HZ_1000
cfg --set-val HZ 1000
cfg -e PREEMPT_DYNAMIC
cfg -e PREEMPT
cfg -e NO_HZ_IDLE
cfg -d NO_HZ_FULL
cfg -e HIGH_RES_TIMERS
cfg -e CPU_FREQ
cfg -e CPU_FREQ_GOV_SCHEDUTIL
cfg -e CPU_FREQ_DEFAULT_GOV_SCHEDUTIL
cfg -e X86_AMD_PSTATE
cfg -e ACPI
cfg -e EFI
cfg -e EFI_STUB
cfg -e EFI_PARTITION

cfg -e BLK_DEV_INITRD
cfg -e BINFMT_ELF
cfg -e BINFMT_SCRIPT
cfg -e DEVTMPFS
cfg -e DEVTMPFS_MOUNT
cfg -e PRINTK
cfg -e EARLY_PRINTK
cfg -e TTY
cfg -e SERIAL_8250
cfg -e SERIAL_8250_CONSOLE
cfg -e SERIAL_8250_PCI
cfg -e SERIAL_EARLYCON
cfg -e SERIAL_CORE
cfg -e SERIAL_CORE_CONSOLE
cfg -e RD_GZIP
cfg -e RD_ZSTD
cfg -e RD_XZ
cfg -e TMPFS
cfg -e CGROUPS
cfg -e CGROUP_BPF
cfg -e PSI
cfg -e BPF
cfg -e BPF_SYSCALL
cfg -e BPF_JIT

cfg -e NET
cfg -e INET
cfg -m TCP_CONG_BBR
cfg -m NET_SCH_FQ
cfg -e NETFILTER
cfg -e NETFILTER_ADVANCED
cfg -m NF_TABLES
cfg -m NF_CONNTRACK
cfg -m NETFILTER_XTABLES
cfg -m IP_NF_IPTABLES
cfg -m IP6_NF_IPTABLES
cfg -m BRIDGE
cfg -m BRIDGE_NETFILTER
cfg -m VLAN_8021Q
cfg -m WIREGUARD

cfg -e INPUT
cfg -e INPUT_EVDEV
cfg -e HID
cfg -m HID_GENERIC
cfg -m HID_MULTITOUCH
cfg -m I2C_HID_ACPI
cfg -m USB_HID
cfg -e USB_XHCI_HCD
cfg -m USB_STORAGE
cfg -m UVC_VIDEO
cfg -m SND_HDA_INTEL
cfg -m SND_USB_AUDIO

cfg -e DRM
cfg -e DRM_FBDEV_EMULATION
cfg -m DRM_AMDGPU
cfg -e DRM_AMD_DC
cfg -m DRM_I915
cfg -m DRM_XE
cfg -m DRM_NOUVEAU
cfg -e DRM_NOUVEAU_BACKLIGHT
cfg -m DRM_VIRTIO_GPU
cfg -e FB_EFI
cfg -e FRAMEBUFFER_CONSOLE

cfg -e FW_LOADER
cfg -e FW_LOADER_COMPRESS
cfg -e FW_LOADER_COMPRESS_XZ
cfg -e FW_LOADER_COMPRESS_ZSTD
cfg -e MODULE_COMPRESS
cfg -d MODULE_COMPRESS_GZIP
cfg -d MODULE_COMPRESS_XZ
cfg -e MODULE_COMPRESS_ZSTD
cfg -e MODULE_COMPRESS_ALL

cfg -m BT
cfg -m BT_HCIBTUSB
cfg -e WLAN
cfg -m CFG80211
cfg -m MAC80211
cfg -m IWLWIFI
cfg -e IWLWIFI_OPMODE_MODULAR
cfg -m ATH10K
cfg -m ATH11K
cfg -m RTW88
cfg -m RTW89
cfg -m MT76

cfg -e EXT4_FS
cfg -m BTRFS_FS
cfg -m XFS_FS
cfg -m F2FS_FS
cfg -m EXFAT_FS
cfg -m NTFS3_FS
cfg -m NFS_FS
cfg -m CIFS
cfg -m OVERLAY_FS
cfg -m SQUASHFS
cfg -e SQUASHFS_ZSTD
cfg -m EROFS_FS
cfg -e FUSE_FS
cfg -e VIRTIO_FS
cfg -m ZRAM
cfg -e ZSWAP
cfg -m VFAT_FS
cfg -m MSDOS_FS
cfg -e FAT_FS

cfg -e BLK_DEV_NVME
cfg -e NVME_CORE
cfg -e MD
cfg -m BLK_DEV_DM
cfg -m DM_CRYPT
cfg -m DM_SNAPSHOT
cfg -m DM_THIN_PROVISIONING
cfg -m MD_RAID1
cfg -e CRYPTO_XTS
cfg -e CRYPTO_AES_NI_INTEL

cfg -m KVM
cfg -m KVM_INTEL
cfg -m KVM_AMD
cfg -m VFIO
cfg -m VFIO_PCI
cfg -e VIRTIO
cfg -e VIRTIO_PCI
cfg -e VIRTIO_BLK
cfg -m VIRTIO_NET
cfg -e VIRTIO_CONSOLE
cfg -m VIRTIO_SCSI

cfg -e SECURITY_APPARMOR

make olddefconfig
# Second pass: some fragments carry child symbols that can re-enable the parent.
disable_signature_enforcement_and_debug
make olddefconfig
grep -E 'CONFIG_(MODULE_SIG|DEBUG_INFO)' .config >&2 || true

failed=0
assert_cfg() {
  local sym="$1" want="$2" line
  line="$(grep -E "^(# )?CONFIG_${sym}(=| is not set)" .config | head -n1 || true)"
  case "${want}" in
    y|m)
      if [[ "${line}" != "CONFIG_${sym}=${want}" ]]; then
        echo "config assertion failed: wanted CONFIG_${sym}=${want}, got '${line:-missing}'" >&2
        failed=1
      fi
      ;;
    n)
      if [[ "${line}" != "# CONFIG_${sym} is not set" ]]; then
        echo "config assertion failed: wanted CONFIG_${sym} off, got '${line:-missing}'" >&2
        failed=1
      fi
      ;;
  esac
}

assert_cfg MODULES y
assert_cfg MODULE_UNLOAD y
assert_cfg BLK_DEV_INITRD y
assert_cfg BINFMT_ELF y
assert_cfg BINFMT_SCRIPT y
assert_cfg DEVTMPFS y
assert_cfg DEVTMPFS_MOUNT y
assert_cfg PRINTK y
assert_cfg SERIAL_8250 y
assert_cfg SERIAL_8250_CONSOLE y
assert_cfg EFI y
assert_cfg EFI_STUB y
assert_cfg ACPI y
assert_cfg NET y
assert_cfg INET y
assert_cfg NETFILTER y
assert_cfg NETFILTER_ADVANCED y
assert_cfg NF_TABLES m
assert_cfg NF_CONNTRACK m
assert_cfg NETFILTER_XTABLES m
assert_cfg IP_NF_IPTABLES m
assert_cfg IP6_NF_IPTABLES m
assert_cfg WIREGUARD m
assert_cfg DRM y
assert_cfg DRM_AMDGPU m
assert_cfg DRM_I915 m
assert_cfg DRM_NOUVEAU m
assert_cfg DRM_XE m
assert_cfg DRM_VIRTIO_GPU m
assert_cfg FW_LOADER y
assert_cfg FW_LOADER_COMPRESS_XZ y
assert_cfg FW_LOADER_COMPRESS_ZSTD y
assert_cfg MODULE_COMPRESS_ZSTD y
assert_cfg MODULE_COMPRESS_ALL y
assert_cfg EXT4_FS y
assert_cfg BTRFS_FS m
assert_cfg XFS_FS m
assert_cfg VIRTIO y
assert_cfg VIRTIO_PCI y
assert_cfg VIRTIO_BLK y
assert_cfg VIRTIO_NET m
assert_cfg KVM m
assert_cfg KVM_INTEL m
assert_cfg KVM_AMD m
assert_cfg VFIO m
assert_cfg VFIO_PCI m
assert_cfg BLK_DEV_NVME y
assert_cfg NVME_CORE y
assert_cfg MD y
assert_cfg BLK_DEV_DM m
assert_cfg DM_CRYPT m
assert_cfg WLAN y
assert_cfg SECURITY_APPARMOR y
assert_cfg ZSWAP y
case "${cpu_optimization}" in
  generic)
    assert_cfg GENERIC_CPU y
    assert_cfg X86_64_VERSION 1
    ;;
  x86-64-v3|x86-64-v3-znver3)
    assert_cfg GENERIC_CPU3 y
    assert_cfg X86_64_VERSION 3
    ;;
  znver3)
    assert_cfg MZEN3 y
    ;;
esac
assert_cfg HZ 1000
assert_cfg PREEMPT_DYNAMIC y
assert_cfg MODULE_SIG_ALL n
assert_cfg MODULE_SIG_FORCE n
assert_cfg DEBUG_INFO_NONE y
assert_cfg WERROR n

if grep -qE '^CONFIG_RUST=(y|m)' .config; then
  echo "config assertion failed: CONFIG_RUST is enabled" >&2
  failed=1
fi

grep -qx 'CONFIG_LOCALVERSION="-cachyos-debian"' .config || {
  echo "config assertion failed: LOCALVERSION is not -cachyos-debian" >&2
  failed=1
}

if [[ "${failed}" -ne 0 ]]; then
  echo "kernel configuration is not suitable for the Debian 13 release gate" >&2
  exit 1
fi

echo "kernel configuration verified"
grep -E '^CONFIG_(LOCALVERSION|HZ|MODULE_SIG|DEBUG_INFO|GENERIC_CPU|GENERIC_CPU3|MZEN3|X86_64_VERSION|DRM_NOUVEAU|DRM_AMDGPU|DRM_I915|FW_LOADER|MODULE_COMPRESS_ZSTD|BTRFS_FS|EXT4_FS)=' .config || true
