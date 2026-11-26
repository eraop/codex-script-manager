---
name: script-manager
description: Open Script Manager for the current local Codex project or worktree on macOS or native Windows. Use when asked to open Script Manager for the current project.
---

# Open Script Manager

Set the command working directory to the current project or worktree. Use the absolute path to the launcher bundled with this skill, and pass the absolute project path as its only argument.

- macOS: Run `scripts/open-project.sh` to open the native window.
- Native Windows: Run `python` with `scripts/open-project.py` and a Windows project path.

For a remote, cloud, or projectless chat, ask the user to switch to a supported local project chat. Opening Script Manager leaves script execution under the user's control.
