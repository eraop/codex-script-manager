from __future__ import annotations

from collections import deque
from contextlib import closing
from dataclasses import dataclass
import json
import os
from pathlib import Path
import re
import shlex
import sqlite3
import stat
import subprocess


DEBUG_OPTION = "-agentlib:jdwp=transport=dt_socket,server=y,suspend=n,address=127.0.0.1:5005"
CONFIG_PATH = ".codex/script-manager.json"
CONFIG_LIMIT = 256 * 1024
SKIP_DIRECTORIES = {
    "node_modules", "build", "dist", "target", "out", "coverage", "vendor", "pods",
    "fixtures", "__fixtures__", "testdata",
}
LOCKFILES = (
    ("pnpm-lock.yaml", "pnpm"), ("yarn.lock", "yarn"), ("bun.lock", "bun"),
    ("bun.lockb", "bun"), ("package-lock.json", "npm"), ("npm-shrinkwrap.json", "npm"),
    ("pnpm-workspace.yaml", "pnpm"),
)
MAVEN_PLUGIN = re.compile(r"<artifactId>\s*spring-boot-maven-plugin\s*</artifactId>")
MAVEN_STARTER = re.compile(r"<artifactId>\s*spring-boot-starter(?:-[^<]+)?\s*</artifactId>")
GRADLE_COMMENTS = re.compile(r"/\*[\s\S]*?\*/|^[ \t]*//[^\n]*", re.MULTILINE)
GRADLE_BOOT = re.compile(
    r"[\"']org\.springframework\.boot[\"'](?:(?!apply\s+false)[^\n])*$"
    r"|\bbootRun\b|\balias\s*\(\s*libs\.plugins\.spring[._-]?boot\b",
    re.MULTILINE,
)


@dataclass(frozen=True)
class Task:
    id: str
    name: str
    cwd: Path
    executable: str | None
    arguments: tuple[str, ...]
    detail: str
    package_path: str
    package_name: str | None = None
    configured_command: str | None = None
    gradle_debug: bool = False
    root: Path | None = None
    shell: str | None = None

    @property
    def command(self) -> str:
        if self.configured_command is not None:
            return self.configured_command
        assert self.executable is not None
        argv = (self.executable, *self.arguments)
        command = subprocess.list2cmdline(argv) if os.name == "nt" else shlex.join(argv)
        return command + (" --init-script <JDWP>" if self.gradle_debug else "")

    def row(self) -> dict:
        result = {
            "id": self.id, "name": self.name, "detail": self.detail,
            "command": self.command, "packagePath": self.package_path,
        }
        if self.package_name is not None:
            result["packageName"] = self.package_name
        if self.root is not None:
            result["rootPath"] = str(self.root)
        return result


@dataclass(frozen=True)
class ConfigError:
    english: str
    chinese: str

    def localized(self, locale: str | None) -> str:
        return self.chinese if locale == "zh-CN" else self.english


def is_file(path: Path) -> bool:
    try:
        return path.is_file()
    except OSError:
        return False


def read_text(path: Path) -> str | None:
    if not is_file(path):
        return None
    try:
        return path.read_text(encoding="utf-8-sig")
    except (OSError, UnicodeError):
        return None


def read_object(path: Path) -> dict:
    content = read_text(path)
    if content is not None:
        try:
            value = json.loads(content)
            if isinstance(value, dict):
                return value
        except (ValueError, RecursionError):
            pass
    return {}


def lineage(directory: Path, root: Path):
    while True:
        yield directory
        if directory == root:
            return
        directory = directory.parent


def project_directories(root: Path):
    pending = deque([root])
    while pending:
        directory = pending.popleft()
        yield directory
        try:
            with os.scandir(directory) as children:
                for child in sorted(children, key=lambda item: item.name):
                    if child.name.startswith(".") or child.name.casefold() in SKIP_DIRECTORIES:
                        continue
                    try:
                        if not child.is_dir(follow_symlinks=False):
                            continue
                        if os.name == "nt" and child.stat(follow_symlinks=False).st_file_attributes & (
                            stat.FILE_ATTRIBUTE_REPARSE_POINT | stat.FILE_ATTRIBUTE_HIDDEN
                        ):
                            continue
                    except OSError:
                        continue
                    pending.append(Path(child.path))
        except OSError:
            continue


def relative_directory(directory: Path, root: Path) -> str:
    return "" if directory == root else directory.relative_to(root).as_posix()


def task_detail(kind: str, package_path: str) -> str:
    return f"{kind} · {package_path}" if package_path else kind


