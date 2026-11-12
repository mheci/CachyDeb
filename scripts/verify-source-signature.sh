#!/usr/bin/env bash
set -euo pipefail

pkgbuild="${1:?usage: verify-source-signature.sh PKGBUILD TARBALL SIGNATURE}"
tarball="${2:?usage: verify-source-signature.sh PKGBUILD TARBALL SIGNATURE}"
signature="${3:?usage: verify-source-signature.sh PKGBUILD TARBALL SIGNATURE}"

for file in "${pkgbuild}" "${tarball}" "${signature}"; do
  [[ -f "${file}" ]] || { echo "missing file: ${file}" >&2; exit 1; }
done

export XDG_DATA_HOME="${XDG_DATA_HOME:-${HOME:-/root}/.local/share}"
set +u
# shellcheck disable=SC1090
source "${pkgbuild}" >/dev/null 2>&1
set -u

# shellcheck disable=SC2154
declare -p validpgpkeys >/dev/null 2>&1 || {
  echo "PKGBUILD does not define validpgpkeys" >&2
  exit 1
}

export GNUPGHOME
GNUPGHOME="$(mktemp -d)"
trap 'rm -rf "${GNUPGHOME}"' EXIT
chmod 700 "${GNUPGHOME}"

key_servers=(hkps://keyserver.ubuntu.com hkps://keys.openpgp.org)
for key in "${validpgpkeys[@]}"; do
  imported=0
  for server in "${key_servers[@]}"; do
    if timeout 90 gpg --batch --quiet --keyserver "${server}" --recv-keys "${key}" 2>/dev/null; then
      imported=1
      break
    fi
  done
  if [[ "${imported}" -ne 1 ]]; then
    echo "could not import CachyOS signing key ${key}" >&2
    exit 1
  fi
done

status_file="$(mktemp)"
error_file="$(mktemp)"
trap 'rm -rf "${GNUPGHOME}" "${status_file}" "${error_file}"' EXIT

if ! gpg --batch --status-fd 1 --verify "${signature}" "${tarball}" >"${status_file}" 2>"${error_file}"; then
  cat "${error_file}" >&2
  echo "source signature verification failed" >&2
  exit 1
fi

grep -q '^\[GNUPG:\] GOODSIG ' "${status_file}" || {
  echo "source signature has no good signature" >&2
  exit 1
}

fingerprint="$(awk '/^\[GNUPG:\] VALIDSIG / {print $3; exit}' "${status_file}")"
[[ -n "${fingerprint}" ]] || {
  echo "source signature has no valid fingerprint" >&2
  exit 1
}

found=0
for key in "${validpgpkeys[@]}"; do
  if [[ "${key,,}" == "${fingerprint,,}" ]]; then
    found=1
    break
  fi
done

if [[ "${found}" -ne 1 ]]; then
  echo "source signed by ${fingerprint}, which is not in validpgpkeys" >&2
  exit 1
fi

echo "verified source signature from ${fingerprint}"
