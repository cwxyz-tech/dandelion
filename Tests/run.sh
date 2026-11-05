#!/bin/sh
# Builds and runs the scanner check (needs a Mac). Used by CI; run it yourself with:  sh Tests/run.sh
set -e
cd "$(dirname "$0")/.."
mkdir -p build
xcrun swiftc -parse-as-library -O -swift-version 5 \
  Sources/Model.swift Sources/Scanner.swift Tests/ScanCheck.swift -o build/scancheck
./build/scancheck
