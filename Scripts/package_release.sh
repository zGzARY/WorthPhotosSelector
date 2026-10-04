#!/bin/zsh
# Build a distributable Release without installing or replacing a running app.
set -euo pipefail
cd "${0:A:h:h}"
repo_root="$PWD"
work="$(mktemp -d /private/tmp/WorthPhotos-Release.XXXXXX)"
source_dir="$work/Source"
mkdir -p "$source_dir/Scripts"
for input in Sources Configuration Assets; do
  ditto --norsrc "$repo_root/$input" "$source_dir/$input"
done
ditto --norsrc "$repo_root/Scripts/generate_project.py" "$source_dir/Scripts/generate_project.py"
python3 "$source_dir/Scripts/generate_project.py"
xcodebuild -project "$source_dir/PhotosDuplicateClean.xcodeproj" -scheme TravelSelect \
  -configuration Release -derivedDataPath "$work/DerivedData" \
  CLANG_MODULE_CACHE_PATH="$work/ModuleCache.noindex" build
app="$work/DerivedData/Build/Products/Release/WorthPhotos.app"
codesign --verify --deep --strict "$app"
version=$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")
output="${WORTHPHOTOS_RELEASE_PATH:-$repo_root/build/Release}"
staging="$work/Package"
mkdir -p "$output" "$staging"
ditto --norsrc "$app" "$staging/WorthPhotos.app"
cp "$repo_root/LICENSE" "$staging/LICENSE"
cat > "$staging/INSTALL.txt" <<'INSTALL'
WorthPhotos / 择影

Requires macOS 15 or later on Apple Silicon. The application interface is Chinese.
Drag WorthPhotos.app to Applications. Open it and select your photo source.
This build is ad-hoc signed and has not been notarized by Apple.
If macOS blocks it, follow Apple's guidance for an app you trust:
https://support.apple.com/102445
Do not disable system-wide security protections.

需要 Apple Silicon Mac，macOS 15 或更新版本。软件界面为中文。
将 WorthPhotos.app 拖入“应用程序”，打开后选择照片来源。
本版本采用 ad-hoc 签名，尚未经过 Apple 公证。
如 macOS 阻止打开，请按 Apple 官方说明为你信任的此应用操作：
https://support.apple.com/zh-cn/102445
无需关闭系统整体安全保护。

Documentation and corresponding source code / 文档与对应源码：
https://github.com/zGzARY/WorthPhotosSelector

License: GNU GPL v3; see the included LICENSE file.
INSTALL
archive="WorthPhotos-$version-macOS-arm64.zip"
ditto -c -k --norsrc "$staging" "$output/$archive"
(cd "$output" && shasum -a 256 "$archive" > SHA256SUMS.txt)
codesign --verify --deep --strict "$staging/WorthPhotos.app"
print "Release package: $output/$archive"
print "Checksum: $output/SHA256SUMS.txt"
print "Build directory: $work"
