#!/bin/bash
set -euo pipefail

if [[ ${OSTYPE:-} != darwin* ]]; then
    printf '%s\n' 'Script Manager requires macOS.' >&2
    exit 1
fi

if [[ $# -ne 1 || $1 != /* || ! -d $1 ]]; then
    printf '%s\n' 'Pass the absolute path to an existing project folder.' >&2
    exit 2
fi

script_dir="$(/usr/bin/dirname -- "${BASH_SOURCE[0]}")"
plugin_root="$(CDPATH='' cd -- "$script_dir/../../.." && pwd -P)"
app="$plugin_root/assets/Codex Script Manager.app"

if [[ ! -x "$app/Contents/MacOS/CodexScriptManager" ]]; then
    printf 'The plugin is missing the Script Manager app at %s\n' "$app" >&2
    exit 1
fi

exec /usr/bin/open -a "$app" -- "$1"
