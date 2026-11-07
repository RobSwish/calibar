#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate
calendar_derived="${TMPDIR:-/private/tmp}/CaliBarDerivedData"
# GOOGLE_CLIENT_ID in the environment overrides project.yml for local testing.
calendar_google=()
[[ -n "${GOOGLE_CLIENT_ID:-}" ]] && calendar_google=("GOOGLE_CLIENT_ID=$GOOGLE_CLIENT_ID")
xcodebuild -project CaliBar.xcodeproj -scheme CaliBar -configuration Debug \
  -derivedDataPath "$calendar_derived" CODE_SIGN_IDENTITY=- "${calendar_google[@]}" build
mkdir -p build
calendar_app="$calendar_derived/Build/Products/Debug/CaliBar.app"
codesign --verify --deep --strict "$calendar_app"
ditto --norsrc --noextattr "$calendar_app" build/CaliBar.app
print 'Built build/CaliBar.app (development signing).'
