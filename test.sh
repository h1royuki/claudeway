#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
swift run --package-path "$ROOT" --scratch-path "${BUILD_DIR:-$ROOT/.build}" SwitcherTests
