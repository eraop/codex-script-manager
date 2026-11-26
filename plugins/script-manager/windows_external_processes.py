import ctypes
from ctypes import wintypes
from contextlib import contextmanager
from functools import lru_cache
import ntpath
import os
from pathlib import Path
import struct


PROCESS_TERMINATE = 0x0001
PROCESS_VM_READ = 0x0010
PROCESS_DUP_HANDLE = 0x0040
PROCESS_QUERY_INFORMATION = 0x0400
SYNCHRONIZE = 0x00100000
PROCESS_INSPECT = PROCESS_QUERY_INFORMATION | PROCESS_VM_READ | SYNCHRONIZE
TOKEN_QUERY = 0x0008
TOKEN_USER = 1
TH32CS_SNAPPROCESS = 0x00000002
ERROR_NO_MORE_FILES = 18
WAIT_TIMEOUT = 258
INVALID_HANDLE_VALUE = ctypes.c_void_p(-1).value
POINTER_SIZE = ctypes.sizeof(ctypes.c_void_p)

SHELLS = {
    "bash", "cmd", "csh", "dash", "fish", "ksh", "mintty", "nu", "powershell", "powershell_ise", "pwsh",
    "sh", "ssh", "tcsh", "wsl", "wslhost", "zsh",
}
APPS = {
    "chatgpt", "chrome_crashpad_handler", "code", "code - insiders", "codex", "codex-app-server",
    "codex-x86_64-pc-windows-msvc", "codex-aarch64-pc-windows-msvc", "codexscriptmanager", "conhost", "cursor",
    "devenv", "electron", "explorer", "goland64", "idea64", "openconsole", "pycharm64", "rider64", "rustrover64",
    "taskmgr", "webstorm64", "windowsterminal", "windsurf", "zed",
}
MACHINE_POINTER_SIZE = {
    0x014C: 4,  # I386
    0x01C4: 4,  # ARMNT
    0x8664: 8,  # AMD64
    0xAA64: 8,  # ARM64
    0xA641: 8,  # ARM64EC
    0xA64E: 8,  # ARM64X
}


class ExternalProcessError(Exception):
    def __init__(self, english, chinese):
        super().__init__(english)
        self.chinese = chinese


def _unavailable():
    return ExternalProcessError("The external process is no longer accessible in this project.",
                                "此外部进程已不在此项目中运行或无法访问。")


class _ProcessEntry(ctypes.Structure):
    _fields_ = [
        ("size", wintypes.DWORD), ("usage", wintypes.DWORD), ("pid", wintypes.DWORD),
        ("heap", ctypes.c_size_t), ("module", wintypes.DWORD), ("thread_count", wintypes.DWORD),
        ("parent", wintypes.DWORD), ("priority", wintypes.LONG), ("flags", wintypes.DWORD),
        ("executable", wintypes.WCHAR * 260),
    ]


class _ProcessBasicInformation(ctypes.Structure):
    _fields_ = [
        ("reserved", ctypes.c_void_p), ("peb", ctypes.c_void_p), ("reserved2", ctypes.c_void_p * 2),
        ("pid", ctypes.c_size_t), ("reserved3", ctypes.c_void_p),
    ]


def _absolute_path(value):
    value = os.fspath(value).replace("/", "\\")
    if value[:8].casefold() == "\\\\?\\unc\\":
        value = "\\\\" + value[8:]
    elif value.startswith("\\\\?\\"):
        value = value[4:]
    if "\0" in value or value.startswith("\\\\.\\"):
        return None
    drive, remainder = ntpath.splitdrive(value)
    if len(drive) == 2 and drive[0].isascii() and drive[0].isalpha() and drive[1] == ":":
        if not remainder.startswith("\\"):
            return None
        value = drive.upper() + remainder
    elif drive.startswith("\\\\") and (not remainder or remainder.startswith("\\")):
        parts = drive[2:].split("\\")
        if len(parts) != 2 or any(part in ("", ".", "..", "?") for part in parts):
            return None
        if parts[0].casefold() in ("wsl$", "wsl.localhost"):
            return None
    else:
        return None
    if any(part in (".", "..") for part in remainder.split("\\")):
        return None
    return ntpath.normpath(value)


