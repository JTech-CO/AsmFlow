#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

make check
make package

archive="dist/AsmFlow-$(tr -d '\r\n' < VERSION).zip"
unzip -t "$archive" >/dev/null
sha256sum "$archive"
