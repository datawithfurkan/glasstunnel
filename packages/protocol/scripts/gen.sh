#!/usr/bin/env bash
# Regenerate Swift, TypeScript, and Go bindings from schema/glasstunnel.proto.
#
# Fallback behavior: if protoc or the required plugins are not installed,
# this script emits hand-written shim files for TS and Go so the rest of
# the repo still builds in CI and on fresh clones. Swift uses hand-written
# structs by default (matching the proto schema) because SwiftProtobuf
# requires an Xcode toolchain step that is easier to run manually. Generated
# Swift files are emitted under packages/protocol/gen for inspection and are
# not compiled into the Mac app.
#
# Install plugins:
#   Go:     go install google.golang.org/protobuf/cmd/protoc-gen-go@v1.35.2
#   TS:     pnpm add -D ts-proto
#   Swift:  brew install swift-protobuf
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROTOCOL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$PROTOCOL_DIR/../.." && pwd)"
PROTOCOL_NODE_BIN="$PROTOCOL_DIR/node_modules/.bin"

if [ -d "$PROTOCOL_NODE_BIN" ]; then
  export PATH="$PROTOCOL_NODE_BIN:$PATH"
fi

SCHEMA="$PROTOCOL_DIR/schema/glasstunnel.proto"

TS_OUT="$PROTOCOL_DIR/gen/ts"
GO_OUT="$REPO_ROOT/apps/signaling/internal/proto"
SWIFT_OUT="$PROTOCOL_DIR/gen/swift"

mkdir -p "$TS_OUT" "$GO_OUT" "$SWIFT_OUT"

if ! command -v protoc >/dev/null 2>&1; then
  echo "protoc not found; skipping generation. Install with 'brew install protobuf'." >&2
  echo "Hand-written shims in packages/protocol/src/ and apps/*/internal/proto will be used." >&2
  exit 0
fi

echo "Generating TypeScript protobuf bindings -> $TS_OUT"
if command -v protoc-gen-ts_proto >/dev/null 2>&1; then
  protoc \
    --plugin=protoc-gen-ts_proto="$(command -v protoc-gen-ts_proto)" \
    --ts_proto_out="$TS_OUT" \
    --ts_proto_opt=esModuleInterop=true,useExactTypes=false,outputIndex=true \
    -I "$PROTOCOL_DIR/schema" \
    "$SCHEMA"
else
  echo "  protoc-gen-ts_proto missing; run 'pnpm add -D ts-proto' in packages/protocol"
fi

echo "Generating Go protobuf bindings -> $GO_OUT"
if command -v protoc-gen-go >/dev/null 2>&1; then
  protoc \
    --go_out="$GO_OUT" \
    --go_opt=paths=source_relative \
    -I "$PROTOCOL_DIR/schema" \
    "$SCHEMA"
else
  echo "  protoc-gen-go missing; run 'go install google.golang.org/protobuf/cmd/protoc-gen-go@latest'"
fi

echo "Generating Swift protobuf bindings -> $SWIFT_OUT"
if command -v protoc-gen-swift >/dev/null 2>&1; then
  protoc \
    --swift_out="$SWIFT_OUT" \
    --swift_opt=Visibility=Public \
    -I "$PROTOCOL_DIR/schema" \
    "$SCHEMA"
else
  echo "  protoc-gen-swift missing; run 'brew install swift-protobuf'"
fi

echo "Done."
