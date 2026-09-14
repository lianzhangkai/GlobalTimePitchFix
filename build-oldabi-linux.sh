#!/bin/bash
set -euo pipefail
export THEOS="${THEOS:-$HOME/theos}"
make clean package FINALPACKAGE=1 messages=yes
