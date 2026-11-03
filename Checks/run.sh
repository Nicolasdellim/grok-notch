#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/checks
swiftc -parse-as-library Sources/GrokNotch/ChatStore.swift Checks/ModelChecks.swift -o .build/checks/model-checks
.build/checks/model-checks
