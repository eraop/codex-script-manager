import base64
import ctypes
import errno
from functools import lru_cache
import json
import os
from pathlib import Path
import socket
import stat
import subprocess
import sys
import time

import portable_bridge
import repair


PLUGIN_DIR = Path(__file__).resolve().parent
APP_PATH = PLUGIN_DIR / "assets" / "Codex Script Manager.app"
APP_EXECUTABLE = APP_PATH / "Contents" / "MacOS" / "CodexScriptManager"
SOCKET_DIR_ENV = "CODEX_SCRIPT_MANAGER_SOCKET_DIR"
RESOURCE_URI = "ui://script-manager/index.html"
RESOURCE_MIME = "text/html;profile=mcp-app"
ENTRY_TOOL = "script_manager"
OPEN_FLOATING_WINDOW_TOOL = f"{ENTRY_TOOL}_open_floating_window"
MANIFEST = json.loads((PLUGIN_DIR / "plugin.json").read_text(encoding="utf-8"))
INTERFACE = MANIFEST["extensions"]["com.openai"]["interface"]
APP_TITLE = INTERFACE["displayName"]
PROTOCOL_VERSION = "2025-11-25"
SUPPORTED_VERSIONS = {PROTOCOL_VERSION, "2025-06-18", "2025-03-26"}
MAX_REQUEST_SIZE = 16 * 1024
MAX_RESPONSE_SIZE = 8 * 1024 * 1024
WINDOWS = sys.platform == "win32"
OPEN_DESTINATIONS = ("file_manager" if WINDOWS else "finder", "vscode")
ICON_ASSETS = {
    theme: (PLUGIN_DIR / INTERFACE[field]).read_bytes()
    for field, theme in (("logo", "light"), ("logoDark", "dark"))
}


def encode_icon(svg):
    return {
        "src": "data:image/svg+xml;base64," + base64.b64encode(svg).decode("ascii"),
        "mimeType": "image/svg+xml",
        "sizes": ["48x48"],
    }


def encode_icons(assets):
    return [{**encode_icon(svg), "theme": theme} for theme, svg in assets.items()]


BRAND_ICONS = encode_icons(ICON_ASSETS)
SIDEBAR_ICONS = encode_icons({
    theme: svg.replace(b'viewBox="0 0 24 24"', b'viewBox="-2 -2 28 28"', 1)
    for theme, svg in ICON_ASSETS.items()
})
OPERATIONS = {
    "snapshot": ("Read projects, task status, and logs.", ("projectId", "taskId"), ()),
    "choose": ("Open the local project folder picker.", (), ()),
    "refresh": ("Rescan all projects or a single project.", ("projectId",), ()),
    "add_command": ("Save a discovered command suggestion to the selected project folder.",
                    ("projectId", "rootPath", "candidateId"), ("projectId", "rootPath", "candidateId")),
    "open": ("Open a known project in the file manager or Visual Studio Code.", ("projectId", "destination"), ("projectId", "destination")),
    "start": ("Start a script discovered in the project.", ("projectId", "taskId"), ("projectId", "taskId")),
    "stop": ("Stop a task managed by Script Manager.", ("projectId", "taskId"), ("projectId", "taskId")),
    "ai_fix": ("Open a Codex draft to diagnose a script failure.", ("projectId", "taskId"), ("projectId", "taskId")),
}
if WINDOWS:
    OPERATIONS["add"] = ("Add a local project folder by its absolute path.", ("path",), ("path",))
RESOURCE = {"uri": RESOURCE_URI, "name": APP_TITLE, "mimeType": RESOURCE_MIME}


class RpcError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


class BridgeError(Exception):
    def __init__(self, english, chinese=None):
        super().__init__(english)
        self.chinese = chinese or english

    def localized(self, locale):
        return translate(locale, str(self), self.chinese)


def translate(locale, english, chinese):
    language = locale.replace("_", "-").partition("-")[0].lower() if isinstance(locale, str) else ""
    return chinese if language == "zh" else english


def object_schema(properties=(), required=()):
    result = {
        "type": "object",
        "properties": {name: {"type": "string", "minLength": 1, "maxLength": 8192} for name in properties},
        "additionalProperties": False,
    }
    if required:
        result["required"] = list(required)
    return result


