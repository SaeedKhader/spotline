#!/bin/zsh
# Builds and runs spotline-bench. When an Apple Development certificate is present,
# signs it first so the Keychain keeps "Always Allow" for the API keys across rebuilds.
# Usage: scripts/bench.sh <samples folder> [options]
set -euo pipefail
package="$(dirname "$0")/../Packages/SpotlineKit"

swift build --package-path "$package" -c release --product spotline-bench >&2
binary="$(swift build --package-path "$package" -c release --show-bin-path)/spotline-bench"

identity=$(security find-identity -v -p codesigning | grep -m1 -o '"Apple Development: [^"]*"' | tr -d '"' || true)
if [[ -n "$identity" ]]; then
  codesign --force --sign "$identity" --identifier io.github.saeedkhader.spotline-bench "$binary"
fi
exec "$binary" "$@"
