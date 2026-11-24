#!/bin/bash
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "$0")/.." && pwd -P)"
source_dir="$repo_dir/apps/macos"
app_name='Codex Script Manager.app'
output_dir="$repo_dir/build"
app="$output_dir/$app_name"
executable='CodexScriptManager'
plist="$source_dir/Resources/Info.plist"

if [[ "$(uname -s)" != Darwin ]] || ! swiftc="$(/usr/bin/xcrun --find swiftc 2>/dev/null)"; then
    printf '%s\n' '请在 macOS 上安装 Xcode 或 Command Line Tools 后重新构建。' >&2
    exit 1
fi

shopt -s nullglob
sources=("$source_dir"/Sources/*.swift)
if [[ ${#sources[@]} -eq 0 ]]; then
    printf '未找到 Swift 源文件：%s/Sources\n' "$source_dir" >&2
    exit 1
fi

sdk="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
mkdir -p "$output_dir"
staging="$(mktemp -d "$output_dir/.staging.XXXXXX")"
bundle="$staging/$app_name"
previous="$staging/previous.app"

cleanup() {
    if [[ -d "$previous" && ! -e "$app" ]] && ! mv "$previous" "$app"; then
        printf '上一版本保存在：%s\n' "$previous" >&2
        return
    fi
    rm -rf -- "$staging"
}
trap cleanup EXIT

mkdir -p "$bundle/Contents/MacOS"
cp "$plist" "$bundle/Contents/Info.plist"
/usr/bin/plutil -lint -s "$bundle/Contents/Info.plist"

"$swiftc" -swift-version 5 -O \
    -target "$(uname -m)-apple-macosx13.0" \
    -sdk "$sdk" \
    -module-cache-path "$staging/ModuleCache" \
    "${sources[@]}" \
    -o "$bundle/Contents/MacOS/$executable"

/usr/bin/codesign --force --sign - "$bundle"
/usr/bin/codesign --verify --strict "$bundle"

if [[ -e "$app" || -L "$app" ]]; then
    bundle_id="$(/usr/bin/plutil -extract CFBundleIdentifier raw "$plist")"
    if [[ -L "$app" ]] || ! previous_id="$(/usr/bin/plutil -extract CFBundleIdentifier raw "$app/Contents/Info.plist" 2>/dev/null)" || [[ "$previous_id" != "$bundle_id" ]]; then
        printf '构建路径已被其他文件占用：%s\n' "$app" >&2
        exit 1
    fi
    mv "$app" "$previous"
fi

mv "$bundle" "$app"
printf '已构建 %s\n' "$app"
