#!/bin/zsh
# Build, notarize and prepare signed update assets. Publishing is a separate step.
set -euo pipefail
cd "$(dirname "$0")/.."
release_root="$PWD"
release_version="${1:?Usage: scripts/release.sh VERSION BUILD_NUMBER}"
release_build="${2:?Supply an increasing integer build number}"
[[ "$release_version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { print -u2 'Use a version such as 1.0.0'; exit 1; }
[[ "$release_build" =~ '^[1-9][0-9]*$' ]] || { print -u2 'Build number must be a positive integer'; exit 1; }
release_team="${DEVELOPMENT_TEAM:-94XP85L8JK}"
release_identity="${SIGNING_IDENTITY:-Developer ID Application: SWIFTLAB LTD (94XP85L8JK)}"
release_notary="${NOTARY_PROFILE:-nimble-notary}"
release_account="${SPARKLE_ACCOUNT:-veycal}"
release_repo="${RELEASE_REPO:-RobSwish/calibar}"
release_work="$(mktemp -d "${TMPDIR:-/private/tmp}/calibar-release.XXXXXX")"
release_source="$release_work/source"
print "Release workspace: $release_work"
# Materialize source outside cloud-synced folders before signing the app.
python3 - "$release_root" "$release_source" <<'COPY'
from pathlib import Path
import shutil,sys
src,dst=map(Path,sys.argv[1:]);dst.mkdir()
for name in ('Sources','Resources'):
    shutil.copytree(src/name,dst/name,copy_function=shutil.copyfile)
for name in ('project.yml',):
    shutil.copyfile(src/name,dst/name)
COPY
cd "$release_source"
xcodegen generate
xcodebuild -project CaliBar.xcodeproj -scheme CaliBar -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$release_work/CaliBar.xcarchive" \
  -derivedDataPath "$release_work/DerivedData" CODE_SIGN_IDENTITY="$release_identity" \
  DEVELOPMENT_TEAM="$release_team" MARKETING_VERSION="$release_version" \
  CURRENT_PROJECT_VERSION="$release_build" 'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO archive
python3 - "$release_work/ExportOptions.plist" "$release_team" <<'PLIST'
import plistlib,sys
plistlib.dump(dict(method='developer-id',teamID=sys.argv[2],signingStyle='manual',
                  signingCertificate='Developer ID Application'),open(sys.argv[1],'wb'))
PLIST
xcodebuild -exportArchive -archivePath "$release_work/CaliBar.xcarchive" \
  -exportOptionsPlist "$release_work/ExportOptions.plist" -exportPath "$release_work/export"
release_app="$release_work/export/CaliBar.app"
codesign --verify --deep --strict "$release_app"
python3 - "$release_app/Contents/MacOS/CaliBar" <<'ARCHS'
import subprocess,sys
arches=set(subprocess.check_output(['lipo','-archs',sys.argv[1]],text=True).split())
if not {'arm64','x86_64'} <= arches:
    raise SystemExit('Release must support both Apple silicon and Intel: '+str(arches))
ARCHS
ditto -c -k --keepParent --norsrc --noextattr "$release_app" "$release_work/notarization.zip"
xcrun notarytool submit "$release_work/notarization.zip" --keychain-profile "$release_notary" \
  --wait --output-format json > "$release_work/notarization.json"
python3 - "$release_work/notarization.json" <<'NOTARY'
import json,sys
result=json.load(open(sys.argv[1]))
if result.get('status') != 'Accepted':
    raise SystemExit('Notarization failed: '+str(result))
NOTARY
xcrun stapler staple "$release_app"
xcrun stapler validate "$release_app"
spctl --assess --type execute --verbose=2 "$release_app"
release_assets="$release_work/assets"
mkdir -p "$release_assets"
ditto -c -k --keepParent --norsrc --noextattr "$release_app" "$release_assets/CaliBar.zip"
# Use the tools from the same official Sparkle version pinned in project.yml.
release_sparkle="${SPARKLE_TOOLS_DIR:-$release_work/sparkle/bin}"
if [[ ! -x "$release_sparkle/generate_appcast" ]]; then
  curl --fail --location --retry 3 'https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-2.10.0.tar.xz' -o "$release_work/Sparkle.tar.xz"
  mkdir -p "$release_work/sparkle"
  tar -xf "$release_work/Sparkle.tar.xz" -C "$release_work/sparkle"
fi
"$release_sparkle/generate_appcast" --account "$release_account" \
  --download-url-prefix "https://github.com/$release_repo/releases/download/v$release_version/" \
  --link "https://github.com/$release_repo/releases" "$release_assets"
"$release_sparkle/sign_update" --account "$release_account" "$release_assets/appcast.xml"
"$release_sparkle/sign_update" --account "$release_account" --verify "$release_assets/appcast.xml"
cd "$release_assets"
shasum -a 256 CaliBar.zip > SHA256SUMS
release_output="$release_root/build/releases/$release_version"
[[ ! -e "$release_output" ]] || { print -u2 "Output already exists: $release_output. Prepared assets remain at $release_assets"; exit 1; }
mkdir -p "$release_output"
cp CaliBar.zip appcast.xml SHA256SUMS "$release_output/"
print "Signed, notarized release prepared at $release_output"
print 'Commit the version change, tag it, then publish these three assets with gh release create.'
