# Codex Script Manager

A Codex desktop plugin for running local project commands and viewing logs on macOS.

| Entry point | Use |
| --- | --- |
| Sidebar plugin | Open Script Manager in Codex to browse projects, run scripts, and view logs. |
| Chat skill | Use the `script-manager` skill in a local project chat to open the native window for the current project or worktree. |
| Project action (optional) | Run the installed action from the project's local environment to open the same native window. |

All three entry points share one local script runner. Closing the window or leaving the sidebar keeps scripts running. Reopen either view to see their status and latest logs. Quitting the native app stops the scripts it manages.

## Install the plugin

You need macOS 13 or later, Xcode or Command Line Tools, Python 3.9 or later, and a Codex desktop version that supports local plugins. Run these commands from the repository root:

```bash
./scripts/package-plugin.sh
codex plugin marketplace add "$(pwd -P)/build/codex-marketplace"
codex plugin add script-manager@codex-script-manager
```

Open **Explore** in the Codex sidebar, find **Script Manager**, and pin it. If a newly installed plugin does not appear, reopen Codex. [Local plugin installation](https://developers.openai.com/plugins/build/plugins#install-a-local-plugin-manually) · [Sidebar apps](https://developers.openai.com/plugins/build/extensions#sidebar-apps)

Script Manager lists local Codex projects and puts pinned projects first in their Codex order. Use **Open Project** to add another local folder. Select one project at a time, then search its scripts or filter them by package or status. Scripts in subpackages show the package name in parentheses. Use the button at the start of a row to run or stop its script.

The logs panel shows the latest output for scripts across projects. Select a script row or log tab to see the output. Closing a running tab stops its command. Select the script row to reopen its latest log. Changing projects keeps the current log open. The logs panel moves below the project and script lists on narrower windows.

Script Manager highlights recognized error lines. For a failed run or recognized error, **AI Fix** opens a Codex draft in the script's project with a short diagnostic excerpt. Review and send the draft to ask Codex to fix missing dependencies or project setup and identify required environment variables.

The sidebar follows the Codex interface language. The native window reads the Codex language when it opens and falls back to the macOS preferred language. Script output is displayed as written.

If you installed the plugin using its former ID, remove that installation and marketplace after installing the current one:

```bash
codex plugin remove script-manager@codex-actions
codex plugin marketplace remove codex-actions
```

## Add the optional project action

The action installer needs Python 3.11 or later, or Python with `tomli` installed. From the repository root, run:

```bash
./scripts/build.sh
./scripts/install-action.py '/path/to/project'
```

The installer adds a project action to `.codex/environments/environment.toml` and preserves the existing configuration. Use `--environment filename.toml` to select another environment file, `--app '/path/to/app.app'` to point to another app build, or `--dry-run` to print the generated command.

Open the project's local environment in Codex and run the installed action. If the chat was open during installation, switch to another chat and back to reload the configuration. [Codex project actions](https://learn.chatgpt.com/docs/environments/local-environment#actions)

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

Each command has a unique `name` and a `command` run by `/bin/sh`. Use a relative `cwd` to run it in an existing directory inside the project. If you omit `cwd`, the command runs in the project root. The tools used by the command need to be available in your shell.

Choose **Rescan** after saving the file. Custom commands appear alongside discovered scripts and use the same Run, Stop, and Logs controls. Run long-lived services in the foreground so Script Manager can capture their output and stop them.

## Automatic discovery

- Node.js scripts come from `package.json`. Script Manager picks npm, pnpm, Yarn, or Bun based on the package declaration or lockfile.
- Maven and Gradle Spring Boot modules support Run and Debug. The debug address is `127.0.0.1:5005`.
- Discovered scripts and build tasks run in the directory containing their build or package file, including nested modules.
- The native script runner is in `apps/macos/`, and the plugin is in `plugins/script-manager/`.