def control_characters(value: str) -> bool:
    return any(codepoint < 32 or 127 <= codepoint <= 159 or 0xD800 <= codepoint <= 0xDFFF
               for codepoint in map(ord, value))


def configured_directory(root: Path, cwd: str) -> Path:
    if not cwd.strip() or control_characters(cwd) or Path(cwd).anchor:
        raise ValueError("cwd must be relative")
    directory = (root / cwd).resolve(strict=True)
    if not directory.is_relative_to(root) or not directory.is_dir():
        raise ValueError("cwd must be inside the project")
    return directory


def command_error(index: int, english: str, chinese: str) -> ConfigError:
    return ConfigError(f"{CONFIG_PATH}, command {index}: {english}", f"{CONFIG_PATH} 的第 {index} 条命令{chinese}")


def valid_command(value):
    return isinstance(value, str) and bool(value.strip()) and not re.search(r"[\x00\ud800-\udfff]", value)


def platform_command(entry):
    default = entry.get("command")
    if default is not None and not valid_command(default):
        raise ValueError
    platforms = entry.get("platforms")
    if platforms is None:
        platforms = {}
    if not isinstance(platforms, dict):
        raise ValueError
    for platform, override in platforms.items():
        if platform not in ("macos", "windows") or not isinstance(override, dict) or not valid_command(override.get("command")):
            raise ValueError
    if default is None and not platforms:
        raise ValueError
    platform = "windows" if os.name == "nt" else "macos"
    return platforms.get(platform, {}).get("command", default)


def configured_commands(root: Path) -> tuple[list[Task], ConfigError | None]:
    config = root / CONFIG_PATH
    unreadable = ConfigError(f"Could not read {CONFIG_PATH} as a project file.", f"无法读取项目中的 {CONFIG_PATH}。")
    invalid = ConfigError(
        f"{CONFIG_PATH} must contain a commands array with a name and command for each entry.",
        f"{CONFIG_PATH} 必须包含 commands 数组，每项填写名称和命令。",
    )
    try:
        config.lstat()
    except FileNotFoundError:
        return [], None
    except OSError:
        return [], unreadable
    try:
        config = config.resolve(strict=True)
        if not config.is_relative_to(root) or not config.is_file():
            return [], unreadable
        with config.open("rb") as stream:
            payload = stream.read(CONFIG_LIMIT + 1)
    except (OSError, RuntimeError):
        return [], unreadable
    if len(payload) > CONFIG_LIMIT:
        return [], ConfigError(f"{CONFIG_PATH} must be 256 KiB or smaller.", f"{CONFIG_PATH} 不能超过 256 KiB。")
    try:
        manifest = json.loads(payload)
    except (ValueError, RecursionError):
        return [], invalid
    entries = manifest.get("commands") if isinstance(manifest, dict) else None
    if not isinstance(entries, list):
        return [], invalid

    tasks = []
    names = set()
    for index, entry in enumerate(entries, start=1):
        if not isinstance(entry, dict):
            return [], invalid
        name, cwd = (entry.get(field) for field in ("name", "cwd"))
        if not isinstance(name, str) or (cwd is not None and not isinstance(cwd, str)):
            return [], invalid
        if not 1 <= len(name.strip()) <= 256 or control_characters(name):
            return [], command_error(index, "name must be 1–256 characters with no control characters.",
                                     "名称须为 1 到 256 个字符，且不能包含控制字符。")
        name = name.strip()
        if name in names:
            return [], command_error(index, "name is already in use.", "使用了重复的名称。")
        try:
            command = platform_command(entry)
        except ValueError:
            return [], command_error(index, "provide a nonempty default or platform command without NUL characters.",
                                     "需要填写非空且不含 NUL 字符的默认命令或平台命令。")
        names.add(name)
        if command is None:
            continue
        try:
            directory = configured_directory(root, "." if cwd is None else cwd)
        except (ValueError, RuntimeError, OSError):
            return [], command_error(index, "cwd must be a relative path to a folder inside the project.",
                                     "需要使用项目内目录的相对路径作为 cwd。")
        package_path = relative_directory(directory, root)
        tasks.append(Task(f"{root.as_uri()}#command:{name}", name, directory, None, (),
                          task_detail("Shell", package_path), package_path, configured_command=command))
    return tasks, None