def _canonical_directory(path):
    try:
        resolved = Path(path).resolve(strict=True)
        return _absolute_path(resolved) if resolved.is_dir() else None
    except (OSError, RuntimeError, ValueError):
        return None


def _inside(path, root):
    return path == root or path.startswith(root if root.endswith("\\") else root + "\\")


class _Scope:
    def __init__(self, roots, excluded_roots):
        self._roots = []
        self._hints = []
        for raw in roots:
            spelling = _absolute_path(raw)
            root = _canonical_directory(spelling) if spelling else None
            if root:
                self._roots.append(root)
                self._hints.extend((ntpath.normcase(spelling), ntpath.normcase(root)))
        self._excluded_roots = []
        for raw in excluded_roots:
            path = _absolute_path(raw)
            root = _canonical_directory(path) if path else None
            if root:
                self._excluded_roots.append(root)

    def directory(self, path):
        path = _absolute_path(path)
        # Limit filesystem lookups of remote process cwd strings to the selected project's paths.
        if not path or not any(_inside(ntpath.normcase(path), root) for root in self._hints):
            return None
        directory = _canonical_directory(path)
        if not directory:
            return None
        owner = max((len(root) for root in self._roots if _inside(directory, root)), default=0)
        if not owner or any(len(root) >= owner and _inside(directory, root) for root in self._excluded_roots):
            return None
        return directory


def _managed_tree(bases, entries):
    children = {}
    for pid, (parent, _) in entries.items():
        children.setdefault(parent, []).append(pid)
    managed = set(bases)
    pending = list(managed)
    while pending:
        for child in children.get(pending.pop(), ()):
            if child not in managed:
                managed.add(child)
                pending.append(child)
    return managed


def _executable_name(path):
    return ntpath.basename(path).casefold().removesuffix(".exe")


def _eligible(pid, entries, managed):
    if pid <= 4 or pid in (os.getpid(), os.getppid()) or pid in managed or pid not in entries:
        return False
    name = _executable_name(entries[pid][1])
    return bool(name and name not in APPS and name not in SHELLS)


def _bind(library, name, parameters, result):
    function = getattr(library, name)
    function.argtypes = parameters
    function.restype = result
    return function


