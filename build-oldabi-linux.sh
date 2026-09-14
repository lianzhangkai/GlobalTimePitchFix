#!/usr/bin/env bash
set -euo pipefail
if [[ -z "${THEOS:-}" ]]; then
  echo "ERROR: THEOS environment variable is not set."
  exit 1
fi
if [[ ! -f vendor/sonic/sonic.c || ! -f vendor/sonic/sonic.h ]]; then
  echo "ERROR: Sonic source missing. Run the workflow fetch step."
  exit 1
fi
make clean package FINALPACKAGE=1
