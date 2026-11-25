from __future__ import annotations

import base64
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys
from tempfile import NamedTemporaryFile
from xml.etree import ElementTree

from portable_discovery import (
    CONFIG_LIMIT,
    CONFIG_PATH,
    configured_commands,
    configured_directory,
    control_characters,
    project_directories,
    relative_directory,
)

try:
    import tomllib
except ModuleNotFoundError:
    from _vendor import tomli as tomllib


ENVIRONMENT_PATH = ".codex/environments/environment.toml"
COMPOSE_FILES = ("compose.yaml", "compose.yml", "docker-compose.yaml", "docker-compose.yml")
PROJECT_FILES = {".csproj", ".fsproj", ".vbproj"}
GO_MAIN = re.compile(r"(?m)^\s*package\s+main\b[\s\S]*^\s*func\s+main\s*\(")
PORTABLE_NAME = re.compile(r"[a-zA-Z0-9_][a-zA-Z0-9_.-]*\Z")
COMMAND_NAME_LIMIT = 256


class CommandError(Exception):
    def __init__(self, english: str, chinese: str):
        super().__init__(english)
        self.english = english
        self.chinese = chinese

    def row(self) -> dict:
        return {"english": self.english, "chinese": self.chinese}


@dataclass(frozen=True)
class Candidate:
    name: str
    command: str
    cwd: str
    detail: str
    windows_command: str | None = None

    @property
    def id(self) -> str:
        directory = base64.urlsafe_b64encode(self.cwd.encode()).decode()
        digest = hashlib.sha256(json.dumps(self.entry, sort_keys=True).encode()).hexdigest()[:24]
        return f"{directory}.{digest}"

    @property
    def entry(self) -> dict:
        entry = {"name": self.name, "command": self.command}
        if self.cwd:
            entry["cwd"] = self.cwd
        if self.windows_command:
            entry["platforms"] = {"windows": {"command": self.windows_command}}
        return entry

    def row(self) -> dict:
        return {
            "id": self.id, "name": self.name, "cwd": self.cwd, "detail": self.detail,
            "command": (self.windows_command or self.command) if os.name == "nt" else self.command,
        }


def project_file(path: Path, root: Path) -> bool:
    try:
        return path.is_file() and path.resolve().is_relative_to(root)
    except (OSError, RuntimeError, ValueError):
        return False


def read_project_file(path: Path, root: Path) -> bytes | None:
    try:
        resolved = path.resolve(strict=True)
        if not resolved.is_relative_to(root) or not resolved.is_file():
            return None
        with resolved.open("rb") as stream:
            value = stream.read(CONFIG_LIMIT + 1)
        return value if len(value) <= CONFIG_LIMIT else None
    except (OSError, RuntimeError, ValueError):
        return None


def read_toml(path: Path, root: Path) -> dict:
    source = read_project_file(path, root)
    if source is None:
        raise ValueError("Unreadable TOML")
    return tomllib.loads(source.decode("utf-8-sig"))


def optional_toml(path: Path, root: Path) -> dict:
    try:
        return read_toml(path, root)
    except (ValueError, RecursionError):
        return {}


def child_paths(directory: Path) -> list[Path]:
    try:
        return sorted(directory.iterdir(), key=lambda path: (path.name.casefold(), path.name))
    except OSError:
        return []


def files_matching(directory: Path, root: Path, suffixes: set[str]) -> list[Path]:
    return [
        path for path in child_paths(directory)
        if path.suffix.lower() in suffixes and project_file(path, root)
    ]