class _WindowsAPI:
    def __init__(self):
        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        security = ctypes.WinDLL("advapi32", use_last_error=True)
        native = ctypes.WinDLL("ntdll", use_last_error=True)
        handle, dword, boolean = wintypes.HANDLE, wintypes.DWORD, wintypes.BOOL
        pointer, out_dword = ctypes.c_void_p, ctypes.POINTER(dword)
        out_bool = ctypes.POINTER(boolean)

        self.close = _bind(kernel, "CloseHandle", [handle], boolean)
        self.current_process = _bind(kernel, "GetCurrentProcess", [], handle)
        self.open = _bind(kernel, "OpenProcess", [dword, boolean, dword], handle)
        self.wait = _bind(kernel, "WaitForSingleObject", [handle, dword], dword)
        self.terminate = _bind(kernel, "TerminateProcess", [handle, wintypes.UINT], boolean)
        self.is_critical = _bind(kernel, "IsProcessCritical", [handle, out_bool], boolean)
        self.snapshot = _bind(kernel, "CreateToolhelp32Snapshot", [dword, dword], handle)
        entry = ctypes.POINTER(_ProcessEntry)
        self.first = _bind(kernel, "Process32FirstW", [handle, entry], boolean)
        self.next = _bind(kernel, "Process32NextW", [handle, entry], boolean)
        filetime = ctypes.POINTER(wintypes.FILETIME)
        self.times = _bind(kernel, "GetProcessTimes", [handle, filetime, filetime, filetime, filetime], boolean)
        self.query_image = _bind(kernel, "QueryFullProcessImageNameW", [handle, dword, wintypes.LPWSTR, out_dword], boolean)
        self.nt_query = _bind(native, "NtQueryInformationProcess", [handle, wintypes.ULONG, pointer, wintypes.ULONG, pointer],
                              wintypes.LONG)
        self.read_memory = _bind(kernel, "ReadProcessMemory", [handle, pointer, pointer, ctypes.c_size_t,
                                                               ctypes.POINTER(ctypes.c_size_t)], boolean)
        self.wow64 = _bind(kernel, "IsWow64Process", [handle, out_bool], boolean)
        self.wow64_2 = None
        if hasattr(kernel, "IsWow64Process2"):
            word = ctypes.POINTER(wintypes.USHORT)
            self.wow64_2 = _bind(kernel, "IsWow64Process2", [handle, word, word], boolean)

        self.open_token = _bind(security, "OpenProcessToken", [handle, dword, ctypes.POINTER(handle)], boolean)
        self.token_information = _bind(security, "GetTokenInformation", [handle, ctypes.c_int, pointer, dword, out_dword],
                                       boolean)
        self.valid_sid = _bind(security, "IsValidSid", [pointer], boolean)
        self.sid_length = _bind(security, "GetLengthSid", [pointer], dword)

    def entries(self):
        snapshot = self.snapshot(TH32CS_SNAPPROCESS, 0)
        if not snapshot or snapshot == INVALID_HANDLE_VALUE:
            raise _unavailable()
        try:
            entry = _ProcessEntry()
            entry.size = ctypes.sizeof(entry)
            entries = {}
            found = self.first(snapshot, ctypes.byref(entry))
            while found:
                entries[entry.pid] = (entry.parent, entry.executable)
                found = self.next(snapshot, ctypes.byref(entry))
            if ctypes.get_last_error() != ERROR_NO_MORE_FILES:
                raise _unavailable()
            return entries
        finally:
            self.close(snapshot)

    def sid(self, process):
        token = wintypes.HANDLE()
        if not self.open_token(process, TOKEN_QUERY, ctypes.byref(token)):
            return None
        try:
            length = wintypes.DWORD()
            self.token_information(token, TOKEN_USER, None, 0, ctypes.byref(length))
            if not POINTER_SIZE <= length.value <= 4096:
                return None
            data = ctypes.create_string_buffer(length.value)
            if not self.token_information(token, TOKEN_USER, data, len(data), ctypes.byref(length)):
                return None
            sid = ctypes.c_void_p.from_buffer(data).value
            start = ctypes.addressof(data)
            if sid is None or not start <= sid <= start + len(data) - 8:
                return None
            if not self.valid_sid(sid):
                return None
            size = self.sid_length(sid)
            return ctypes.string_at(sid, size) if 8 <= size and sid + size <= start + len(data) else None
        finally:
            self.close(token)

    def creation_time(self, process):
        creation, exit_time, kernel, user = (wintypes.FILETIME() for _ in range(4))
        if not self.times(process, *(ctypes.byref(value) for value in (creation, exit_time, kernel, user))):
            return None
        return (creation.dwHighDateTime << 32) | creation.dwLowDateTime

    def image(self, process):
        size = wintypes.DWORD(32768)
        buffer = ctypes.create_unicode_buffer(size.value)
        if not self.query_image(process, 0, buffer, ctypes.byref(size)):
            return None
        return buffer.value

    def pointer_size(self, process):
        if self.wow64_2 is not None:
            target, native = wintypes.USHORT(), wintypes.USHORT()
            if self.wow64_2(process, ctypes.byref(target), ctypes.byref(native)):
                return MACHINE_POINTER_SIZE.get(target.value or native.value)
            return None

        target_wow = wintypes.BOOL()
        if not self.wow64(process, ctypes.byref(target_wow)):
            return None
        if POINTER_SIZE == 8:
            return 4 if target_wow.value else 8
        caller_wow = wintypes.BOOL()
        if self.wow64(self.current_process(), ctypes.byref(caller_wow)) and bool(caller_wow.value) == bool(target_wow.value):
            return 4
        return None

    def _peb(self, process, width):
        if width == POINTER_SIZE:
            info = _ProcessBasicInformation()
            status = self.nt_query(process, 0, ctypes.byref(info), ctypes.sizeof(info), None)
            return info.peb if status >= 0 else None
        if width == 4 and POINTER_SIZE == 8:
            peb = ctypes.c_size_t()
            status = self.nt_query(process, 26, ctypes.byref(peb), ctypes.sizeof(peb), None)
            return peb.value if status >= 0 else None
        return None

    def _read(self, process, address, size, width):
        address_limit = (1 << 32) if width == 4 else (1 << 63)
        if not 0x10000 <= address <= address_limit - size:
            return None
        buffer = ctypes.create_string_buffer(size)
        count = ctypes.c_size_t()
        if not self.read_memory(process, address, buffer, size, ctypes.byref(count)) or count.value != size:
            return None
        return buffer.raw

    def parameters(self, process, *, logs):
        width = self.pointer_size(process)
        peb = self._peb(process, width)
        if not peb or peb % width:
            return None

        # Read only PEB.ProcessParameters and the current-directory and optional stdio fields.
        # The x86/ARM32 and 64-bit layouts use different offsets and pointer alignment.
        parameters_slot = peb + (0x20 if width == 8 else 0x10)
        cwd_offset, std_offset = (0x38, 0x28) if width == 8 else (0x24, 0x1C)
        parameter_pointer = self._read(process, parameters_slot, width, width)
        if parameter_pointer is None:
            return None
        parameters = int.from_bytes(parameter_pointer, "little")
        if parameters % width:
            return None
        header = self._read(process, parameters, 12, width)
        if header is None:
            return None
        capacity, length, flags = struct.unpack("<III", header)
        if not cwd_offset + width * 3 <= length <= capacity or not flags & 1:
            return None
        cwd_slot = parameters + cwd_offset
        cwd = self._read(process, cwd_slot, width * 2, width)
        if cwd is None:
            return None
        size, capacity = struct.unpack_from("<HH", cwd)
        address = int.from_bytes(cwd[width:], "little")
        if not 0 < size <= capacity or size % 2 or capacity % 2 or address % 2:
            return None
        data = self._read(process, address, size, width)
        if data is None or data != self._read(process, address, size, width):
            return None
        try:
            directory = data.decode("utf-16-le", errors="strict")
        except UnicodeError:
            return None

        handles = (None, None)
        if logs:
            output = self._read(process, parameters + std_offset, width * 2, width)
            if output is not None:
                handles = tuple(_stream_handle(output[offset:offset + width]) for offset in (0, width))
        if cwd != self._read(process, cwd_slot, width * 2, width) or parameter_pointer != self._read(
            process, parameters_slot, width, width
        ):
            return None
        return directory, handles


