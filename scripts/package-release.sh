#!/bin/bash
# Package a committed revision without touching an installed or running app.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
release_ref="${1:-HEAD}"
commit="$(git -C "$repo_root" rev-parse --verify "${release_ref}^{commit}")"

if [[ "$(uname -s)" != Darwin ]]; then
    echo "Release packaging requires macOS and full Xcode." >&2
    exit 1
fi
for command_name in xcodegen xcodebuild codesign ditto hdiutil shasum; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "Missing tool: $command_name" >&2
        exit 1
    fi
done

release_work="$(mktemp -d /tmp/wheelflip-release.XXXXXX)"
cleanup() {
    result=$?
    if [[ "$result" -eq 0 ]]; then
        rm -rf -- "$release_work"
    else
        echo "Packaging failed; diagnostic files remain at $release_work" >&2
    fi
}
trap cleanup EXIT

source_dir="$release_work/source"
payload_dir="$release_work/payload"
mkdir -p "$source_dir" "$payload_dir"
git -C "$repo_root" archive "$commit" | tar -x -C "$source_dir"

echo "Building committed revision $commit for Apple silicon and Intel…"
(
    cd "$source_dir"
    xcodegen generate --spec app/project.yml
    xcodebuild -project app/WheelFlip.xcodeproj -scheme WheelFlip \
        -configuration Release -destination 'generic/platform=macOS' \
        -derivedDataPath "$release_work/derived" \
        ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO build
) > "$release_work/build.log" 2>&1 || {
    tail -60 "$release_work/build.log" >&2
    exit 1
}

built_app="$release_work/derived/Build/Products/Release/WheelFlip.app"
package_app="$payload_dir/WheelFlip.app"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$built_app/Contents/Info.plist")"
minimum_macos="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$built_app/Contents/Info.plist")"
output_dir="${2:-$repo_root/app/dist/v$version}"
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
for asset in WheelFlip-universal.dmg WheelFlip-universal.zip SHA256SUMS.txt BUILD-INFO.txt; do
    if [[ -e "$output_dir/$asset" ]]; then
        echo "Refusing to overwrite $output_dir/$asset; choose a new output directory." >&2
        exit 1
    fi
done

ditto --noextattr --norsrc "$built_app" "$package_app"
cp "$source_dir/LICENSE" "$package_app/Contents/Resources/LICENSE.txt"
codesign --force --sign - \
    --entitlements "$source_dir/app/WheelFlip/WheelFlip.entitlements" \
    --identifier com.jonywu.WheelFlip "$package_app"
codesign --verify --deep --strict "$package_app"
architectures="$(xcrun lipo -archs "$package_app/Contents/MacOS/WheelFlip")"
for architecture in arm64 x86_64; do
    case " $architectures " in
        *" $architecture "*) ;;
        *) echo "Missing architecture: $architecture" >&2; exit 1 ;;
    esac
done

cp "$source_dir/docs/INSTALL.txt" "$payload_dir/Start Here - 安装说明.txt"
cp "$source_dir/LICENSE" "$payload_dir/LICENSE.txt"
ln -s /Applications "$payload_dir/Applications"

ditto -c -k --sequesterRsrc --keepParent "$package_app" "$output_dir/WheelFlip-universal.zip"
hdiutil create -quiet -volname WheelFlip -srcfolder "$payload_dir" \
    -fs HFS+ -format UDZO "$output_dir/WheelFlip-universal.dmg"
hdiutil verify "$output_dir/WheelFlip-universal.dmg"

cat > "$output_dir/BUILD-INFO.txt" <<EOF
Project: https://github.com/WoWJony/wheelflip
Version: $version
Source commit: $commit
Minimum macOS: $minimum_macos
Architectures: arm64 x86_64
Code signature: ad-hoc (not Developer ID)
Apple notarization: no
EOF
xcodebuild -version >> "$output_dir/BUILD-INFO.txt"
(
    cd "$output_dir"
    shasum -a 256 WheelFlip-universal.dmg WheelFlip-universal.zip BUILD-INFO.txt > SHA256SUMS.txt
)
echo "Packaged WheelFlip $version: $output_dir"
