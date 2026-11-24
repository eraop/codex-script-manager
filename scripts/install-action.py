#!/usr/bin/env python3
import argparse
from copy import deepcopy
from importlib import import_module
import json
import os
from pathlib import Path
import re
import shlex
import stat
import sys
import tempfile


ACTION_NAME = "脚本管理"
COMMAND_PREFIX = ": codex-script-manager; "
DEFAULT_ENVIRONMENT = "environment.toml"


def get_toml():
    for module in ("tomllib", "tomli", "pip._vendor.tomli"):
        try:
            return import_module(module)
        except ImportError:
            continue
    raise ValueError("安装器需要 Python 3.11+ 或已安装 tomli 的 Python。")


def toml_string(value):
    return json.dumps(value, ensure_ascii=False).replace("\x7f", r"\u007f")


def action_command(app):
    return (
        COMMAND_PREFIX
        + f'/usr/bin/open -a {shlex.quote(str(app))} -- "${{CODEX_WORKTREE_PATH:-$PWD}}"'
    )


def choose_environment(project, requested):
    config_dir = project / ".codex" / "environments"
    if requested:
        if Path(requested).name != requested or not requested.endswith(".toml"):
            raise ValueError("--environment 只接受该项目下的 .toml 文件名。")
        return config_dir / requested

    primary = config_dir / DEFAULT_ENVIRONMENT
    if primary.exists() or primary.is_symlink():
        return primary
    existing = sorted(path for path in config_dir.glob("*.toml") if path.is_file())
    if len(existing) > 1:
        names = "、".join(path.name for path in existing)
        raise ValueError(f"项目有多个本地环境。请用 --environment 指定一个文件。现有文件为 {names}。")
    return existing[0] if existing else primary


def parsed(toml, source):
    try:
        return toml.loads(source)
    except toml.TOMLDecodeError as error:
        raise ValueError(f"本地环境 TOML 无法解析（{error}）") from error


def build_configuration(toml, source, project_name, action):
    document = parsed(toml, source)
    setup = document.get("setup")
    if (
        not isinstance(document.get("name"), str)
        or not isinstance(setup, dict)
        or not isinstance(setup.get("script"), str)
    ):
        if source.strip():
            raise ValueError("现有配置缺少环境名称或 [setup] 下的 script。")
        source = f'version = 1\nname = {toml_string(project_name)}\n\n[setup]\nscript = ""\n'
        document = parsed(toml, source)

    actions = document.get("actions", [])
    if not isinstance(actions, list) or any(not isinstance(item, dict) for item in actions):
        raise ValueError("现有 actions 结构无法作为 Codex Action 列表读取。")
    matches = [item for item in actions if item.get("name") == ACTION_NAME]
    if len(matches) == 1 and matches[0] == action:
        return source
    if len(matches) > 1 or (matches and not str(matches[0].get("command", "")).startswith(COMMAND_PREFIX)):
        raise ValueError(f"已有同名 Action「{ACTION_NAME}」，请先在 Codex 的本地环境中重命名。")

    expected = deepcopy(document)
    if not matches:
        expected.setdefault("actions", []).append(action)
        newline = "\r\n" if "\r\n" in source else "\n"
        fields = [f"{key} = {toml_string(value)}" for key, value in action.items()]
        separator = newline if source.endswith("\n") else newline * 2
        candidate = source + separator + newline.join(["[[actions]]", *fields, ""])
        try:
            if toml.loads(candidate) == expected:
                return candidate
        except toml.TOMLDecodeError:
            pass
        raise ValueError("现有配置使用与 [[actions]] 不兼容的 Action 格式，请在 Codex 的本地环境中添加此 Action。")

    # Codex writes command values as a single TOML string. Reparse edits to preserve other fields.
    old_action = matches[0]
    expected["actions"][actions.index(old_action)]["command"] = action["command"]
    for match in re.finditer(r"(?m)^([ \t]*command[ \t]*=[ \t]*)([^\r\n]*)", source):
        try:
            if toml.loads("command = " + match[2]).get("command") != old_action["command"]:
                continue
        except toml.TOMLDecodeError:
            continue
        candidate = source[: match.start(2)] + toml_string(action["command"]) + source[match.end(2) :]
        try:
            if toml.loads(candidate) == expected:
                return candidate
        except toml.TOMLDecodeError:
            continue
    raise ValueError("无法定位旧 Action 的命令，请在 Codex 的本地环境中更新其命令。")


def write_configuration(path, original, updated):
    path.parent.mkdir(parents=True, exist_ok=True)
    mode = stat.S_IMODE(path.stat().st_mode) if original is not None else 0o644
    temp_path = None
    try:
        with tempfile.NamedTemporaryFile(dir=path.parent, prefix=".environment-", delete=False) as file:
            temp_path = Path(file.name)
            os.fchmod(file.fileno(), mode)
            file.write(updated.encode("utf-8"))

        if original is None:
            os.link(temp_path, path)
        else:
            if path.is_symlink() or path.read_bytes() != original:
                raise ValueError("配置刚刚被修改，请重新运行安装器。")
            os.replace(temp_path, path)
    finally:
        if temp_path is not None:
            temp_path.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description="为一个 Codex 项目的 macOS 本地环境安装「脚本管理」Action。")
    parser.add_argument("project", type=Path, help="Codex 项目根目录")
    parser.add_argument("--app", type=Path, help="Codex Script Manager.app 的路径")
    parser.add_argument("--environment", help="本地环境文件名，例如 environment.toml")
    parser.add_argument("--dry-run", action="store_true", help="显示配置路径及命令")
    args = parser.parse_args()
    try:
        project = args.project.expanduser().resolve(strict=True)
        if not project.is_dir():
            raise ValueError(f"项目路径必须是文件夹。当前路径为 {project}")

        app = (args.app or (Path(__file__).resolve().parents[1] / "build" / "Codex Script Manager.app")).expanduser()
        app = app.resolve()
        if app.suffix != ".app" or not (app / "Contents" / "Info.plist").is_file():
            raise ValueError(f"找不到已构建的应用，请先构建或通过 --app 指定应用路径。当前路径为 {app}")

        config = choose_environment(project, args.environment)
        if any(path.is_symlink() for path in (config, config.parent, config.parent.parent)):
            raise ValueError("本地环境的路径含有符号链接。请通过 Codex 的本地环境设置添加 Action。")
        action = {"name": ACTION_NAME, "icon": "tool", "command": action_command(app), "platform": "darwin"}
        original = config.read_bytes() if config.exists() else None
        source = original.decode("utf-8") if original is not None else ""
        updated = build_configuration(get_toml(), source, project.name, action)
        if args.dry_run:
            print(f"配置路径 {config}\nAction 命令 {action['command']}")
        elif updated == source:
            print(f"「{ACTION_NAME}」已安装到 {config}")
        else:
            write_configuration(config, original, updated)
            print(f"已安装「{ACTION_NAME}」到 {config}")
        return 0
    except (OSError, ValueError) as error:
        print(f"安装失败。{error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
