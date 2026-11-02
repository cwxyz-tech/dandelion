#!/bin/sh
# Builds and runs every engine check (needs a Mac). Used by CI; run it yourself with:  sh Tests/run.sh
set -e
cd "$(dirname "$0")/.."
mkdir -p build
xcrun swiftc -parse-as-library -O -swift-version 5 \
  Sources/Model.swift Sources/Scanner.swift Sources/Safety.swift Sources/Duplicates.swift Sources/Rules.swift \
  Sources/TimeLog.swift Sources/RecorderMath.swift Sources/RecorderExport.swift Sources/Markup.swift \
  Tests/ScanCheck.swift Tests/SuiteCheck.swift Tests/ToolsCheck.swift Tests/MediaCheck.swift -o build/checks
./build/checks
