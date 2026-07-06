#!/usr/bin/env bash
# Regenerates Sources/PicoMarkdownView/Resources/prism-bundle.js from a
# pinned prismjs release. The language list lives in Scripts/bundle-prism.js;
# dependency resolution, concatenation, and a load/tokenize smoke test happen
# there. Requires: curl, tar, node.
#
# Usage: Scripts/bundle-prism.sh
set -euo pipefail

PRISM_VERSION="1.29.0"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
OUTPUT="$REPO_ROOT/Sources/PicoMarkdownView/Resources/prism-bundle.js"

command -v node >/dev/null 2>&1 || {
  echo "error: node is required (it resolves component dependencies and smoke-tests the bundle)" >&2
  exit 1
}

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

echo "Fetching prismjs@$PRISM_VERSION ..."
curl -fsSL -o "$WORK_DIR/prismjs.tgz" \
  "https://registry.npmjs.org/prismjs/-/prismjs-$PRISM_VERSION.tgz"
tar -xzf "$WORK_DIR/prismjs.tgz" -C "$WORK_DIR"

node "$SCRIPT_DIR/bundle-prism.js" \
  "$WORK_DIR/package" \
  "$SCRIPT_DIR/prism-wrapper.js" \
  "$OUTPUT"

echo "Wrote $OUTPUT"