def package_manager(directory: Path, root: Path, manifest: dict) -> str:
    for ancestor in lineage(directory, root):
        config = manifest if ancestor == directory else read_object(ancestor / "package.json")
        declared = config.get("packageManager")
        if isinstance(declared, str):
            name = declared.split("@", 1)[0]
            if name in ("npm", "pnpm", "yarn", "bun"):
                return name
        for filename, name in LOCKFILES:
            if is_file(ancestor / filename):
                return name
    return "npm"


def script_name_key(name: str) -> list[tuple[int, str]]:
    key = []
    for index, part in enumerate(re.split(r"([0-9]+)", name.casefold())):
        if index % 2:
            part = part.lstrip("0")
            key.append((len(part), part))
        else:
            key.append((0, part))
    return key


def node_tasks(directory: Path, root: Path, package_path: str) -> list[Task]:
    manifest = read_object(directory / "package.json")
    scripts = manifest.get("scripts")
    if not isinstance(scripts, dict):
        return []
    executable = package_manager(directory, root, manifest)
    name = manifest.get("name")
    package_name = name.strip() if isinstance(name, str) and not control_characters(name) else None
    uri = directory.as_uri()
    tasks = []
    for name in sorted(scripts, key=script_name_key):
        if not name or control_characters(name) or not isinstance(scripts[name], str) or not scripts[name]:
            continue
        arguments = ("run", "--", name) if name.startswith("-") else ("run", name)
        tasks.append(Task(f"{uri}#node:{name}", name, directory, executable, arguments,
                          task_detail(executable, package_path), package_path, package_name or None))
    return tasks


def wrapper(name: str, windows_name: str, directory: Path, root: Path) -> str | None:
    for ancestor in lineage(directory, root):
        path = ancestor / (windows_name if os.name == "nt" else name)
        if is_file(path) and (os.name == "nt" or os.access(path, os.X_OK)):
            return str(path)
    return None


def spring_tasks(directory: Path, package_path: str, kind: str, executable: str,
                 arguments: tuple[str, ...], debug_arguments: tuple[str, ...] = ()) -> list[Task]:
    task_id = f"{directory.as_uri()}#{kind.casefold()}"
    return [
        Task(f"{task_id}:run", "Spring Boot Run", directory, executable, arguments,
             task_detail(kind, package_path), package_path),
        Task(f"{task_id}:debug", "Spring Boot Debug", directory, executable, arguments + debug_arguments,
             task_detail(f"{kind} · JDWP 127.0.0.1:5005", package_path), package_path, gradle_debug=kind == "Gradle"),
    ]


def pom_contents(directory: Path) -> str:
    return re.sub(r"<!--[\s\S]*?-->", "", read_text(directory / "pom.xml") or "")


def maven_tasks(directory: Path, root: Path, package_path: str) -> list[Task]:
    pom = pom_contents(directory)
    if not pom or re.search(r"<packaging>\s*pom\s*</packaging>", pom):
        return []
    if not (MAVEN_PLUGIN.search(pom) or re.search(r"<artifactId>\s*spring-boot-starter-parent\s*</artifactId>", pom)):
        ancestors = lineage(directory, root)
        next(ancestors)
        if not MAVEN_STARTER.search(pom) or not any(MAVEN_PLUGIN.search(pom_contents(parent)) for parent in ancestors):
            return []
    executable = wrapper("mvnw", "mvnw.cmd", directory, root) or "mvn"
    return spring_tasks(directory, package_path, "Maven", executable, ("spring-boot:run",),
                        (f"-Dspring-boot.run.jvmArguments={DEBUG_OPTION}",))


def gradle_tasks(directory: Path, root: Path, package_path: str) -> list[Task]:
    manifest = read_text(directory / "build.gradle.kts")
    if manifest is None:
        manifest = read_text(directory / "build.gradle")
    if manifest is None or not GRADLE_BOOT.search(GRADLE_COMMENTS.sub("", manifest)):
        return []
    gradle_root = next((parent for parent in lineage(directory, root)
                        if is_file(parent / "settings.gradle") or is_file(parent / "settings.gradle.kts")), directory)
    executable = wrapper("gradlew", "gradlew.bat", directory, gradle_root) or "gradle"
    module = relative_directory(directory, gradle_root).replace("/", ":")
    task_name = f":{module}:bootRun" if module else ":bootRun"
    return spring_tasks(directory, package_path, "Gradle", executable, ("--no-daemon", "--console=plain", task_name))


