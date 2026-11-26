# Codex Script Manager

A local Codex plugin for running project commands and viewing logs on macOS and Windows.

| Entry point | Use |
| --- | --- |
| Sidebar | Open Script Manager in Codex to browse projects, run scripts, and view logs. |
| Chat side panel | Open Script Manager beside a project chat to run scripts and follow logs while keeping the chat visible. |
| Chat skill | Use the `script-manager` skill in a local project chat to open the current project or worktree in the macOS native window or the Windows browser dashboard. |

All entry points share the same script runner within each environment. Closing a view keeps scripts running. Reopen Script Manager to see their status and latest logs. On macOS, quitting the native app stops the scripts it manages.

## Install the plugin

Use the Codex desktop app with local plugin support and Python 3.9 or later.

- On macOS, put `python3` on your `PATH`. [Desktop app requirements](https://help.openai.com/en/articles/9275200-downloading-the-chatgpt-macos-app)
- On Windows, put `python` on your `PATH` and set the Codex agent to **Windows native**. [Windows desktop settings](https://learn.chatgpt.com/docs/windows/windows-app#windows-subsystem-for-linux-wsl)

### Install from the Git repository

1. In the Codex plugin directory, choose **Add → Add a marketplace**.
2. Enter the repository's Git clone URL in **Source**, such as `git@github.com:eraop/codex-script-manager.git`. If you use an SSH host alias, enter the clone URL that works with your Git credentials.
3. Set **Git ref** to the branch for your platform and leave **Sparse paths** empty.

   | Platform | Git ref |
   | --- | --- |
   | macOS (Apple silicon and Intel) | `marketplace-macos` |
   | Windows native | `marketplace-windows` |

4. Select **Add marketplace**, open **Script Manager** in the **Codex Script Manager** marketplace, and choose **Install**.

The publishing workflow builds and publishes both branches when packaging inputs change on `main`. It can also run manually from `main`. [Publish plugin marketplaces](.github/workflows/publish-marketplaces.yml)

### Build from source

Run the commands for your platform from the repository root with `codex` available on your `PATH`.

#### macOS

Install Xcode or Command Line Tools to build the native app for macOS 13 or later.

```bash
./scripts/package-plugin.sh
codex plugin marketplace add "$(pwd -P)/build/codex-marketplace"
codex plugin add script-manager@codex-script-manager
```

#### Windows native

```powershell
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\scripts\package-plugin.ps1
$marketplace = (Resolve-Path .\build\codex-marketplace-windows).Path
codex plugin marketplace add $marketplace
codex plugin add script-manager@codex-script-manager
```

### Open Script Manager

Open **Explore** in the Codex desktop sidebar, find **Script Manager**, and pin it. If a newly installed plugin does not appear, reopen Codex. [Local plugin installation](https://developers.openai.com/plugins/build/plugins#install-a-local-plugin-manually) · [Sidebar apps](https://developers.openai.com/plugins/build/extensions#sidebar-apps)

On macOS, Codex shows the floating window shortcut in the sidebar layout with named app rows. Select the two-window icon at the right edge of the pinned **Script Manager** row. Hover over the icon to see **打开浮窗** (Open floating window). When Codex places app icons in the navigation rail, use the `script-manager` skill in your project chat to open the native window.

To keep a project chat visible, open its right panel, choose **New tab (+)**, and select **Script Manager** from the plugin options. [Conversation panels](https://github.com/openai/mcp-extensions/blob/main/docs/spec.md#thread-entrypoint)

On macOS, click the two-window icon in the Script Manager header to bring the selected project into the native window. Hover to see **Open Floating Window**. Use the **Back to Codex** icon in the floating window's title bar to return to Codex while your scripts keep running.

Script Manager lists local Codex projects and puts pinned projects first in their Codex order. Use **Open Project** to add another local folder. When a Codex project has multiple folders, its command list shows the primary folder first and the attached folders in Codex order. Each folder group starts expanded and can be collapsed independently. Search and filters cover the entire command list. Scripts in subpackages show their package names. Use the button at the start of a row to run or stop its script.

Commands run in the folder they came from. Opening a Worktree chat uses the current checkout and includes the attached folders when Script Manager can identify a unique matching Codex project. Each command has its own status and log, even when commands in different folders share a name.

The logs panel shows the latest output for scripts across projects. Select a script row or log tab to see the output. Closing a running tab stops its command. Select the script row to reopen its latest log. Changing projects keeps the current log open. The logs panel moves below the project and script lists on narrower windows.

Script Manager highlights recognized error lines. For a failed run or recognized error, **AI Fix** opens a Codex draft in the script's project with a short diagnostic excerpt. Review and send the draft to ask Codex to fix missing dependencies or project setup and identify required environment variables.

The sidebar follows the Codex interface language. The macOS window reads the Codex language when it opens and falls back to the system language. The Windows dashboard follows the browser language. Script output is displayed as written.

### External processes

On macOS and native Windows, select a project and open **External Processes** to see local processes running from that project's folders. Select a process to follow stdout or stderr redirected to a readable file. macOS also detects writable `.log` files that the process still has open. Script Manager displays up to the latest 64 KiB. Terminal output remains in the original terminal. For example, in a macOS shell or Windows Command Prompt, run `npm run dev >> dev.log 2>&1` to capture output in a file.

Use the stop button and confirm the name and PID. Script Manager rechecks the process identity and project. macOS sends `SIGTERM` to request a graceful stop. Windows terminates the selected process immediately after confirmation.

If the Windows runner is still from an earlier version, let managed scripts finish, restart Windows, and reopen Script Manager to load the update.

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
