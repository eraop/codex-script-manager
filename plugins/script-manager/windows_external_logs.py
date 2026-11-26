from contextlib import contextmanager
import codecs
import ctypes
from ctypes import wintypes
from functools import lru_cache
from pathlib import PureWindowsPath
import sys


MAX_TAIL_BYTES = 65_536
_INVALID_HANDLE = wintypes.HANDLE(-1).value
_DUPLICATE_SAME_ACCESS = 0x0002
_FILE_TYPE_DISK = 0x0001
_GENERIC_READ = 0x80000000
_FILE_SHARE_READ_WRITE_DELETE = 0x0007
_FILE_NAME_OPENED = 0x0008
_FILE_STANDARD_INFO = 1
_FILE_ID_INFO = 18
_FILE_BEGIN = 0
_ERROR_HANDLE_EOF = 38
_STREAM_NAMES = ("stdout", "stderr")
_ENCODINGS = (
    (codecs.BOM_UTF32_LE, "utf-32-le", 4),
    (codecs.BOM_UTF32_BE, "utf-32-be", 4),
    (codecs.BOM_UTF16_LE, "utf-16-le", 2),
    (codecs.BOM_UTF16_BE, "utf-16-be", 2),
    (codecs.BOM_UTF8, "utf-8", 1),
)


class ExternalLogError(Exception):
    def __init__(self, english, chinese):
        super().__init__(english)
        self.chinese = chinese


class _FileStandardInfo(ctypes.Structure):
    _fields_ = [
        ("allocation_size", ctypes.c_int64),
        ("size", ctypes.c_int64),
        ("links", ctypes.c_uint32),
        ("delete_pending", ctypes.c_ubyte),
        ("directory", ctypes.c_ubyte),
    ]


class _FileIdInfo(ctypes.Structure):
    _fields_ = [
        ("volume", ctypes.c_uint64),
        ("file_id", ctypes.c_ubyte * 16),
    ]


@lru_cache(maxsize=1)
def _api():
    if sys.platform != "win32":
        raise ExternalLogError("External logs require native Windows.", "外部日志需要原生 Windows。")
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    handle, dword, boolean = wintypes.HANDLE, wintypes.DWORD, wintypes.BOOL
    kernel.GetCurrentProcess.argtypes = []
    kernel.GetCurrentProcess.restype = handle
    kernel.DuplicateHandle.argtypes = [
        handle, handle, handle, ctypes.POINTER(handle), dword, boolean, dword,
    ]
    kernel.DuplicateHandle.restype = boolean
    kernel.GetFileType.argtypes = [handle]
    kernel.GetFileType.restype = dword
    kernel.GetFileInformationByHandleEx.argtypes = [handle, ctypes.c_int, ctypes.c_void_p, dword]
    kernel.GetFileInformationByHandleEx.restype = boolean
    kernel.ReOpenFile.argtypes = [handle, dword, dword, dword]
    kernel.ReOpenFile.restype = handle
    kernel.GetFinalPathNameByHandleW.argtypes = [handle, wintypes.LPWSTR, dword, dword]
    kernel.GetFinalPathNameByHandleW.restype = dword
    kernel.SetFilePointerEx.argtypes = [handle, ctypes.c_int64, ctypes.POINTER(ctypes.c_int64), dword]
    kernel.SetFilePointerEx.restype = boolean
    kernel.ReadFile.argtypes = [handle, ctypes.c_void_p, dword, ctypes.POINTER(dword), ctypes.c_void_p]
    kernel.ReadFile.restype = boolean
    kernel.CloseHandle.argtypes = [handle]
    kernel.CloseHandle.restype = boolean
    return kernel


def _disk_file_info(api, file):
    if api.GetFileType(file) != _FILE_TYPE_DISK:
        return None
    info = _FileStandardInfo()
    if not api.GetFileInformationByHandleEx(file, _FILE_STANDARD_INFO, ctypes.byref(info), ctypes.sizeof(info)):
        return None
    return info if not info.directory and not info.delete_pending and info.size >= 0 else None


def _file_identity(api, file):
    info = _FileIdInfo()
    if not api.GetFileInformationByHandleEx(file, _FILE_ID_INFO, ctypes.byref(info), ctypes.sizeof(info)):
        return None
    identifier = bytes(info.file_id)
    return f"{info.volume:x}:{identifier.hex()}" if any(identifier) else None


