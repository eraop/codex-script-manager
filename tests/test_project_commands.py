import json
import os
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "plugins" / "script-manager"))
from portable_discovery import discover_tasks
from project_commands import CommandError, save_project_candidate, scan_project_commands


class ProjectCommandTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()

    def write(self, path, text):
        file = self.root / path
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(text, encoding="utf-8")
        return file

    def test_rescan_suggests_commands_without_writing_config(self):
        self.write("api/pyproject.toml", "[tool.pytest.ini_options]\naddopts = '-q'\n")
        self.write("api/uv.lock", "version = 1\n")
        self.write("backend/go.mod", "module example.com/backend\n")
        self.write("backend/cmd/api/main.go", "package main\nfunc main() {}\n")
        self.write("library/Cargo.toml", "[package]\nname = 'library'\n")
        self.write("app/App.csproj", '<Project Sdk="Microsoft.NET.Sdk.Web"></Project>')
        self.write("ops/compose.yaml", "services: {}")
        candidates, actions, error = scan_project_commands(self.root)
        commands = {(row["cwd"], row["command"]) for row in candidates}
        self.assertTrue({
            ("api", "uv run pytest"),
            ("backend", "go test ./..."),
            ("backend", "go run ./cmd/api"),
            ("library", "cargo build"),
            ("app", "dotnet run"),
            ("ops", "docker compose up"),
        }.issubset(commands))
        self.assertNotIn(("backend", "go run ."), commands)
        self.assertNotIn(("library", "cargo run"), commands)
        self.assertEqual(actions, [])
        self.assertIsNone(error)
        self.assertFalse((self.root / ".codex").exists())

    def test_add_preserves_existing_settings_and_is_idempotent(self):
        self.write("services blue/pytest.ini", "[pytest]\n")
        manual = {"name": "Python Test", "command": "echo keep my custom command"}
        config = self.write(".codex/script-manager.json", json.dumps({"commands": [manual], "custom": {"value": 3}}))
        candidate = next(row for row in scan_project_commands(self.root)[0] if row["name"] == "Python Test")
        self.assertEqual(candidate["cwd"], "services blue")
        save_project_candidate(self.root, candidate["id"])
        contents = config.read_bytes()
        persisted = json.loads(contents)
        self.assertEqual(persisted["custom"], {"value": 3})
        self.assertEqual(persisted["commands"][0], manual)
        self.assertEqual(persisted["commands"][1]["platforms"]["windows"]["command"], "python -m pytest")
        tasks, error = discover_tasks(self.root)
        self.assertIsNone(error)
        task = next(task for task in tasks if task.cwd == self.root / "services blue")
        self.assertEqual(task.command, "python -m pytest" if os.name == "nt" else "python3 -m pytest")
        self.assertEqual(scan_project_commands(self.root)[0], [])
        save_project_candidate(self.root, candidate["id"])
        self.assertEqual(config.read_bytes(), contents)

    def test_add_leaves_invalid_config_and_rejects_stale_candidates(self):
        manifest = self.write("compose.yaml", "services: {}")
        config = self.write(".codex/script-manager.json", "{invalid")
        suggestion = scan_project_commands(self.root)[0][0]
        with self.assertRaises(CommandError):
            save_project_candidate(self.root, suggestion["id"])
        self.assertEqual(config.read_text(), "{invalid")
        config.unlink()
        manifest.unlink()
        with self.assertRaisesRegex(CommandError, "suggestion has changed"):
            save_project_candidate(self.root, suggestion["id"])
        self.assertFalse(config.exists())

    def test_version_one_actions_support_multiline_and_platform_overrides(self):
        config = self.write(".codex/environments/environment.toml", """version = 1
name = "Example"

[setup]
script = "echo setup only"

[[actions]]
name = "Build"
command = "echo default"

[[actions]]
name = "Build"
platform = "darwin"
command = '''
echo build
echo done'''

[[actions]]
name = "Build"
platform = "win32"
command = '''
Write-Output build
Write-Output done'''

[[actions]]
name = "Test"
command = "echo test"
""")
        candidates, actions, error = scan_project_commands(self.root)
        self.assertEqual(candidates, [])
        self.assertIsNone(error)
        self.assertEqual([action["name"] for action in actions], ["Build", "Test"])
        expected = "Write-Output build\nWrite-Output done" if os.name == "nt" else "echo build\necho done"
        self.assertEqual(actions[0]["command"], expected)
        self.assertEqual(actions[1]["command"], "echo test")

        config.write_text("version = 2\n", encoding="utf-8")
        self.write("compose.yaml", "services: {}")
        candidates, actions, error = scan_project_commands(self.root)
        self.assertEqual(candidates[0]["command"], "docker compose up")
        self.assertEqual(actions, [])
        self.assertIsNotNone(error)


if __name__ == "__main__":
    unittest.main()
