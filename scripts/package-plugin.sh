#!/bin/bash
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "$0")/.." && pwd -P)"
plugin_name=script-manager
plugin_source="$repo_dir/plugins/$plugin_name"
output_dir="$repo_dir/build"
marketplace="$output_dir/codex-marketplace"
app_name='Codex Script Manager.app'

"$repo_dir/scripts/build.sh"

staging="$(mktemp -d "$output_dir/.codex-marketplace.XXXXXX")"
staged_marketplace="$staging/marketplace"
staged_plugin="$staged_marketplace/plugins/$plugin_name"
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
cp "$plugin_source/plugin.json" "$plugin_source/mcp.json" "$plugin_source/server.py" "$plugin_source/repair.py" "$staged_plugin/"
cp -R "$plugin_source/app" "$plugin_source/assets" "$plugin_source/skills" "$staged_plugin/"
/usr/bin/ditto "$output_dir/$app_name" "$staged_plugin/assets/$app_name"
/usr/bin/codesign --verify --strict "$staged_plugin/assets/$app_name"

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
