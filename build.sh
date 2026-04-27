#!/bin/bash
set -e
cd "$(dirname "$0")"

APP="ClaudeUsage.app"
BINARY="$APP/Contents/MacOS/ClaudeUsage"

echo "→ Compiling…"
swiftc main.swift MenuBar.swift Settings.swift \
  -framework AppKit -framework Foundation -framework Security -framework SwiftUI \
  -target arm64-apple-macosx13.0 \
  -O \
  -o menubar

echo "→ Copying binary into bundle…"
cp menubar "$BINARY"
chmod +x "$BINARY"

echo "→ Signing (ad-hoc)…"
codesign --sign - --force --deep "$APP"

echo "→ Verifying…"
codesign --verify "$APP" && echo "   signature OK"

echo ""
echo "✓ Built: $APP  ($(du -sh "$APP" | cut -f1))"
echo ""
echo "To run:       open $APP"
echo "To distribute: zip -r ClaudeUsage.zip $APP"
