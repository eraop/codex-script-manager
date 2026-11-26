from contextlib import contextmanager
from dataclasses import dataclass, field
from http.client import HTTPConnection, HTTPException
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import secrets
import socket
import stat
import subprocess
import sys
import time
from urllib.parse import urlencode


LOOPBACK = "127.0.0.1"
PROTOCOL = 1
MAX_REQUEST_SIZE = 64 * 1024
MAX_RESPONSE_SIZE = 8 * 1024 * 1024
PLUGIN_DIR = Path(__file__).resolve().parent


class ConnectionError(Exception):
    pass


def runtime_directory():
    base = Path(os.environ.get("LOCALAPPDATA") or Path.home() / "AppData" / "Local")
    return base / "CodexScriptManager"


def private_directory(directory):
    if not directory.is_absolute():
        raise OSError("Script Manager needs an absolute runtime directory")
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = directory.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_file_attributes & stat.FILE_ATTRIBUTE_REPARSE_POINT:
        raise OSError("Script Manager needs a private runtime directory")


@contextmanager
def daemon_lock(directory):
    import msvcrt

    with (directory / "runner.lock").open("a+b") as lock:
        lock.seek(0)
        try:
            msvcrt.locking(lock.fileno(), msvcrt.LK_NBLCK, 1)
        except PermissionError:
            yield False
        else:
            yield True


@dataclass
class Endpoint:
    port: int
    token: str = field(repr=False)

    def request(self, method, path, body=None):
        client = HTTPConnection(LOOPBACK, self.port, timeout=8 if body else 0.5)
        headers = {"Authorization": "Bearer " + self.token}
        if body is not None:
            headers["Content-Type"] = "application/json"
        try:
            client.request(method, path, body=body, headers=headers)
            response = client.getresponse()
            payload = response.read(MAX_RESPONSE_SIZE + 1)
            if response.status == 200 and len(payload) <= MAX_RESPONSE_SIZE:
                return json.loads(payload)
        except (OSError, HTTPException, ValueError):
            pass
        finally:
            client.close()
        raise ConnectionError("Could not connect to the local Script Manager runner.")

    def call_tool(self, params):
        return self.request("POST", "/tool", json.dumps(params).encode("ascii"))


def running_endpoint(directory):
    try:
        data = json.loads((directory / "runner.json").read_text(encoding="utf-8"))
        port, token = data["port"], data["token"]
        if type(port) is int and 1 <= port <= 65535 and isinstance(token, str) and len(token) == 43 and token.isascii():
            endpoint = Endpoint(port, token)
            if endpoint.request("GET", "/health") == {"protocol": PROTOCOL}:
                return endpoint
    except (OSError, ValueError, TypeError, KeyError, ConnectionError):
        pass
    return None


def launch(directory):
    command = [sys.executable, str(PLUGIN_DIR / "portable_bridge.py"), str(directory)]
    options = {"cwd": directory, "stdin": subprocess.DEVNULL, "stdout": subprocess.DEVNULL, "stderr": subprocess.DEVNULL}
    flags = subprocess.DETACHED_PROCESS | subprocess.CREATE_NEW_PROCESS_GROUP
    try:
        subprocess.Popen(command, creationflags=flags | subprocess.CREATE_BREAKAWAY_FROM_JOB, **options)
    except PermissionError:
        subprocess.Popen(command, creationflags=flags, **options)


def connect():
    directory = runtime_directory()
    private_directory(directory)
    endpoint = running_endpoint(directory)
    if endpoint is not None:
        return endpoint
    launch(directory)
    deadline = time.monotonic() + 6
    while time.monotonic() < deadline:
        endpoint = running_endpoint(directory)
        if endpoint is not None:
            return endpoint
        time.sleep(0.1)
    raise ConnectionError("Could not start the local Script Manager runner.")


def call_tool(params):
    return connect().call_tool(params)


def open_project(project):
    endpoint = connect()
    response = endpoint.call_tool({"name": "script_manager_add", "arguments": {"path": project}})
    if response.get("isError"):
        raise ConnectionError(response["content"][0]["text"])
    selection = response["structuredContent"]["selectedProjectId"]
    fragment = urlencode({"token": endpoint.token, "project": selection})
    os.startfile(f"http://{LOOPBACK}:{endpoint.port}/#{fragment}")