def tools():
    sidebar = {"type": "global"}
    if sys.platform == "darwin":
        sidebar["quickAction"] = {
            "title": "打开浮窗",
            "icons": [encode_icon((PLUGIN_DIR / "assets" / "floating-window.svg").read_bytes())],
            "target": {"type": "tool", "name": OPEN_FLOATING_WINDOW_TOOL, "arguments": {}},
        }
    yield {
        "name": ENTRY_TOOL,
        "title": APP_TITLE,
        "description": "Open Script Manager for local macOS or Windows projects.",
        "inputSchema": object_schema(),
        "annotations": {"readOnlyHint": True, "openWorldHint": False},
        "icons": SIDEBAR_ICONS,
        "_meta": {
            "ui": {"resourceUri": RESOURCE_URI},
            "openai/ui": {"entrypoints": [sidebar, {"type": "thread"}]},
        },
    }
    if sys.platform == "darwin":
        schema = object_schema(("projectId",))
        schema["properties"]["locale"] = {"type": "string", "enum": ["en", "zh-CN"]}
        yield {
            "name": OPEN_FLOATING_WINDOW_TOOL,
            "description": "Bring the macOS Script Manager floating window forward.",
            "inputSchema": schema,
            "annotations": {"readOnlyHint": True, "openWorldHint": False},
            "_meta": {"ui": {"visibility": ["app"]}},
        }
    for name, (description, properties, required) in OPERATIONS.items():
        schema = object_schema(properties, required)
        schema["properties"]["locale"] = {"type": "string", "enum": ["en", "zh-CN"]}
        if name == "open":
            schema["properties"]["destination"] = {"type": "string", "enum": list(OPEN_DESTINATIONS)}
        yield {
            "name": f"{ENTRY_TOOL}_{name}",
            "description": description,
            "inputSchema": schema,
            "annotations": {"readOnlyHint": name == "snapshot", "destructiveHint": name == "stop",
                            **({"idempotentHint": True} if name == "add_command" else {})},
            "_meta": {"ui": {"resourceUri": RESOURCE_URI, "visibility": ["app"]}},
        }


def tool_result(text, *, data=None, error=False):
    result = {"content": [{"type": "text", "text": text}]}
    if data is not None:
        result["structuredContent"] = data
    if error:
        result["isError"] = True
    return result


def connect_private_socket(path):
    uid = os.getuid()
    directory = path.parent.lstat()
    if not stat.S_ISDIR(directory.st_mode) or directory.st_uid != uid or stat.S_IMODE(directory.st_mode) != 0o700:
        raise BridgeError("The Script Manager socket directory has invalid permissions.", "本地脚本管理的通信目录权限无效。")
    endpoint = path.lstat()
    if not stat.S_ISSOCK(endpoint.st_mode) or endpoint.st_uid != uid or stat.S_IMODE(endpoint.st_mode) != 0o600:
        raise BridgeError("The Script Manager socket has invalid permissions.", "本地脚本管理的通信套接字权限无效。")
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(3)
    try:
        client.connect(os.fspath(path))
    except OSError:
        client.close()
        raise
    return client


def launch_bridge(socket_dir_override):
    if sys.platform != "darwin":
        raise BridgeError("Script Manager requires macOS.", "脚本管理需要在 macOS 上运行。")
    if not APP_EXECUTABLE.is_file():
        raise BridgeError("The native Script Manager app is missing. Rebuild and reinstall the plugin.", "插件包内缺少脚本管理应用。请重新构建并安装插件。")
    command = ["/usr/bin/open", "-g", "-j", "-a", str(APP_PATH)]
    if socket_dir_override:
        command.extend(["--env", f"{SOCKET_DIR_ENV}={socket_dir_override}"])
    codex_home = os.environ.get("CODEX_HOME")
    if codex_home and Path(codex_home).is_absolute():
        command.extend(["--env", f"CODEX_HOME={codex_home}"])
    command.extend(["--args", "--mcp-bridge"])
    try:
        subprocess.run(command, stdin=subprocess.DEVNULL, capture_output=True, timeout=3, check=True)
    except (OSError, subprocess.SubprocessError) as error:
        raise BridgeError("Could not launch the native Script Manager app.", "无法启动本地脚本管理应用。") from error