def _stream_handle(raw):
    value = int.from_bytes(raw, "little")
    # Exclude null handles, pseudo handles and legacy tagged console handles.
    return value if 0 < value < (1 << (len(raw) * 8 - 1)) and value % 4 == 0 else None


@lru_cache(maxsize=1)
def _api():
    if os.name != "nt":
        raise ExternalProcessError("External Windows processes require native Windows.", "此外部进程功能仅支持原生 Windows。")
    try:
        return _WindowsAPI()
    except (OSError, AttributeError) as error:
        raise ExternalProcessError("Windows process inspection is unavailable.", "当前无法检查 Windows 进程。") from error


def _inspect(api, handle, pid, user, entries, scope, *, logs):
    if api.wait(handle, 0) != WAIT_TIMEOUT or api.sid(handle) != user:
        return None
    creation = api.creation_time(handle)
    image = api.image(handle)
    name = _executable_name(image or entries[pid][1])
    if not creation or not name or name in SHELLS or name in APPS:
        return None
    parameters = api.parameters(handle, logs=logs)
    if parameters is None:
        return None
    directory = scope.directory(parameters[0])
    if directory is None or api.wait(handle, 0) != WAIT_TIMEOUT:
        return None

    parent = entries.get(entries[pid][0])
    direct_app_child = parent is not None and _executable_name(parent[1]) in APPS
    critical = wintypes.BOOL()
    can_stop = bool(image and not direct_app_child and api.is_critical(handle, ctypes.byref(critical)) and not critical.value)
    record = {"id": f"{pid}:{creation}", "pid": pid, "name": ntpath.basename(image or entries[pid][1]),
              "directory": directory, "canStop": can_stop, "streams": []}
    if logs:
        record["handles"] = parameters[1]
    return record