class RequestHandler(BaseHTTPRequestHandler):
    def setup(self):
        super().setup()
        self.connection.settimeout(10)

    def log_message(self, _format, *_args):
        pass

    def reply(self, status, body=b"", content_type="application/json"):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Content-Security-Policy", "default-src 'none'; script-src 'unsafe-inline'; "
                         "style-src 'unsafe-inline'; img-src data:; connect-src 'self'; base-uri 'none'; "
                         "form-action 'none'; frame-ancestors 'none'")
        self.end_headers()
        if body:
            self.wfile.write(body)

    def reply_json(self, value):
        body = json.dumps(value).encode("ascii")
        if len(body) <= MAX_RESPONSE_SIZE:
            self.reply(200, body)
        else:
            self.reply(500)

    def local_origin(self):
        host = f"{LOOPBACK}:{self.server.server_port}"
        return self.headers.get("Host") == host and self.headers.get("Origin") in (None, "http://" + host)

    def authorized(self):
        value = self.headers.get("Authorization", "").encode("latin-1")
        return secrets.compare_digest(value, ("Bearer " + self.server.token).encode("ascii"))

    def do_GET(self):
        if not self.local_origin():
            self.reply(403)
        elif self.path == "/":
            self.reply(200, self.server.html, "text/html; charset=utf-8")
        elif self.path == "/health" and self.authorized():
            self.reply_json({"protocol": PROTOCOL})
        else:
            self.reply(404)

    def do_POST(self):
        if not self.local_origin() or not self.authorized():
            self.reply(403)
            return
        if self.path != "/tool":
            self.reply(404)
            return
        try:
            length = int(self.headers.get("Content-Length", ""))
            if not 0 < length <= MAX_REQUEST_SIZE or self.headers.get_content_type() != "application/json":
                raise ValueError
            value = json.loads(self.rfile.read(length))
            if not isinstance(value, dict):
                raise ValueError
            result = self.server.call_tool(value)
        except (ValueError, self.server.rpc_error):
            self.reply(400)
        except OSError:
            self.reply(500)
        else:
            self.reply_json(result)


class LocalServer(ThreadingHTTPServer):
    allow_reuse_address = False

    def __init__(self, runner):
        import server
        from portable_runner import PortableError

        self.runner = runner
        self.portable_error = PortableError
        self.rpc_error = server.RpcError
        self.bridge_error = server.BridgeError
        self.handle_tool = server.call_tool
        self.token = secrets.token_urlsafe(32)
        self.html = server.resource_html().encode("utf-8")
        super().__init__((LOOPBACK, 0), RequestHandler)

    def server_bind(self):
        if sys.platform == "win32":
            self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
        super().server_bind()

    def bridge(self, method, arguments):
        try:
            return self.runner.call(method, arguments)
        except self.portable_error as error:
            raise self.bridge_error(str(error), error.chinese) from error

    def call_tool(self, value):
        return self.handle_tool(value, bridge=self.bridge)


def serve(directory):
    from portable_runner import Runner

    private_directory(directory)
    with daemon_lock(directory) as acquired:
        if not acquired:
            return
        runner = Runner()
        state_path = directory / "runner.json"
        try:
            with LocalServer(runner) as server:
                temporary = directory / "runner.next.json"
                fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
                with os.fdopen(fd, "w", encoding="utf-8") as stream:
                    json.dump({"port": server.server_port, "token": server.token}, stream)
                for attempt in range(10):
                    try:
                        os.replace(temporary, state_path)
                        break
                    except PermissionError:
                        # Another launcher may still be reading the previous endpoint file.
                        if attempt == 9:
                            raise
                        time.sleep(0.05)
                server.serve_forever()
        finally:
            try:
                state_path.unlink(missing_ok=True)
            finally:
                runner.close()


if __name__ == "__main__":
    if len(sys.argv) != 2 or sys.platform != "win32":
        sys.exit("Script Manager runner requires native Windows.")
    serve(Path(sys.argv[1]))