def python_commands(directory: Path, root: Path, cwd: str):
    manifest = optional_toml(directory / "pyproject.toml", root)
    tool = manifest.get("tool")
    uv = project_file(directory / "uv.lock", root)
    has_tests = project_file(directory / "pytest.ini", root) or (
        isinstance(tool, dict) and isinstance(tool.get("pytest"), dict)
    )
    if not has_tests and manifest:
        has_tests = any(path.name.startswith("test_") or path.name.endswith("_test.py")
                        for path in files_matching(directory / "tests", root, {".py"}))
    if has_tests:
        if uv:
            yield Candidate("Python Test", "uv run pytest", cwd, "Python")
        else:
            yield Candidate("Python Test", "python3 -m pytest", cwd, "Python", "python -m pytest")
    project = manifest.get("project")
    scripts = project.get("scripts") if isinstance(project, dict) else None
    if uv and isinstance(scripts, dict):
        for name, entrypoint in scripts.items():
            if PORTABLE_NAME.fullmatch(name) and isinstance(entrypoint, str) and entrypoint.strip():
                yield Candidate(f"Python Run {name}", f"uv run {name}", cwd, "Python")


def go_commands(directory: Path, root: Path, cwd: str):
    if not project_file(directory / "go.mod", root):
        return
    yield Candidate("Go Build", "go build ./...", cwd, "Go")
    yield Candidate("Go Test", "go test ./...", cwd, "Go")
    packages = [directory, *child_paths(directory / "cmd")]
    for package in packages:
        source = read_project_file(package / "main.go", root)
        if source is None or not GO_MAIN.search(source.decode("utf-8", errors="replace")):
            continue
        if package == directory:
            yield Candidate("Go Run", "go run .", cwd, "Go")
        elif PORTABLE_NAME.fullmatch(package.name):
            yield Candidate(f"Go Run {package.name}", f"go run ./cmd/{package.name}", cwd, "Go")


def rust_commands(directory: Path, root: Path, cwd: str):
    manifest = optional_toml(directory / "Cargo.toml", root)
    package = manifest.get("package")
    if not isinstance(package, dict) and not isinstance(manifest.get("workspace"), dict):
        return
    yield Candidate("Rust Build", "cargo build", cwd, "Rust")
    yield Candidate("Rust Test", "cargo test", cwd, "Rust")
    if not isinstance(package, dict):
        return
    explicit = manifest.get("bin", [])
    default = package.get("default-run")
    autobins = package.get("autobins") is not False
    implicit_main = autobins and project_file(directory / "src/main.rs", root)
    multiple_possible = autobins and (directory / "src/bin").is_dir()
    single_binary = isinstance(explicit, list) and not multiple_possible and len(explicit) + int(implicit_main) == 1
    if (isinstance(default, str) and default.strip()) or single_binary:
        yield Candidate("Rust Run", "cargo run", cwd, "Rust")


def dotnet_commands(directory: Path, root: Path, cwd: str):
    solution_suffixes = {".sln", ".slnx"}
    files = files_matching(directory, root, PROJECT_FILES | solution_suffixes)
    only = len(files) == 1
    for path in files:
        if not only and not PORTABLE_NAME.fullmatch(path.name.replace(" ", "_")):
            continue
        target = "" if only else f' "./{path.name}"'
        suffix = "" if only else f" ({path.name})"
        yield Candidate(f".NET Build{suffix}", f"dotnet build{target}", cwd, ".NET")
        if path.suffix.lower() in solution_suffixes:
            yield Candidate(f".NET Test{suffix}", f"dotnet test{target}", cwd, ".NET")
            continue
        source = read_project_file(path, root)
        if source is None:
            continue
        try:
            project = ElementTree.fromstring(source)
        except ElementTree.ParseError:
            continue
        is_test = any(
            (field.tag.rsplit("}", 1)[-1] == "IsTestProject" and (field.text or "").strip().lower() == "true")
            or (field.tag.rsplit("}", 1)[-1] == "PackageReference"
                and field.attrib.get("Include", "").casefold() == "microsoft.net.test.sdk")
            for field in project.iter()
        )
        if is_test:
            yield Candidate(f".NET Test{suffix}", f"dotnet test{target}", cwd, ".NET")
        is_executable = project.attrib.get("Sdk") == "Microsoft.NET.Sdk.Web" or any(
            field.tag.rsplit("}", 1)[-1] == "OutputType" and (field.text or "").strip().casefold() in {"exe", "winexe"}
            for field in project.iter()
        )
        if is_executable and not is_test:
            target = "" if only else f' --project "./{path.name}"'
            yield Candidate(f".NET Run{suffix}", f"dotnet run{target}", cwd, ".NET")


