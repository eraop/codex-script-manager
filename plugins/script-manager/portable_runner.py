from __future__ import annotations

import base64
from concurrent.futures import Future, ThreadPoolExecutor
import ctypes
from ctypes import wintypes
from dataclasses import dataclass, field
import hashlib
import json
import locale as system_locale
import os
from pathlib import Path, PureWindowsPath
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time

from portable_discovery import DEBUG_OPTION, ConfigError, ProjectCatalog, Task, discover_tasks, local_path
from repair import ANSI


LOG_LIMIT = 120_000
ACTIVE = {"running", "stopping"}
STATUS_LABELS = {
    "idle": ("Idle", "未运行"),
    "running": ("Running", "运行中"),
    "stopping": ("Stopping", "正在停止"),
    "stopped": ("Stopped", "已停止"),
    "succeeded": ("Succeeded", "成功"),
    "failed": ("Launch failed", "启动失败"),
}
UTF8_ESCAPES = re.compile(r"[\udc80-\udcff]+")

WINDOWS_LAUNCHER = """
import json, os, subprocess, sys
request = json.loads(sys.stdin.buffer.readline())
try:
    code = subprocess.call(
        request["command"], executable=request["executable"],
        env={**os.environ, **request["env"]}, stdin=subprocess.DEVNULL,
        creationflags=subprocess.CREATE_NO_WINDOW,
    )
except (OSError, ValueError) as error:
    print(f"[Launch failed] {error}", file=sys.stderr)
    code = 1
sys.exit(code if code <= 0x7fffffff else code - 0x100000000)
"""

PICK_FOLDER = """
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
Add-Type -AssemblyName System.Windows.Forms
$picker = New-Object System.Windows.Forms.FolderBrowserDialog
$picker.Description = '%s'
if ($picker.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
    [Console]::Write($picker.SelectedPath)
}
$picker.Dispose()
"""


class PortableError(Exception):
    def __init__(self, english, chinese=None):
        super().__init__(english)
        self.chinese = chinese or english


def translate(locale, english, chinese):
    return chinese if locale and locale.replace("_", "-").lower().startswith("zh") else english


def decode_log(data):
    encoding = system_locale.getpreferredencoding(False)
    text = data.decode("utf-8", errors="surrogateescape")
    if encoding.lower() not in ("utf-8", "utf8"):
        text = UTF8_ESCAPES.sub(
            lambda match: match[0].encode("utf-8", "surrogateescape").decode(encoding, "replace"),
            text,
        )
    else:
        text = UTF8_ESCAPES.sub(lambda match: "\ufffd" * len(match[0]), text)
    return ANSI.sub("", text.replace("\r\n", "\n"))


@dataclass
class ManagedProject:
    path: Path
    name: str
    source: str
    pinned: bool
    available: bool
    tasks: dict[str, Task] = field(default_factory=dict)
    retired: set[str] = field(default_factory=set)
    scan: Future[tuple[list[Task], ConfigError | None]] | None = None
    config_error: ConfigError | None = None
    selected_task: str | None = None

    @property
    def id(self):
        return str(self.path)


