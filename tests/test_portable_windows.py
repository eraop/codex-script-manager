from http.client import HTTPConnection
import ctypes
from ctypes import wintypes
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import Mock


PLUGIN = Path(__file__).resolve().parents[1] / "plugins" / "script-manager"
sys.path.insert(0, str(PLUGIN))

import portable_bridge
from portable_discovery import discover_tasks


def write_commands(root, commands):
    config = root / ".codex" / "script-manager.json"
    config.parent.mkdir(exist_ok=True)
    config.write_text(json.dumps({"commands": commands}), encoding="utf-8")


def wait_for(callback, timeout=10):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = callback()
        if result:
            return result
        time.sleep(0.05)
    raise AssertionError("Timed out waiting for Script Manager.")


class DiscoveryTests(unittest.TestCase):
    def test_outside_configured_directory_leaves_discovered_scripts_available(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "project"
            root.mkdir()
            (root / "package.json").write_text('{"scripts":{"dev":"node dev.js"}}', encoding="utf-8")
            write_commands(root, [{"name": "Outside", "command": "echo test", "cwd": ".."}])

            tasks, error = discover_tasks(root)

            self.assertEqual([task.name for task in tasks], ["dev"])
            self.assertIn("inside the project", error.localized("en"))


class LocalTransportTests(unittest.TestCase):
    def test_only_authorized_local_requests_reach_the_runner(self):
        runner = Mock()
        runner.call.return_value = {"schemaVersion": 2, "projects": [], "log": "error: fixture"}
        with portable_bridge.LocalServer(runner) as server:
            thread = threading.Thread(target=server.serve_forever)
            thread.start()
            try:
                self.check_requests(server, runner)
            finally:
                server.shutdown()
                thread.join()

    def check_requests(self, server, runner):
        tool = {"name": "script_manager_snapshot", "arguments": {}}
        token = {"Authorization": "Bearer " + server.token}

        def request(method, path, headers, body=None):
            connection = HTTPConnection("127.0.0.1", server.server_port, timeout=5)
            try:
                connection.request(method, path, body=body, headers=headers)
                response = connection.getresponse()
                return response.status, response.read()
            finally:
                connection.close()

        status, dashboard = request("GET", "/", {})
        self.assertEqual(status, 200)
        self.assertNotIn(server.token.encode("ascii"), dashboard)

        body = json.dumps(tool)
        headers = {"Content-Type": "application/json"}
        for rejected in (
            headers,
            {**headers, "Authorization": "Bearer invalid"},
            {**headers, **token, "Origin": "https://example.test"},
            {**headers, **token, "Host": "example.test"},
        ):
            self.assertEqual(request("POST", "/tool", rejected, body)[0], 403)
        runner.call.assert_not_called()

        endpoint = portable_bridge.Endpoint(server.server_port, server.token)
        result = endpoint.call_tool(tool)
        runner.call.assert_called_once_with("snapshot", {})
        self.assertEqual(result["structuredContent"]["logErrorLines"], [0])


DAEMON = """
from functools import partial
from pathlib import Path
import sys
sys.path.insert(0, sys.argv[1])
import portable_bridge
import portable_runner
portable_runner.Runner = partial(portable_runner.Runner, Path(sys.argv[2]))
portable_bridge.serve(Path(sys.argv[3]))
"""


@unittest.skipUnless(sys.platform == "win32", "Requires native Windows cmd.exe and Job Objects")
class NativeWindowsTests(unittest.TestCase):
    def test_runs_configured_command_and_stops_its_descendant(self):
        with tempfile.TemporaryDirectory() as temporary:
            temp = Path(temporary).resolve()
            project = temp / "Project with spaces"
            workspace = project / "module"
            workspace.mkdir(parents=True)
            self.create_tasks(project)

            runtime = temp / "runtime"
            daemon = subprocess.Popen(
                [sys.executable, "-B", "-c", DAEMON, str(PLUGIN), str(temp / "codex"), str(runtime)],
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
            )
            try:
                endpoint = wait_for(lambda: self.find_endpoint(daemon, runtime))
                self.exercise_runner(endpoint, project, workspace)
            finally:
                daemon.terminate()
                daemon.communicate(timeout=5)

    def create_tasks(self, project):
        (project / "spawn_child.py").write_text(
            "import subprocess, sys\n"
            "child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)'])\n"
            "print(f'DESCENDANT_PID={child.pid}', flush=True)\n"
            "child.wait()\n",
            encoding="utf-8",
        )
        write_commands(project, [
            {
                "name": "Write logs", "cwd": "module",
                "command": "echo native stdout& echo native stderr 1>&2& echo proof>cwd-proof.txt",
            },
            {"name": "Start descendant", "command": f'"{sys.executable}" spawn_child.py'},
        ])

    def find_endpoint(self, daemon, runtime):
        if daemon.poll() is not None:
            _, errors = daemon.communicate()
            self.fail(f"Windows runner exited with {daemon.returncode}: {errors.decode(errors='replace')}")
        return portable_bridge.running_endpoint(runtime)

    def exercise_runner(self, endpoint, project, workspace):
        def call(operation, **arguments):
            result = endpoint.call_tool({"name": "script_manager_" + operation, "arguments": arguments})
            self.assertFalse(result.get("isError"), result)
            return result["structuredContent"]

        project_id = call("add", path=str(project))["selectedProjectId"]

        def discover():
            tasks = call("snapshot", projectId=project_id)["tasks"]
            return {task["name"]: task["id"] for task in tasks} if len(tasks) == 2 else None

        tasks = wait_for(discover)

        def run(operation, name):
            return call(operation, projectId=project_id, taskId=tasks[name])

        def wait_for_status(name, expected):
            def snapshot():
                data = run("snapshot", name)
                row = next(task for task in data["tasks"] if task["id"] == tasks[name])
                if row["statusKind"] == "failed":
                    self.fail(data["log"])
                return data if row["statusKind"] == expected else None

            return wait_for(snapshot)

        run("start", "Write logs")
        log = wait_for_status("Write logs", "succeeded")["log"].splitlines()
        self.assertIn("native stdout", [line.strip() for line in log])
        self.assertIn("native stderr", [line.strip() for line in log])
        self.assertEqual((workspace / "cwd-proof.txt").read_text(encoding="utf-8").strip(), "proof")

        run("start", "Start descendant")
        match = wait_for(lambda: re.search(r"^DESCENDANT_PID=(\d+)$", run("snapshot", "Start descendant")["log"], re.M))
        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
        kernel.OpenProcess.restype = wintypes.HANDLE
        kernel.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
        kernel.WaitForSingleObject.restype = wintypes.DWORD
        kernel.CloseHandle.argtypes = [wintypes.HANDLE]
        handle = kernel.OpenProcess(0x00100000, False, int(match[1]))  # SYNCHRONIZE
        self.assertTrue(handle, "Expected the descendant to be running.")
        try:
            self.assertEqual(kernel.WaitForSingleObject(handle, 0), 258)  # WAIT_TIMEOUT
            run("stop", "Start descendant")
            self.assertEqual(kernel.WaitForSingleObject(handle, 5000), 0)  # WAIT_OBJECT_0
            wait_for_status("Start descendant", "stopped")
        finally:
            kernel.CloseHandle(handle)


if __name__ == "__main__":
    unittest.main()
