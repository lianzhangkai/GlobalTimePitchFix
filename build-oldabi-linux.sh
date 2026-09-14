#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${THEOS:-}" ]]; then
  echo "ERROR: THEOS environment variable is not set."
  exit 1
fi

CLANG_VER="$(${THEOS}/toolchain/linux/iphone/bin/clang --version 2>/dev/null | head -n1 || true)"
echo "Toolchain: ${CLANG_VER:-not found}"

if [[ ! -d "${THEOS}/sdks/iPhoneOS13.7.sdk" ]]; then
  echo "ERROR: ${THEOS}/sdks/iPhoneOS13.7.sdk is missing."
  exit 1
fi

make clean package FINALPACKAGE=1