@dataclass
class Run:
    locale: str | None
    status: str = "running"
    code: int | None = None
    tree: ProcessTree | None = None
    log: bytearray = field(default_factory=bytearray)
    truncated: bool = False

    def append(self, data):
        if isinstance(data, str):
            data = data.encode("utf-8", errors="replace")
        self.log.extend(data)
        if len(self.log) > LOG_LIMIT:
            del self.log[:-(LOG_LIMIT * 3 // 4)]
            self.truncated = True

    def output(self, locale):
        prefix = translate(locale, "[Earlier output truncated]\n", "[较早输出已截断]\n") if self.truncated else ""
        return prefix + decode_log(self.log)


def status_row(locale, status, code=None):
    label = translate(locale, *STATUS_LABELS[status])
    if status == "failed" and code is not None:
        label = translate(locale, f"Exit code {code}", f"退出码 {code}")
    row = {"status": label, "statusKind": status, "active": status in ACTIVE, "stopping": status == "stopping"}
    if status == "failed":
        row["exitCode"] = code
    return row


class BasicJobLimits(ctypes.Structure):
    _fields_ = [
        ("per_process_time", ctypes.c_int64),
        ("per_job_time", ctypes.c_int64),
        ("flags", ctypes.c_uint32),
        ("minimum_working_set", ctypes.c_size_t),
        ("maximum_working_set", ctypes.c_size_t),
        ("active_process_limit", ctypes.c_uint32),
        ("affinity", ctypes.c_size_t),
        ("priority", ctypes.c_uint32),
        ("scheduling", ctypes.c_uint32),
    ]


class IoCounters(ctypes.Structure):
    _fields_ = [(name, ctypes.c_uint64) for name in ("read", "write", "other", "read_bytes", "write_bytes", "other_bytes")]


class ExtendedJobLimits(ctypes.Structure):
    _fields_ = [
        ("basic", BasicJobLimits),
        ("io", IoCounters),
        ("process_memory_limit", ctypes.c_size_t),
        ("job_memory_limit", ctypes.c_size_t),
        ("process_memory_peak", ctypes.c_size_t),
        ("job_memory_peak", ctypes.c_size_t),
    ]


class WindowsJob:
    def __init__(self):
        api = ctypes.WinDLL("kernel32", use_last_error=True)
        api.CreateJobObjectW.argtypes = [ctypes.c_void_p, wintypes.LPCWSTR]
        api.CreateJobObjectW.restype = wintypes.HANDLE
        api.SetInformationJobObject.argtypes = [wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p, wintypes.DWORD]
        api.SetInformationJobObject.restype = wintypes.BOOL
        api.AssignProcessToJobObject.argtypes = [wintypes.HANDLE, wintypes.HANDLE]
        api.AssignProcessToJobObject.restype = wintypes.BOOL
        api.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
        api.OpenProcess.restype = wintypes.HANDLE
        api.CloseHandle.argtypes = [wintypes.HANDLE]
        api.CloseHandle.restype = wintypes.BOOL
        self.api = api
        self.handle = api.CreateJobObjectW(None, None)
        if not self.handle:
            raise ctypes.WinError(ctypes.get_last_error())
        limits = ExtendedJobLimits()
        limits.basic.flags = 0x2000  # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        if not api.SetInformationJobObject(self.handle, 9, ctypes.byref(limits), ctypes.sizeof(limits)):
            error = ctypes.WinError(ctypes.get_last_error())
            self.close()
            raise error

    def add(self, pid):
        process = self.api.OpenProcess(0x0101, False, pid)  # PROCESS_SET_QUOTA | PROCESS_TERMINATE
        if not process:
            raise ctypes.WinError(ctypes.get_last_error())
        try:
            if not self.api.AssignProcessToJobObject(self.handle, process):
                raise ctypes.WinError(ctypes.get_last_error())
        finally:
            self.api.CloseHandle(process)

    def close(self):
        if self.handle:
            self.api.CloseHandle(self.handle)
            self.handle = None


def windows_system_command(name):
    path = Path(os.environ.get("SystemRoot", r"C:\Windows")) / "System32" / name
    if path.is_file():
        return str(path.absolute())
    found = shutil.which(path.name)
    return os.path.abspath(found) if found else None


def cmd_invocation(command):
    interpreter = windows_system_command("cmd.exe")
    if interpreter is None:
        raise PortableError("Command Prompt is unavailable.", "找不到命令提示符。")
    prefix = subprocess.list2cmdline([interpreter, "/d", "/v:off", "/s", "/c"])
    return f'{prefix} "{command}"', interpreter


def batch_invocation(executable, arguments):
    environment = {}
    for index, argument in enumerate((executable, *arguments)):
        if any(character in argument for character in '"\r\n\x00'):
            raise PortableError("A batch script argument contains an unsupported character.", "批处理脚本参数包含不支持的字符。")
        name = f"CODEX_SCRIPT_MANAGER_ARG_{index}"
        trailing_backslashes = len(argument) - len(argument.rstrip("\\"))
        environment[name] = '"' + argument + "\\" * trailing_backslashes + '"'
    # Expanding values once keeps percent signs in paths and arguments literal.
    command, interpreter = cmd_invocation(" ".join(f"%{name}%" for name in environment))
    return command, interpreter, environment


def program_invocation(executable, arguments):
    if executable and Path(executable).is_absolute():
        resolved = executable
    else:
        resolved = shutil.which(executable) if executable else None
    if resolved is None:
        raise PortableError(f"Command not found: {executable}", f"找不到命令：{executable}")
    resolved = os.path.abspath(resolved)
    if Path(resolved).suffix.lower() in (".bat", ".cmd"):
        return batch_invocation(resolved, arguments)
    return [resolved, *arguments], None, {}


class ProcessTree:
    def __init__(self, command, executable, environment, cwd):
        self.lock = threading.Lock()
        self.windows_job = WindowsJob()
        process = None
        try:
            process = subprocess.Popen(
                [sys.executable, "-I", "-c", WINDOWS_LAUNCHER], cwd=cwd,
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                creationflags=subprocess.CREATE_NO_WINDOW,
            )
            # Release the launcher only after the job object can contain all of its descendants.
            self.windows_job.add(process.pid)
            with process.stdin:
                payload = json.dumps({"command": command, "executable": executable, "env": environment})
                process.stdin.write(payload.encode("ascii") + b"\n")
        except BaseException:
            self.windows_job.close()
            if process is not None:
                process.kill()
                process.wait()
                process.stdin.close()
                process.stdout.close()
            raise
        self.process = process

    def terminate(self):
        with self.lock:
            self.windows_job.close()

    def wait(self):
        try:
            return self.process.wait()
        finally:
            self.terminate()


def absolute_directory(value):
    if not isinstance(value, (str, Path)):
        return None
    path = local_path(str(value))
    if path is None:
        return None
    try:
        return path if path.is_dir() else None
    except OSError:
        return None


def is_unc(path):
    drive = PureWindowsPath(path).drive.casefold()
    return drive.startswith("\\\\?\\unc\\") or (drive.startswith("\\\\") and not drive.startswith("\\\\?\\"))


class Runner:
    def __init__(self, home=None):
        if home is None:
            configured = os.environ.get("CODEX_HOME")
            home = Path(configured) if configured and Path(configured).is_absolute() else Path.home() / ".codex"
        self.catalog = ProjectCatalog(home)
        self.manual_directory = home / "script-manager" / "projects"
        self.projects = {}
        self.runs = {}
        self.selected_project = None
        self._last_catalog_check = float("-inf")
        self._lock = threading.RLock()
        self._scanner = ThreadPoolExecutor(max_workers=2, thread_name_prefix="script-manager-scan")
        self._picker_program = windows_system_command(r"WindowsPowerShell\v1.0\powershell.exe")
        self._picker = None
        self._closed = False

    def _manual_paths(self):
        try:
            files = sorted(self.manual_directory.glob("*.json"))
        except OSError:
            return
        for file in files:
            try:
                value = json.loads(file.read_text(encoding="utf-8"))
                if isinstance(value, str) and "\x00" not in value and Path(value).is_absolute():
                    yield Path(value)
            except (OSError, ValueError, UnicodeError):
                continue

    def _save_project(self, path):
        identity = os.path.normcase(str(path))
        filename = hashlib.sha256(os.fsencode(identity)).hexdigest() + ".json"
        temporary = None
        try:
            self.manual_directory.mkdir(mode=0o700, parents=True, exist_ok=True)
            with tempfile.NamedTemporaryFile(dir=self.manual_directory, delete=False, mode="w", encoding="utf-8") as file:
                temporary = Path(file.name)
                json.dump(str(path), file)
            temporary.replace(self.manual_directory / filename)
        except OSError as error:
            raise PortableError(f"Could not save the project: {error}", f"无法保存项目：{error}") from error
        finally:
            if temporary is not None:
                try:
                    temporary.unlink(missing_ok=True)
                except OSError:
                    pass

    def _active(self, project_id, task_id):
        run = self.runs.get((project_id, task_id))
        return run is not None and run.status in ACTIVE

    def _sync_projects(self, *, force=False):
        now = time.monotonic()
        if not force and now - self._last_catalog_check < 1:
            return
        self._last_catalog_check = now
        entries = [(item.path, item.name, "codex", item.pinned) for item in self.catalog.read()]
        entries.extend((path, path.name or str(path), "manual", False) for path in self._manual_paths())
        known_paths = set()
        projects = {}
        for path, name, source, pinned in entries:
            if path in known_paths:
                continue
            known_paths.add(path)
            try:
                available = path.is_dir()
            except OSError:
                available = False
            item = self.projects.get(str(path))
            needs_scan = available and (item is None or not item.available)
            if item is None:
                item = ManagedProject(path, name, source, pinned, available)
            else:
                item.name, item.source, item.pinned, item.available = name, source, pinned, available
            if not available:
                if item.scan is not None:
                    item.scan.cancel()
                    item.scan = None
                item.config_error = None
                item.tasks = {key: task for key, task in item.tasks.items() if self._active(item.id, key)}
                item.retired = set(item.tasks)
            projects[item.id] = item
            if needs_scan:
                self._scan(item)
        for project in self.projects.values():
            if project.id not in projects and any(self._active(project.id, key) for key in project.tasks):
                project.source, project.pinned = "session", False
                projects[project.id] = project
        self.projects = projects
        self.runs = {key: run for key, run in self.runs.items() if key[0] in projects and key[1] in projects[key[0]].tasks}
        if self.selected_project not in projects:
            self.selected_project = next((item.id for item in projects.values() if item.available), next(iter(projects), None))

    def _scan(self, project):
        if project.available and project.scan is None:
            project.scan = self._scanner.submit(discover_tasks, project.path)

    def _collect_scans(self):
        for project in self.projects.values():
            future = project.scan
            if future is None or not future.done():
                continue
            project.scan = None
            if not project.available:
                continue
            try:
                tasks, error = future.result()
            except (OSError, RuntimeError, ValueError) as failure:
                project.config_error = ConfigError(f"Could not scan the project: {failure}", f"无法扫描项目：{failure}")
                continue
            updated = {task.id: task for task in tasks}
            retired = {key for key in project.tasks.keys() - updated.keys() if self._active(project.id, key)}
            updated.update((key, project.tasks[key]) for key in project.tasks if key in retired)
            project.tasks, project.config_error, project.retired = updated, error, retired
            if project.selected_task not in updated:
                project.selected_task = next(iter(updated), None)
            self.runs = {key: run for key, run in self.runs.items() if key[0] != project.id or key[1] in updated}

    def _add(self, path):
        directory = absolute_directory(path)
        if directory is None:
            raise PortableError("Pass the absolute path to an existing project folder.", "请输入已有项目目录的绝对路径。")
        if not any(project.path == directory and project.source == "codex" for project in self.projects.values()):
            self._save_project(directory)
        self._sync_projects(force=True)
        project = next((project for project in self.projects.values() if project.path == directory), None)
        if project is None:
            raise PortableError("The project folder is unavailable.", "项目目录不可用。")
        self.selected_project = project.id
        self._scan(project)
        return project

    def _choose(self, locale):
        if self._picker is not None or self._picker_program is None:
            return
        prompt = translate(locale, "Open Project", "打开项目")
        program = base64.b64encode((PICK_FOLDER % prompt).encode("utf-16le")).decode("ascii")
        try:
            self._picker = subprocess.Popen(
                [self._picker_program, "-NoProfile", "-STA", "-EncodedCommand", program],
                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                creationflags=subprocess.CREATE_NO_WINDOW,
            )
        except OSError:
            self._picker_program = None
            return
        threading.Thread(target=self._collect_picker, args=(self._picker,), daemon=True).start()

    def _collect_picker(self, process):
        output, _ = process.communicate()
        with self._lock:
            self._picker = None
            if self._closed:
                return
            if process.returncode != 0:
                self._picker_program = None
                return
            if output:
                try:
                    self._add(output.decode("utf-8"))
                except (PortableError, UnicodeError):
                    self._picker_program = None

    def _open(self, project, destination):
        if not project.available:
            raise PortableError("The project folder is unavailable.", "项目目录不可用。")
        if destination in ("file_manager", "explorer"):
            try:
                os.startfile(project.path)
            except OSError as error:
                raise PortableError("Could not open the project in the file manager.", "无法在文件管理器中打开项目。") from error
            return
        if destination != "vscode":
            raise PortableError("Unsupported application.", "不支持该应用。")
        executable = shutil.which("code")
        if executable is None:
            directories = (os.environ.get("LOCALAPPDATA"), os.environ.get("ProgramFiles"))
            candidates = [
                Path(directory) / suffix
                for directory, suffix in zip(directories, ("Programs/Microsoft VS Code/Code.exe", "Microsoft VS Code/Code.exe"))
                if directory
            ]
            executable = next((str(candidate) for candidate in candidates if candidate.is_file()), None)
        if executable is None:
            raise PortableError("Visual Studio Code is unavailable. Enable its `code` command on PATH.", "找不到 Visual Studio Code。请将 `code` 命令加入 PATH。")
        try:
            command, program, environment = program_invocation(executable, (str(project.path),))
            self._launch_view(command, executable=program, environment=environment)
        except OSError as error:
            raise PortableError("Could not open the project in Visual Studio Code.", "无法在 Visual Studio Code 中打开项目。") from error

    @staticmethod
    def _launch_view(command, *, executable=None, environment=None):
        process = subprocess.Popen(
            command, executable=executable, env={**os.environ, **(environment or {})},
            creationflags=subprocess.CREATE_NO_WINDOW,
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        threading.Thread(target=process.wait, daemon=True).start()

    def _start(self, project, task, locale):
        key = (project.id, task.id)
        if self._active(*key) or task.id in project.retired:
            return
        if not project.available:
            raise PortableError("The project folder is unavailable.", "项目目录不可用。")
        project.selected_task = task.id
        run = self.runs[key] = Run(locale)
        run.append(f"$ {task.command}\n")
        debug = None
        try:
            cwd = absolute_directory(task.cwd)
            root = absolute_directory(project.path)
            if cwd is None or root is None or not cwd.is_relative_to(root):
                raise PortableError("The working directory is unavailable or outside the project.", "工作目录不可用或不在项目内。")
            if task.configured_command is not None:
                command, executable = cmd_invocation(task.configured_command)
                environment = {}
            else:
                arguments = task.arguments
                if task.gradle_debug:
                    debug = tempfile.TemporaryDirectory(prefix="codex-script-manager-")
                    init_script = Path(debug.name) / "debug.gradle"
                    init_script.write_text(
                        "allprojects {\n"
                        "    tasks.withType(org.gradle.api.tasks.JavaExec).matching { it.name == 'bootRun' }.all {\n"
                        f"        jvmArgs '{DEBUG_OPTION}'\n"
                        "    }\n"
                        "}\n",
                        encoding="utf-8",
                    )
                    arguments += ("--init-script", str(init_script))
                command, executable, environment = program_invocation(task.executable, arguments)
            if executable and is_unc(cwd):
                raise PortableError(
                    "Command Prompt requires a local drive for the working directory.",
                    "命令提示符的工作目录需要位于本地磁盘。",
                )
            run.tree = ProcessTree(command, executable, environment, cwd)
        except (OSError, PortableError, ValueError) as error:
            if debug is not None:
                self._remove_debug_configuration(debug)
            run.status = "failed"
            message = translate(locale, str(error), error.chinese) if isinstance(error, PortableError) else str(error)
            run.append(translate(locale, "[Launch failed] ", "[启动失败] ") + message + "\n")
            return
        thread = threading.Thread(target=self._watch, args=(key, run, debug), daemon=True)
        thread.start()

    @staticmethod
    def _remove_debug_configuration(debug):
        try:
            debug.cleanup()
        except OSError:
            pass

    def _watch(self, key, run, debug):
        tree = run.tree
        reader = threading.Thread(target=self._read_output, args=(run, tree.process.stdout), daemon=True)
        reader.start()
        try:
            code = tree.wait()
        except OSError:
            code = 1
        reader.join(timeout=1)
        if debug is not None:
            self._remove_debug_configuration(debug)
        with self._lock:
            stopping = run.status == "stopping"
            run.code, run.tree = code, None
            run.status = "stopped" if stopping else "failed" if code else "succeeded"
            ended = (
                translate(run.locale, f"Stopped with exit code {code}", f"已停止，退出码 {code}") if stopping
                else translate(run.locale, f"Exited with code {code}", f"已退出，退出码 {code}")
            )
            run.append(f"\n[{ended}]\n")
            project = self.projects.get(key[0])
            if project is not None and key[1] in project.retired:
                project.retired.remove(key[1])
                project.tasks.pop(key[1], None)
                self.runs.pop(key, None)
                if project.selected_task == key[1]:
                    project.selected_task = next(iter(project.tasks), None)

    def _read_output(self, run, output):
        with output:
            while data := output.read1(8192):
                with self._lock:
                    if run.status not in ACTIVE:
                        break
                    run.append(data)

    def _stop(self, project, task):
        run = self.runs.get((project.id, task.id))
        if run is None or run.status != "running":
            return
        run.status = "stopping"
        run.append(translate(run.locale, "\n[Stopping]\n", "\n[正在停止]\n"))
        run.tree.terminate()

    def _snapshot(self, project, task_id, locale):
        rows = []
        tasks = []
        selected, log = None, ""
        for item in self.projects.values():
            task_rows = []
            for task in item.tasks.values():
                run = self.runs.get((item.id, task.id))
                status = status_row(locale, run.status, run.code) if run else status_row(locale, "idle")
                task_rows.append({**task.row(), **status})
            row = {
                "id": item.id, "name": item.name, "path": str(item.path), "source": item.source,
                "pinned": item.pinned, "available": item.available, "scanning": item.scan is not None,
                "tasks": task_rows, "activeCount": sum(task["active"] for task in task_rows),
            }
            if item.config_error is not None:
                row["commandConfigError"] = item.config_error.localized(locale)
            if project is item:
                tasks = task_rows
                candidate = task_id or item.selected_task
                if candidate in item.tasks:
                    selected = candidate
                    run = self.runs.get((item.id, selected))
                    log = run.output(locale) if run else ""
            rows.append(row)
        return {
            "schemaVersion": 2, "supportsCustomCommands": True, "projects": rows,
            "selectedProjectId": self.selected_project, "projectId": project.id if project else None,
            "tasks": tasks, "selectedTaskId": selected, "log": log, "pickPending": self._picker is not None,
            "usesPathPicker": self._picker_program is None, "platform": "windows", "fileManager": "explorer",
        }

    def call(self, method, arguments):
        with self._lock:
            if self._closed:
                raise PortableError("Script Manager has quit.", "脚本管理器已退出。")
            self._sync_projects(force=method == "refresh")
            self._collect_scans()
            project_id, task_id, locale = (arguments.get(key) for key in ("projectId", "taskId", "locale"))
            project = self.projects.get(project_id)
            if project is None and (method in ("open", "start", "stop") or (method == "refresh" and project_id)):
                raise PortableError("This project is not open.", "该项目尚未打开。")
            if method == "choose":
                self._choose(locale)
            elif method == "add":
                project = self._add(arguments.get("path"))
            elif method == "refresh":
                projects = [project] if project is not None else self.projects.values()
                for item in projects:
                    self._scan(item)
            elif method == "open":
                self._open(project, arguments.get("destination"))
            elif method in ("start", "stop"):
                task = project.tasks.get(task_id)
                if task is None:
                    raise PortableError("Script not found in this project. Rescan the project.", "该项目中找不到脚本。请重新扫描。")
                if method == "start":
                    self._start(project, task, locale)
                else:
                    self._stop(project, task)
            elif method != "snapshot":
                raise PortableError("Unknown Script Manager operation.", "未知的脚本管理操作。")
            return self._snapshot(project or self.projects.get(self.selected_project), task_id, locale)

    def close(self):
        with self._lock:
            if self._closed:
                return
            self._closed = True
            trees = [run.tree for run in self.runs.values() if run.tree is not None]
            if self._picker is not None:
                self._picker.kill()
        self._scanner.shutdown(wait=False, cancel_futures=True)
        for tree in trees:
            tree.terminate()