def candidates_in(directory: Path, root: Path):
    cwd = relative_directory(directory, root)
    if control_characters(cwd):
        return
    if any(project_file(directory / name, root) for name in COMPOSE_FILES):
        yield Candidate("Docker Compose Up", "docker compose up", cwd, "Docker Compose")
    yield from python_commands(directory, root, cwd)
    yield from go_commands(directory, root, cwd)
    yield from rust_commands(directory, root, cwd)
    yield from dotnet_commands(directory, root, cwd)


def codex_actions(root: Path) -> tuple[list[dict], dict | None]:
    path = root / ENVIRONMENT_PATH
    try:
        try:
            path.lstat()
        except FileNotFoundError:
            return [], None
        environment = read_toml(path, root)
        entries = environment.get("actions", [])
        if type(environment.get("version")) is not int or environment["version"] != 1 or not isinstance(entries, list):
            raise ValueError("Unsupported local environment")
        platform = "win32" if os.name == "nt" else "darwin"
        shell = "powershell" if os.name == "nt" else "sh"
        selected = {}
        for entry in entries:
            if not isinstance(entry, dict):
                raise ValueError("Invalid Action")
            name, command, target = entry.get("name"), entry.get("command"), entry.get("platform")
            if (
                not isinstance(name, str) or not name.strip() or control_characters(name)
                or not isinstance(command, str) or not command.strip() or "\x00" in command
                or (target is not None and not isinstance(target, str))
            ):
                raise ValueError("Invalid Action")
            if target not in (None, platform):
                continue
            name = name.strip()
            if name not in selected or target == platform:
                selected[name] = {
                    "id": "codex-action:" + hashlib.sha256(name.encode()).hexdigest()[:24],
                    "name": name, "command": command, "cwd": "", "detail": "Codex Action", "shell": shell,
                }
        return list(selected.values()), None
    except (ValueError, RecursionError, OSError):
        return [], CommandError(
            f"Could not read Codex Actions from {ENVIRONMENT_PATH} (version 1 required).",
            f"无法读取 {ENVIRONMENT_PATH} 中的 Codex Actions（需要版本 1）。",
        ).row()


def read_command_config(root: Path) -> tuple[dict, bytes | None]:
    path = root / CONFIG_PATH
    try:
        path.lstat()
    except FileNotFoundError:
        return {"commands": []}, None
    source = read_project_file(path, root)
    if source is None:
        raise ValueError("Unreadable JSON")
    value = json.loads(source)
    if not isinstance(value, dict) or not isinstance(value.get("commands"), list):
        raise ValueError("Invalid command config")
    return value, source


def entry_command(entry: dict, platform: str):
    platforms = entry.get("platforms")
    override = platforms.get(platform) if isinstance(platforms, dict) else None
    return override.get("command", entry.get("command")) if isinstance(override, dict) else entry.get("command")


def saved_commands(entries: list, root: Path) -> set[tuple[Path, str, str]]:
    platform = "windows" if os.name == "nt" else "macos"
    saved = set()
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        cwd = entry.get("cwd")
        if cwd is not None and not isinstance(cwd, str):
            continue
        try:
            directory = configured_directory(root, "." if cwd is None else cwd)
        except (OSError, ValueError, RuntimeError):
            continue
        name, command = entry.get("name"), entry_command(entry, platform)
        if isinstance(name, str):
            saved.add((directory, "name", name))
        if isinstance(command, str):
            saved.add((directory, "command", command))
    return saved


def is_saved(candidate: Candidate, directory: Path, saved: set[tuple[Path, str, str]]) -> bool:
    command = (candidate.windows_command or candidate.command) if os.name == "nt" else candidate.command
    return (directory, "name", candidate.name) in saved or (directory, "command", command) in saved


def scan_project_commands(root: Path) -> tuple[list[dict], list[dict], dict | None]:
    root = root.resolve()
    actions, action_error = codex_actions(root)
    try:
        config, _ = read_command_config(root)
        saved = saved_commands(config["commands"], root)
    except (OSError, ValueError, RuntimeError):
        saved = set()
    candidates = []
    for directory in project_directories(root):
        for candidate in candidates_in(directory, root):
            if not is_saved(candidate, directory, saved):
                candidates.append(candidate.row())
    return candidates, actions, action_error


