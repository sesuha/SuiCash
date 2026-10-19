#!/usr/bin/env bash
# Starts anvil, deploys the contracts, seeds demo data, writes the app's dev
# environment and starts Vite. The logic lives in scripts/dev.ts so it works
# the same on Windows (`pnpm dev`), macOS and Linux.
set -euo pipefail
cd "$(dirname "$0")/.."
exec pnpm dev "$@"
