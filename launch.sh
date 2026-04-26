#!/bin/bash
# macOS menu bar apps need the Python.app framework binary, not the CLI python3
PYTHON_APP="/Library/Frameworks/Python.framework/Versions/3.11/Resources/Python.app/Contents/MacOS/Python"
APP_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ ! -f "$PYTHON_APP" ]; then
  echo "Python.app not found. Find yours with:"
  echo "  find /Library/Frameworks -name Python -type f 2>/dev/null"
  exit 1
fi

cd "$APP_DIR"
exec "$PYTHON_APP" "$APP_DIR/app.py"
