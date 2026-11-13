#!/usr/bin/env bash
set -euo pipefail

pkgbuild="${1:?usage: upstream-version.sh /path/to/PKGBUILD}"
[[ -f "${pkgbuild}" ]] || { echo "missing PKGBUILD: ${pkgbuild}" >&2; exit 1; }

export XDG_DATA_HOME="${XDG_DATA_HOME:-${HOME:-/root}/.local/share}"
set +u
# shellcheck disable=SC1090
source "${pkgbuild}" >/dev/null 2>&1
set -u

: "${pkgver:?PKGBUILD did not set pkgver}"
: "${pkgrel:?PKGBUILD did not set pkgrel}"
: "${_srcname:?PKGBUILD did not set _srcname}"

version="${pkgver}-${pkgrel}"
printf 'pkgver=%s\n' "${pkgver}"
printf 'pkgrel=%s\n' "${pkgrel}"
printf 'version=%s\n' "${version}"
printf 'srcname=%s\n' "${_srcname}"
printf 'source_url=https://github.com/CachyOS/linux/releases/download/%s/%s.tar.gz\n' "${_srcname}" "${_srcname}"
