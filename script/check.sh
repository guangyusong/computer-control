#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

swift build
swift test

node --check script/browser-agent.mjs
node --check script/chrome-live-agent.mjs
node script/chrome-live-agent.mjs --self-test >/dev/null

git diff --check