def bridge_connection():
    if sys.platform != "darwin":
        raise BridgeError("Script Manager requires macOS or native Windows.", "脚本管理需要 macOS 或原生 Windows。")
    socket_dir_override = os.environ.get(SOCKET_DIR_ENV)
    directory = Path(socket_dir_override or f"/tmp/codex-script-manager-{os.getuid()}")
    if not directory.is_absolute():
        raise BridgeError(f"{SOCKET_DIR_ENV} must be an absolute path.", f"{SOCKET_DIR_ENV} 必须是绝对路径。")
    endpoint = directory / "manager.sock"
    try:
        return connect_private_socket(endpoint)
    except (FileNotFoundError, ConnectionRefusedError):
        launch_bridge(socket_dir_override)

    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        try:
            return connect_private_socket(endpoint)
        except (FileNotFoundError, ConnectionRefusedError):
            time.sleep(0.1)
    raise BridgeError("Script Manager is not ready. If an older version is open, quit it and try again.",
                      "本地脚本管理未就绪。若已打开旧版浮窗，请退出后重试。")


def require_picker_executable(pid):
    # AppKit cannot open the picker once the running executable has been unlinked.
    executable = ctypes.create_string_buffer(4096)
    libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    if libproc.proc_pidpath(pid, executable, len(executable)) <= 0 and ctypes.get_errno() == errno.ENOENT:
        raise BridgeError(
            "The running Script Manager app bundle is missing. Quit Script Manager after your scripts finish, then reconnect.",
            "正在运行的脚本管理应用已被移除。请等脚本运行结束后退出脚本管理，再重新连接。",
        )


def bridge_call(method, arguments):
    request = json.dumps({"method": method, **arguments}, ensure_ascii=False).encode("utf-8") + b"\n"
    if len(request) > MAX_REQUEST_SIZE:
        raise BridgeError("The Script Manager request is too long.", "本地脚本管理请求过长。")
    try:
        with bridge_connection() as client:
            if method == "add_command":
                client.settimeout(15)
            pid = None
            if sys.platform == "darwin":
                pid = client.getsockopt(getattr(socket, "SOL_LOCAL", 0), getattr(socket, "LOCAL_PEERPID", 2))
                if method == "choose":
                    require_picker_executable(pid)
            client.sendall(request)
            with client.makefile("rb") as response:
                payload = response.readline(MAX_RESPONSE_SIZE + 1)
    except OSError as error:
        raise BridgeError("Could not connect to Script Manager.", "本地脚本管理连接失败。") from error
    if len(payload) > MAX_RESPONSE_SIZE or not payload.endswith(b"\n"):
        raise BridgeError("Script Manager returned incomplete data.", "本地脚本管理返回了不完整的数据。")
    try:
        result = json.loads(payload)
    except (UnicodeError, ValueError) as error:
        raise BridgeError("Could not read the Script Manager response.", "本地脚本管理返回了无法解析的数据。") from error
    if not isinstance(result, dict):
        raise BridgeError("Script Manager returned invalid data.", "本地脚本管理返回了无效的数据。")
    if method == "revealNative" and result.get("ok") is True:
        return {}
    data = result.get("data")
    if result.get("ok") is True and isinstance(data, dict):
        if pid is not None and data.get("pickPending"):
            try:
                require_picker_executable(pid)
            except BridgeError as error:
                data["pickPending"] = False
                data["pickerError"] = error.localized(arguments.get("locale"))
        return data
    message = result.get("error")
    if isinstance(message, str) and message:
        raise BridgeError(message)
    raise BridgeError("Script Manager could not complete the request.", "本地脚本管理未能完成请求。")


@lru_cache(maxsize=1)
def read_pins(_time_bucket):
    try:
        result = subprocess.run([str(APP_EXECUTABLE), "--pinned-projects"], capture_output=True, timeout=2, check=True)
        paths = json.loads(result.stdout)
        if isinstance(paths, list):
            unique = dict.fromkeys(path for path in paths if isinstance(path, str))
            return {path: position for position, path in enumerate(unique)}
    except (OSError, ValueError, subprocess.SubprocessError):
        pass
    return {}


