#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate
calendar_derived="${TMPDIR:-/private/tmp}/CaliBarDerivedData"
xcodebuild -project CaliBar.xcodeproj -scheme CaliBar -configuration Debug \
  -derivedDataPath "$calendar_derived" CODE_SIGN_IDENTITY=- build
mkdir -p build
calendar_app="$calendar_derived/Build/Products/Debug/CaliBar.app"
codesign --verify --deep --strict "$calendar_app"
ditto --norsrc --noextattr "$calendar_app" build/CaliBar.app
print 'Built build/CaliBar.app (development signing).'
