#!/bin/bash
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "$0")/.." && pwd -P)"
source_dir="$repo_dir/apps/macos"
plugin_name=script-manager
plugin_source="$repo_dir/plugins/$plugin_name"
output_dir="$repo_dir/build"
marketplace="$output_dir/codex-marketplace"
app_name='Codex Script Manager.app'
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
staging="$(mktemp -d "$output_dir/.codex-marketplace.XXXXXX")"
staged_marketplace="$staging/marketplace"
staged_plugin="$staged_marketplace/plugins/$plugin_name"
bundle="$staged_plugin/assets/$app_name"
previous="$staging/previous"

cleanup() {
    if [[ -d "$previous" && ! -e "$marketplace" ]] && ! mv "$previous" "$marketplace"; then
        printf '上一版插件市场保存在 %s\n' "$previous" >&2
        return
    fi
    rm -rf -- "$staging"
}
trap cleanup EXIT

mkdir -p "$staged_marketplace/.agents/plugins" "$staged_plugin"
cp "$repo_dir/plugins/marketplace.json" "$staged_marketplace/.agents/plugins/marketplace.json"
cp "$plugin_source/plugin.json" "$plugin_source/mcp.json" "$plugin_source"/*.py "$staged_plugin/"
cp -R "$plugin_source/app" "$plugin_source/assets" "$plugin_source/skills" "$plugin_source/_vendor" "$staged_plugin/"

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

if [[ -e "$marketplace" || -L "$marketplace" ]]; then
    previous_manifest="$marketplace/.agents/plugins/marketplace.json"
    if [[ -L "$marketplace" || ! -f "$previous_manifest" ]]; then
        printf '插件市场路径已被占用 %s\n' "$marketplace" >&2
        exit 1
    fi
    mv "$marketplace" "$previous"
fi

mv "$staged_marketplace" "$marketplace"
printf '已打包本地插件市场 %s\n' "$marketplace"
