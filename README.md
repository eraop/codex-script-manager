# Codex Script Manager

A local Codex plugin for running project commands and viewing logs on macOS and Windows.

| Entry point | Use |
| --- | --- |
| Sidebar | Open Script Manager in Codex to browse projects, run scripts, and view logs. |
| Chat skill | Use the `script-manager` skill in a local project chat to open the current project or worktree in the macOS native window or the Windows browser dashboard. |

The sidebar and chat skill share the same script runner within each environment. Closing the window, browser tab, or sidebar keeps scripts running. Reopen either view to see their status and latest logs. On macOS, quitting the native app stops the scripts it manages.

## Install the plugin

Use a Codex version that supports local plugins and install Python 3.9 or later. Run the commands for your environment from this repository's root.

### macOS

You need macOS 13 or later, Xcode or Command Line Tools, and `python3` on your `PATH`.

```bash
./scripts/package-plugin.sh
codex plugin marketplace add "$(pwd -P)/build/codex-marketplace"
codex plugin add script-manager@codex-script-manager
```

### Native Windows

Use PowerShell with Windows Python available as `python` and the Windows Codex CLI available as `codex`.

```powershell
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\scripts\package-plugin.ps1
$marketplace = (Resolve-Path .\build\codex-marketplace-windows).Path
codex plugin marketplace add $marketplace
codex plugin add script-manager@codex-script-manager
```

Keep the desktop app's agent set to **Windows native**. [Windows desktop settings](https://learn.chatgpt.com/docs/windows/windows-app#windows-subsystem-for-linux-wsl)

### Open Script Manager

Open **Explore** in the Codex desktop sidebar, find **Script Manager**, and pin it. If a newly installed plugin does not appear, reopen Codex. [Local plugin installation](https://developers.openai.com/plugins/build/plugins#install-a-local-plugin-manually) · [Sidebar apps](https://developers.openai.com/plugins/build/extensions#sidebar-apps)

Script Manager lists local Codex projects and puts pinned projects first in their Codex order. Use **Open Project** to add another local folder. When a Codex project has multiple folders, its command list shows the primary folder first and the attached folders in Codex order. Each folder group starts expanded and can be collapsed independently. Search and filters cover the entire command list. Scripts in subpackages show their package names. Use the button at the start of a row to run or stop its script.

Commands run in the folder they came from. Opening a Worktree chat uses the current checkout and includes the attached folders when Script Manager can identify a unique matching Codex project. Each command has its own status and log, even when commands in different folders share a name.

The logs panel shows the latest output for scripts across projects. Select a script row or log tab to see the output. Closing a running tab stops its command. Select the script row to reopen its latest log. Changing projects keeps the current log open. The logs panel moves below the project and script lists on narrower windows.

Script Manager highlights recognized error lines. For a failed run or recognized error, **AI Fix** opens a Codex draft in the script's project with a short diagnostic excerpt. Review and send the draft to ask Codex to fix missing dependencies or project setup and identify required environment variables.

The sidebar follows the Codex interface language. The macOS window reads the Codex language when it opens and falls back to the system language. The Windows dashboard follows the browser language. Script output is displayed as written.

## Configure project commands

Use `.codex/script-manager.json` in the project root to add noninteractive shell commands for any project. For example:

```json
{
  "commands": [
    { "name": "Python server", "command": "python3 -m http.server --bind 127.0.0.1 8000", "cwd": "apps/api" },
    { "name": "Go server", "command": "go run ./cmd/server" },
    { "name": "Local services", "command": "docker compose up" }
  ]
}
```

Each command has a unique `name` and a shell `command`. The runner uses `/bin/sh` on macOS and `cmd.exe` on Windows. Use the command syntax and executable names for the target environment. For example, use `python` in place of `python3` for the first example on Windows. Use a relative `cwd` to run a command in an existing directory inside the project. If you omit `cwd`, the command runs in the project root. Windows projects that use `cmd.exe` or a batch script need a drive-letter path. The tools used by the command need to be available in your shell.

Use `platforms.macos.command` or `platforms.windows.command` to override the default command for that platform. If you provide only platform-specific commands, the entry appears on the platforms you configured.

```json
{
  "commands": [
    {
      "name": "Python tests",
      "command": "python3 -m pytest",
      "platforms": { "windows": { "command": "python -m pytest" } }
    }
  ]
}
```

Choose **Rescan** after editing the file. Custom commands appear alongside discovered scripts and use the same Run, Stop, and Logs controls. Run long-lived services in the foreground so Script Manager can capture their output and stop them.

## Automatic discovery

- Node.js scripts come from `package.json`. Script Manager picks npm, pnpm, Yarn, or Bun based on the package declaration or lockfile.
- Maven and Gradle Spring Boot modules support Run and Debug. The debug address is `127.0.0.1:5005`.
- Discovered scripts and build tasks run in the directory containing their build or package file, including nested modules.

### Save suggested commands

Rescan looks for project files that identify common commands. Suggestions include Python tests and uv entry points, Go build and test commands and recognized `main.go` entry points, Cargo tasks, .NET projects and solutions, and Docker Compose. The list shows each suggested command and its working directory. Choose **Add** to save it to the group’s `.codex/script-manager.json`. The scanner reads files and the Add action appends to the existing configuration.

### Use Codex Actions

Script Manager reads version 1 Actions from `.codex/environments/environment.toml` in each folder. An Action for the current platform takes precedence over a default Action with the same name. Start Actions from the command list. They run in the folder that contains the configuration, using the login shell on macOS and PowerShell on Windows. This supports commands that run without interactive input. [Codex local environments](https://learn.chatgpt.com/docs/environments/local-environment#actions)