def resolve_candidate(root: Path, candidate_id: str) -> Candidate:
    try:
        encoded, checksum = candidate_id.split(".")
        if len(checksum) != 24:
            raise ValueError("Invalid candidate identifier")
        cwd = base64.b64decode(encoded, altchars=b"-_", validate=True).decode()
        directory = configured_directory(root, cwd or ".")
        for candidate in candidates_in(directory, root):
            if candidate.id == candidate_id:
                return candidate
    except (OSError, ValueError, RuntimeError):
        pass
    raise CommandError("This command suggestion has changed. Rescan and try again.", "命令建议已变化。请重新扫描后再试。")


def write_command_config(path: Path, config: dict, original: bytes | None, root: Path) -> None:
    payload = (json.dumps(config, indent=2, ensure_ascii=False) + "\n").encode()
    if len(payload) > CONFIG_LIMIT:
        raise CommandError(f"{CONFIG_PATH} would exceed 256 KiB.", f"{CONFIG_PATH} 将超过 256 KiB。")
    if path.parent.is_symlink() or path.is_symlink():
        raise CommandError(f"{CONFIG_PATH} must be a regular project file.", f"{CONFIG_PATH} 必须是项目内的普通文件。")
    path.parent.mkdir(exist_ok=True)
    if path.parent.resolve().parent != root or (path.exists() and not path.is_file()):
        raise CommandError(f"{CONFIG_PATH} must be a regular project file.", f"{CONFIG_PATH} 必须是项目内的普通文件。")
    temporary = None
    try:
        with NamedTemporaryFile(dir=path.parent, prefix=".script-manager-", delete=False) as output:
            temporary = Path(output.name)
            output.write(payload)
        if original is not None:
            os.chmod(temporary, stat.S_IMODE(path.stat().st_mode))
        _, current = read_command_config(root)
        if current != original:
            raise CommandError(f"{CONFIG_PATH} changed. Rescan and try again.", f"{CONFIG_PATH} 已变化。请重新扫描后再试。")
        os.replace(temporary, path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def save_project_candidate(root: Path, candidate_id: str) -> None:
    root = root.resolve()
    candidate = resolve_candidate(root, candidate_id)
    try:
        config, original = read_command_config(root)
        _, error = configured_commands(root)
        if error:
            raise CommandError(error.english, error.chinese)
        entries = config["commands"]
        if is_saved(candidate, root / candidate.cwd, saved_commands(entries, root)):
            return
        new_entry = candidate.entry
        names = {entry["name"].strip() for entry in entries}
        name = candidate.name[:COMMAND_NAME_LIMIT].rstrip()
        if name in names:
            name = f"{candidate.name} ({candidate.cwd or '.'})"[:COMMAND_NAME_LIMIT].rstrip()
            counter = 2
            base = name
            while name in names:
                suffix = f" {counter}"
                name = base[:COMMAND_NAME_LIMIT - len(suffix)].rstrip() + suffix
                counter += 1
        new_entry["name"] = name
        entries.append(new_entry)
        write_command_config(root / CONFIG_PATH, config, original, root)
    except (OSError, ValueError, RuntimeError) as error:
        raise CommandError(f"Could not update {CONFIG_PATH}. Check the file and permissions.",
                           f"无法更新 {CONFIG_PATH}。请检查文件内容和权限。") from error


def main() -> None:
    operation, directory, *arguments = sys.argv[1:]
    root = Path(directory)
    if operation == "scan":
        candidates, actions, action_error = scan_project_commands(root)
        print(json.dumps({"candidates": candidates, "actions": actions, "actionError": action_error}))
    elif operation == "add":
        try:
            save_project_candidate(root, arguments[0])
            print('{"ok":true}')
        except CommandError as error:
            print(json.dumps({"error": error.row()}))


if __name__ == "__main__":
    main()