def add_pins_for_older_bridge(data):
    projects = data.get("projects", [])
    if all("pinned" in project for project in projects):
        return
    # The previous app can keep running tasks and logs while the side panel updates.
    pins = read_pins(int(time.monotonic()) // 3)
    for project in projects:
        project["pinned"] = project.get("id") in pins
    projects.sort(key=lambda project: pins.get(project.get("id"), len(pins)))


def open_repair_draft(data, arguments, locale):
    project_id, task_id = arguments["projectId"], arguments["taskId"]
    def find(items, item_id):
        if not isinstance(items, list):
            return None
        return next((item for item in items if isinstance(item, dict) and item.get("id") == item_id), None)

    project = find(data.get("projects"), project_id)
    task = find(data.get("tasks"), task_id)
    if not project or not task or data.get("projectId") != project_id or data.get("selectedTaskId") != task_id:
        raise BridgeError("Select an existing script to use AI Fix.", "请选择一个现有脚本后再使用 AI 修复。")
    root = repair.project_root(task.get("rootPath", project.get("path"))) if project.get("available") is not False else None
    if root is None:
        raise BridgeError("The selected project folder is unavailable.", "所选项目的目录不可用。")
    log = data.get("log")
    if not isinstance(log, str):
        log = ""
    indices = data["logErrorLines"]
    if task.get("statusKind") != "failed" and not indices:
        raise BridgeError("AI Fix needs a failed run or an error in its log.", "AI 修复需要一次失败的运行或日志中的错误。")
    url = repair.draft_url(root, task, log, indices, chinese=translate(locale, False, True))
    try:
        if WINDOWS:
            os.startfile(url)
        else:
            subprocess.run(["/usr/bin/open", url], stdin=subprocess.DEVNULL, capture_output=True, timeout=3, check=True)
    except (OSError, subprocess.SubprocessError) as error:
        raise BridgeError("Could not open the Codex repair draft.", "无法打开 Codex 修复草稿。") from error


def call_tool(params, *, bridge=None):
    name, arguments = params.get("name"), params.get("arguments", {})
    meta = params.get("_meta")
    locale = meta.get("openai/locale") if isinstance(meta, dict) else None
    if isinstance(arguments, dict):
        locale = arguments.get("locale", locale)
    invalid_arguments = translate(locale, "Invalid Script Manager arguments.", "脚本管理参数无效。")
    if not isinstance(name, str):
        raise RpcError(-32602, "Missing tool name")
    if name == ENTRY_TOOL:
        if arguments != {}:
            return tool_result(invalid_arguments, error=True)
        return tool_result(translate(locale, "Script Manager is open.", "脚本管理已打开。"))
    if name == OPEN_FLOATING_WINDOW_TOOL and sys.platform == "darwin":
        if not isinstance(arguments, dict) or arguments.keys() - {"projectId", "locale"}:
            return tool_result(invalid_arguments, error=True)
        project = arguments.get("projectId")
        if (
            ("projectId" in arguments and (
                not isinstance(project, str) or not project.startswith("/") or "\x00" in project or len(project) > 8192
            ))
            or ("locale" in arguments and locale not in ("en", "zh-CN"))
        ):
            return tool_result(invalid_arguments, error=True)
        try:
            (bridge or bridge_call)("revealNative", arguments)
        except BridgeError as error:
            return tool_result(error.localized(locale), error=True)
        return tool_result(translate(locale, "Script Manager floating window opened.", "已打开脚本管理浮窗。"), data={"opened": True})
    operation = name.removeprefix(f"{ENTRY_TOOL}_")
    if operation == name or operation not in OPERATIONS:
        raise RpcError(-32602, "Unknown tool")
    _, properties, required = OPERATIONS[operation]
    if (
        not isinstance(arguments, dict)
        or set(arguments).difference((*properties, "locale"))
        or set(required).difference(arguments)
        or any(not isinstance(value, str) or not (1 <= len(value) <= 8192) for value in arguments.values())
        or ("locale" in arguments and locale not in ("en", "zh-CN"))
        or (operation == "open" and arguments["destination"] not in OPEN_DESTINATIONS)
    ):
        return tool_result(invalid_arguments, error=True)
    try:
        if bridge is None and WINDOWS:
            try:
                return portable_bridge.call_tool(params)
            except (OSError, portable_bridge.ConnectionError) as error:
                raise BridgeError("Could not connect to Script Manager on Windows.", "无法连接 Windows 脚本管理。") from error
        data = (bridge or bridge_call)("snapshot" if operation == "ai_fix" else operation, arguments)
        if data.get("schemaVersion") != 2:
            raise BridgeError(
                "An older Script Manager is running. Quit it after your scripts finish, then reconnect.",
                "旧版脚本管理仍在运行。请等脚本结束后退出旧版，再重新连接。",
            )
        data["logErrorLines"] = repair.error_lines(data.get("log"))
        if operation == "ai_fix":
            open_repair_draft(data, arguments, locale)
            return tool_result(translate(locale, "Codex repair draft opened.", "已打开 Codex 修复草稿。"), data={"opened": True})
        if not WINDOWS:
            add_pins_for_older_bridge(data)
    except BridgeError as error:
        return tool_result(error.localized(locale), error=True)
    return tool_result(translate(locale, "Script Manager status loaded.", "已获取脚本管理状态。"), data=data)


def resource_html():
    html = (PLUGIN_DIR / "app" / "index.html").read_text(encoding="utf-8")
    for icon in BRAND_ICONS:
        html = html.replace(f"__SCRIPT_MANAGER_ICON_{icon['theme'].upper()}__", icon["src"])
    html = html.replace("__SCRIPT_MANAGER_FLOATING_WINDOW__", "true" if sys.platform == "darwin" else "false")
    return html.replace("__SCRIPT_MANAGER_VERSION__", MANIFEST["version"])


def dispatch(method, params):
    if method == "initialize":
        requested = params.get("protocolVersion")
        if not isinstance(requested, str):
            raise RpcError(-32602, "Missing protocol version")
        return {
            "protocolVersion": requested if requested in SUPPORTED_VERSIONS else PROTOCOL_VERSION,
            "capabilities": {"tools": {}, "resources": {}},
            "serverInfo": {
                "name": MANIFEST["name"],
                "title": APP_TITLE,
                "version": MANIFEST["version"],
                "icons": SIDEBAR_ICONS,
            },
        }
    if method == "ping":
        return {}
    if method == "tools/list":
        return {"tools": list(tools())}
    if method == "tools/call":
        return call_tool(params)
    if method == "resources/list":
        return {"resources": [RESOURCE]}
    if method == "resources/templates/list":
        return {"resourceTemplates": []}
    if method == "resources/read":
        if params.get("uri") != RESOURCE_URI:
            raise RpcError(-32002, "Resource not found")
        return {
            "contents": [{
                "uri": RESOURCE_URI,
                "mimeType": RESOURCE_MIME,
                "text": resource_html(),
                "_meta": {"ui": {"permissions": {"clipboardWrite": {}}, "prefersBorder": False}},
            }],
        }
    raise RpcError(-32601, "Method not found")


def send_reply(request_id, **payload):
    reply = {"jsonrpc": "2.0", "id": request_id, **payload}
    sys.stdout.buffer.write(json.dumps(reply, ensure_ascii=True).encode("ascii") + b"\n")
    sys.stdout.buffer.flush()


def serve():
    for line in sys.stdin.buffer:
        request_id = None
        try:
            try:
                request = json.loads(line)
            except (UnicodeError, ValueError) as error:
                raise RpcError(-32700, "Parse error") from error
            if not isinstance(request, dict) or request.get("jsonrpc") != "2.0" or not isinstance(request.get("method"), str):
                raise RpcError(-32600, "Invalid request")
            if "id" not in request:
                continue
            request_id = request["id"]
            if type(request_id) not in (int, str):
                request_id = None
                raise RpcError(-32600, "Invalid request id")
            params = request.get("params", {})
            if not isinstance(params, dict):
                raise RpcError(-32602, "Invalid params")
            send_reply(request_id, result=dispatch(request["method"], params))
        except RpcError as error:
            send_reply(request_id, error={"code": error.code, "message": str(error)})
        except (OSError, UnicodeError) as error:
            print(f"script-manager: {error}", file=sys.stderr)
            send_reply(request_id, error={"code": -32603, "message": "Internal error"})


if __name__ == "__main__":
    serve()