def scan(roots, excluded_roots, managed_pids, *, log_sources=None):
    api = _api()
    user = api.sid(api.current_process())
    if user is None:
        raise _unavailable()
    scope = _Scope(roots, excluded_roots)
    if not scope._roots:
        return []
    entries = api.entries()
    managed = _managed_tree(managed_pids, entries)
    rows = []
    for pid in sorted(entries):
        if not _eligible(pid, entries, managed):
            continue
        logs = log_sources is not None
        handle = api.open(PROCESS_INSPECT | (PROCESS_DUP_HANDLE if logs else 0), False, pid)
        if not handle and logs:
            logs = False
            handle = api.open(PROCESS_INSPECT, False, pid)
        if not handle:
            continue
        try:
            record = _inspect(api, handle, pid, user, entries, scope, logs=logs)
            if record is None:
                continue
            if record["canStop"]:
                stop_access = api.open(PROCESS_TERMINATE, False, pid)
                record["canStop"] = bool(stop_access)
                if stop_access:
                    api.close(stop_access)
            if logs:
                handles = record.pop("handles")
                try:
                    record["streams"] = log_sources(handle, handles)
                except OSError:
                    pass
            rows.append(record)
        finally:
            api.close(handle)
    return rows


@contextmanager
def open_verified(process_id, roots, excluded_roots, managed_pids, *, terminate=False, logs=False):
    try:
        pid_text, creation = process_id.split(":")
        pid = int(pid_text)
        if (not creation.isascii() or not creation.isdecimal() or not 4 < pid <= 0xFFFFFFFF
                or pid_text != str(pid) or pid in (os.getpid(), os.getppid())):
            raise ValueError
    except (AttributeError, ValueError):
        raise _unavailable() from None

    api = _api()
    user = api.sid(api.current_process())
    if user is None:
        raise _unavailable()
    access = PROCESS_INSPECT | (PROCESS_TERMINATE if terminate else 0) | (PROCESS_DUP_HANDLE if logs else 0)
    handle = api.open(access, False, pid)
    if not handle:
        raise _unavailable()
    try:
        entries = api.entries()
        if not _eligible(pid, entries, _managed_tree(managed_pids, entries)):
            raise _unavailable()
        record = _inspect(api, handle, pid, user, entries, _Scope(roots, excluded_roots), logs=logs)
        if record is None or record["id"] != process_id:
            raise _unavailable()
        if terminate and not record["canStop"]:
            raise ExternalProcessError("Script Manager could not verify that this process can be stopped.",
                                       "脚本管理无法确认能否停止此进程。")
        yield record, handle
    finally:
        api.close(handle)


def stop(process_id, roots, excluded_roots, managed_pids):
    with open_verified(process_id, roots, excluded_roots, managed_pids, terminate=True) as (_, handle):
        if not _api().terminate(handle, 1):
            code = ctypes.get_last_error()
            raise ExternalProcessError(f"Could not stop the external process (Windows error {code}).",
                                       f"无法停止外部进程（Windows 错误 {code}）。")
