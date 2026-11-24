---
name: script-manager
description: Open the native Script Manager window for the current local Codex project or worktree. Use when asked to open Script Manager for the current project.
---

# Open Script Manager

For a local macOS project or worktree, run `scripts/open-project.sh` from this skill using its absolute path. Set the command working directory to the current project or worktree and pass its absolute path as the only argument.

For a remote, cloud, or projectless chat, ask the user to switch to a local macOS project chat. Opening the panel leaves script execution under the user's control.