def discover_tasks(root: Path) -> tuple[list[Task], ConfigError | None]:
    root = root.resolve()
    tasks = []
    for directory in project_directories(root):
        package_path = relative_directory(directory, root)
        tasks.extend(node_tasks(directory, root, package_path))
        tasks.extend(maven_tasks(directory, root, package_path))
        tasks.extend(gradle_tasks(directory, root, package_path))
    configured, error = configured_commands(root)
    tasks.extend(configured)
    return tasks, error


@dataclass(frozen=True)
class Project:
    path: Path
    name: str
    pinned: bool
    roots: tuple[Path, ...] = ()


def string_list(value) -> list[str]:
    return [item for item in value if isinstance(item, str)] if isinstance(value, list) else []


def local_path(value: str) -> Path | None:
    if not isinstance(value, str) or "\0" in value:
        return None
    path = Path(value)
    if not path.is_absolute():
        return None
    if os.name == "nt":
        drive = path.drive.casefold().removeprefix("\\\\?\\unc\\")
        server = drive.lstrip("\\").partition("\\")[0]
        if server in {"wsl$", "wsl.localhost"}:
            return None
    try:
        resolved = path.resolve()
        str(resolved).encode("utf-8")
        return resolved
    except (OSError, RuntimeError, ValueError):
        return None


class ProjectCatalog:
    def __init__(self, home: Path | None = None):
        custom_home = Path(os.environ.get("CODEX_HOME", ""))
        self.home = home if home is not None else custom_home if custom_home.is_absolute() else Path.home() / ".codex"
        self.entries = {}

    def read(self) -> list[Project]:
        state = read_object(self.home / ".codex-global-state.json")
        entries = self.database_entries()
        if entries is not None:
            self.entries = entries
        else:
            legacy = self.legacy_entries(state)
            if legacy is not None:
                self.entries = legacy

        by_id = {}
        for project_id, (name, roots) in self.entries.items():
            path = local_path(roots[0]) if roots else None
            if path is None or (len(roots) == 1 and path.parent.name == ".chatgpt-projects"):
                continue
            attached = tuple(dict.fromkeys(
                [path] + [candidate for value in roots[1:] if (candidate := local_path(value)) is not None]
            ))
            by_id[project_id] = (path, name if name and not control_characters(name) else path.name or str(path), attached)

        migrated_by_host = state.get("app-server-project-id-by-legacy-project-id-by-host")
        migrated = {}
        if isinstance(migrated_by_host, dict):
            same_host = {os.path.normcase(f"local:{path}") for path in (str(self.home), self.home.as_posix())}
            for host, mapping in migrated_by_host.items():
                if os.path.normcase(host) in same_host and isinstance(mapping, dict):
                    migrated = {key: value for key, value in mapping.items() if isinstance(value, str)}
                    break

        def pinned_id(project_id: str) -> str:
            return project_id if project_id in by_id else migrated.get(project_id, project_id)

        pinned = dict.fromkeys(pinned_id(project_id) for project_id in string_list(state.get("pinned-project-ids")))
        projects = []
        for project_id in dict.fromkeys([*pinned, *by_id]):
            if project_id not in by_id:
                continue
            path, name, roots = by_id[project_id]
            projects.append(Project(path, name, project_id in pinned, roots))
        return projects

    def database_entries(self) -> dict | None:
        database = self.home / "state_5.sqlite"
        if not is_file(database):
            return None
        entries = {}
        try:
            with closing(sqlite3.connect(database.resolve().as_uri() + "?mode=ro", uri=True, timeout=0.05)) as db:
                rows = db.execute("""
                    SELECT p.id, p.name, r.path
                    FROM projects AS p JOIN project_roots AS r ON r.project_id = p.id
                    ORDER BY p.position, p.id, r.position
                """)
                for project_id, name, path in rows:
                    if all(isinstance(value, str) for value in (project_id, name, path)):
                        entries.setdefault(project_id, (name, []))[1].append(path)
        except sqlite3.OperationalError as error:
            if "no such table" in str(error) or "no such column" in str(error):
                return None
            return self.entries or None
        except (sqlite3.Error, ValueError, OSError, RuntimeError):
            return self.entries or None
        return entries

    @staticmethod
    def legacy_entries(state: dict) -> dict | None:
        projects = state.get("local-projects")
        if not isinstance(projects, dict):
            return None
        entries = {}
        for project_id in dict.fromkeys(string_list(state.get("project-order")) + sorted(projects)):
            project = projects.get(project_id)
            if isinstance(project, dict) and isinstance(project.get("name"), str):
                entries[project_id] = (project["name"], string_list(project.get("rootPaths")))
        return entries
