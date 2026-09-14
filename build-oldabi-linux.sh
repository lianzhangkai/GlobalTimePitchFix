#!/usr/bin/env bash
set -euo pipefail
make clean package FINALPACKAGE=1 messages=yes