def _file_label(api, file):
    buffer = ctypes.create_unicode_buffer(260)
    length = api.GetFinalPathNameByHandleW(file, buffer, len(buffer), _FILE_NAME_OPENED)
    if len(buffer) <= length <= 32_768:
        buffer = ctypes.create_unicode_buffer(length)
        length = api.GetFinalPathNameByHandleW(file, buffer, len(buffer), _FILE_NAME_OPENED)
    if length == 0 or length >= len(buffer):
        return None
    path = buffer.value
    if path.startswith("\\\\?\\UNC\\"):
        path = "\\\\" + path[8:]
    elif path.startswith("\\\\?\\"):
        path = path[4:]
    path = PureWindowsPath(path)
    if not path.is_absolute() or path.drive.startswith("\\\\.\\") or ":" in path.name:
        return None
    return path.name or None


@contextmanager
def _open_source(api, process_handle, source_handle):
    duplicate = wintypes.HANDLE()
    if not source_handle or source_handle == _INVALID_HANDLE or not api.DuplicateHandle(
        process_handle, source_handle, api.GetCurrentProcess(), ctypes.byref(duplicate),
        0, False, _DUPLICATE_SAME_ACCESS,
    ):
        yield None
        return

    file = None
    try:
        identity = _file_identity(api, duplicate) if _disk_file_info(api, duplicate) else None
        if identity is None:
            yield None
            return

        # A duplicated handle shares the original file position. Reopen for an independent reader.
        file = api.ReOpenFile(duplicate, _GENERIC_READ, _FILE_SHARE_READ_WRITE_DELETE, 0)
        if not file or file == _INVALID_HANDLE:
            yield None
            return

        info = _disk_file_info(api, file)
        label = _file_label(api, file)
        if info and label and _file_identity(api, file) == identity:
            yield file, identity, label, info.size
        else:
            yield None
    finally:
        if file and file != _INVALID_HANDLE:
            api.CloseHandle(file)
        api.CloseHandle(duplicate)


def _read_at(api, file, offset, length):
    if not length:
        return b""
    if api.SetFilePointerEx(file, offset, None, _FILE_BEGIN):
        buffer = ctypes.create_string_buffer(length)
        count = wintypes.DWORD()
        if api.ReadFile(file, buffer, length, ctypes.byref(count), None):
            return buffer.raw[:count.value]
        if ctypes.get_last_error() == _ERROR_HANDLE_EOF:
            return b""
    raise ExternalLogError("Could not read the external log file.", "无法读取外部日志文件。")


def _tail(api, file, size):
    prefix = _read_at(api, file, 0, min(4, size))
    bom, encoding, width = next(
        ((bom, encoding, width) for bom, encoding, width in _ENCODINGS if prefix.startswith(bom)),
        (b"", "utf-8", 1),
    )
    offset = max(len(bom), size - MAX_TAIL_BYTES)
    offset += (len(bom) - offset) % width
    data = _read_at(api, file, offset, max(0, size - offset))
    if encoding == "utf-8" and offset > len(bom):
        skip = 0
        while skip < min(3, len(data)) and data[skip] & 0xC0 == 0x80:
            skip += 1
        data = data[skip:]
    return data.decode(encoding, "replace")


def sources(process_handle, std_handles):
    api = _api()
    entries = []
    seen = set()
    for stream, source_handle in zip(_STREAM_NAMES, std_handles):
        with _open_source(api, process_handle, source_handle) as source:
            if source:
                _, identity, label, _ = source
                if identity not in seen:
                    seen.add(identity)
                    entries.append({"id": f"{stream}:{identity}", "label": label})
    return entries


def read(process_handle, std_handles, source_id):
    api = _api()
    stream_id, _, requested_identity = source_id.partition(":")
    for stream, source_handle in zip(_STREAM_NAMES, std_handles):
        if stream == stream_id:
            with _open_source(api, process_handle, source_handle) as source:
                if source:
                    file, identity, _, size = source
                    if identity == requested_identity:
                        return _tail(api, file, size)
            break
    raise ExternalLogError("This log file is no longer available. Refresh the process list.",
                           "该日志文件已不可用，请刷新进程列表。")
