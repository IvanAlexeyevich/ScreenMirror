#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcodebuild -project ScreenMirror.xcodeproj -scheme ScreenMirror -sdk iphonesimulator -configuration Debug CODE_SIGNING_ALLOWED=NO build
python3 tools/run_tests.py
bash tools/test_mux.sh
