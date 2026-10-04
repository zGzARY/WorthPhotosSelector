#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
python3 Scripts/generate_project.py
# Build a local input snapshot: iCloud file coordination can stall Xcode even
# after files are downloaded, and FinderInfo can invalidate ad-hoc signing.
derived="/private/tmp/TravelSelect-Xcode-$UID"
build_source="$derived/Source"
mkdir -p "$build_source"
for input in Sources Configuration Assets PhotosDuplicateClean.xcodeproj; do
  ditto --norsrc "$input" "$build_source/$input"
done
xcodebuild -project "$build_source/PhotosDuplicateClean.xcodeproj" -scheme TravelSelect -configuration Debug -derivedDataPath "$derived" CLANG_MODULE_CACHE_PATH="$derived/ModuleCache.noindex" build
mkdir -p build
codesign --verify --deep --strict "$derived/Build/Products/Debug/WorthPhotos.app"
ditto -c -k --norsrc --keepParent "$derived/Build/Products/Debug/WorthPhotos.app" build/WorthPhotos-Debug.zip
delivery="${WORTHPHOTOS_DELIVERY_PATH:-${TRAVELSELECT_DELIVERY_PATH:-$HOME/Applications/WorthPhotos.app}}"
if [[ -e "$delivery" ]]; then
  existing_id=$(/usr/bin/plutil -extract CFBundleIdentifier raw "$delivery/Contents/Info.plist")
  [[ "$existing_id" == "app.local.TravelSelect" ]] || { print -u2 "目标已有不同的 App，拒绝覆盖：$delivery"; exit 1; }
fi
mkdir -p "${delivery:h}"
ditto --norsrc "$derived/Build/Products/Debug/WorthPhotos.app" "$delivery"
xattr -cr "$delivery"
codesign --verify --deep --strict "$delivery"
print "已构建并验证：$delivery"
