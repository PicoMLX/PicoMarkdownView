#!/usr/bin/env bash
# Regenerates Sources/PicoMarkdownView/Resources/pele-bundle.js from a pinned
# release of Pele (https://pele.run), the Mermaid-compatible diagram renderer
# that PeleRenderer runs in JavaScriptCore. The published browser build
# (`dist/pele.global.js`, an IIFE that defines a global `pele`) is used as is;
# Scripts/pele-wrapper.js is appended to expose `renderDiagram` and to
# resolve Pele's CSS variables into literal values. Requires: curl, tar,
# shasum, node (smoke test only).
#
# Usage: Scripts/bundle-pele.sh
set -euo pipefail

PELE_VERSION="1.9.1"
PELE_SHA256="fc7e0ee2d0c6118d7dd2622e47fa90206723ca40dcd8e0d29127118736e48d15"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
OUTPUT="$REPO_ROOT/Sources/PicoMarkdownView/Resources/pele-bundle.js"
WRAPPER="$SCRIPT_DIR/pele-wrapper.js"

for tool in curl tar shasum node; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "error: $tool is required" >&2
    exit 1
  }
done

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

echo "Fetching pele@$PELE_VERSION ..."
curl -fsSL -o "$WORK_DIR/pele.tgz" \
  "https://registry.npmjs.org/pele/-/pele-$PELE_VERSION.tgz"
echo "$PELE_SHA256  $WORK_DIR/pele.tgz" | shasum -a 256 -c - >/dev/null
tar -xzf "$WORK_DIR/pele.tgz" -C "$WORK_DIR"

BUNDLE="$WORK_DIR/package/dist/pele.global.js"
[ -f "$BUNDLE" ] || { echo "error: $BUNDLE missing from the package" >&2; exit 1; }

{
  cat "$BUNDLE"
  echo
  cat "$WRAPPER"
} > "$WORK_DIR/pele-bundle.js"

echo "Smoke-testing the bundle ..."
node - "$WORK_DIR/pele-bundle.js" <<'EOF'
const fs = require('fs');
const vm = require('vm');
const source = fs.readFileSync(process.argv[2], 'utf8');
const sandbox = {};
vm.createContext(sandbox);
vm.runInContext(source, sandbox);
const ok = sandbox.renderDiagram('flowchart LR\n  A --> B', { theme: { fg: '#123456' } });
if (!ok.ok || !ok.svg.startsWith('<svg') || ok.svg.includes('var(') || !ok.svg.includes('fill="#123456"')) {
  console.error('smoke test failed:', JSON.stringify(ok).slice(0, 300));
  process.exit(1);
}
const bad = sandbox.renderDiagram('not a diagram', {});
if (bad.ok || bad.code !== 'unsupported-diagram') {
  console.error('error path failed:', JSON.stringify(bad));
  process.exit(1);
}
console.log(`ok: ${ok.type} ${ok.width}x${ok.height}, ${(source.length / 1024).toFixed(0)} KB`);
EOF

cp "$WORK_DIR/pele-bundle.js" "$OUTPUT"
echo "Wrote $OUTPUT"
