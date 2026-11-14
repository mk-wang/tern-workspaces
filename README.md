# tern-workspaces

> 📁 **Workspaces for Tern** — A project sidebar with session-grouped tabs, root-locked tab creation, agent chat resume, and configurable actions for agents and external tools.

## Install

Install [Tern](https://stencil.so/tern) first. Chat history discovery also requires Python 3 (`python3` on `PATH`).

```sh
tern plugin install github.com/mk-wang/tern-workspaces
```

Press `⌘⌥B` on macOS, or `Ctrl+Alt+B` on Linux and Windows, to toggle the sidebar.
Add the current folder with `⌘⌥⇧A` on macOS, or `Ctrl+Alt+Shift+A` on Linux and Windows.
The native interaction checks have been verified on macOS. Other platforms have not been verified.

New installations use each agent's normal approval and sandbox settings. Existing `commands.json` files are not changed.

---

## ✨ Features

- 📑 **Persistent Workspaces Sidebar List**:
  - Press **`⌘ ⌥ B`** (or click the workspace name in the status bar) to toggle the left sidebar.
  - The shortcut toggles one global visibility preference. Existing and new tabs follow the same open or closed state.
  - Opening mounts the sidebar during the action. It does not wait for a window timer or history discovery.
  - The plugin stores workspaces in its own data directory. No other project plugin is required.
  - Each project opens its own Tern session. Selecting a project restores that session and its existing tabs.
  - The top tab bar shows the selected session's tabs. New tabs open at that project's root, even after `cd`.
  - Session bindings persist across plugin reloads and are scoped to the Tern window. Renaming a session preserves its binding.
  - Existing tabs stay in their original sessions. Adding or opening a project does not move those tabs.
  - Tern has no window-level plugin sidebar. One native sidebar pane follows the active tab across sessions without moving content panes.
  - Switching tabs or sessions preserves terminal focus and the sidebar's scroll position. The toggle and keyboard **Close block** action park the pane.
  - Sidebar visibility and width preferences are shared across tabs, sessions, and windows. Dragging the divider updates the saved width.
  - Width follows a viewport fraction rather than a fixed pixel size. Native terminal cells limit resize precision.
  - Tern owns scroll state and does not expose offsets. Plugin reloads and the native pane-header close button reset scroll position.
  - The shared-pane flow is verified in one local window. Concurrent windows and remote hosts have not been verified.
  - In an empty session, opening the sidebar first creates a terminal tab.
  - The sidebar groups projects into **Stick**, **With Status**, and **No Status** sections. Each project keeps its actions and recent chats together.
  - Click the pin icon beside a workspace name to pin or unpin it. Pins are saved across plugin reloads.
  - Pinned projects stay in the **Stick** section regardless of activity. Active pinned projects also appear in **With Status**.
  - **Stick** dynamically places projects with status indicators first. Each status group keeps its saved order.
  - Each section starts expanded. Click its heading to collapse or expand it.
  - The top input filters projects by name or stored path using case-insensitive literal substrings. Either field can match.
  - Clear the input or press Escape to show all projects. Filtering does not change saved projects, sessions, or tabs.
- **Live OMP Status**:
  - Each project shows OMP status indicators using its bound Tern session.
  - Animated spinner (`Working`): an OMP agent is running a turn.
  - `?` (`Waiting`): an OMP agent needs your input.
  - `✓` (`Finished`): an OMP turn ended with an unread Tern alert. Viewing the conversation clears the alert.
  - A project can show several indicators. Counts appear when more than one agent shares the same status.
  - Idle agents without an unread alert have no indicator. Status is live and is not saved in workspace data.
  - Status refreshes on agent events and reconciles every second.
  - Projects with a status indicator in their header or in a recent chat appear in **With Status** before **No Status**. Chats with status indicators appear first within each project. Each group keeps its original order.
- ⚙️ **100% Configurable Data-Driven Actions**:
  - No hardcoded applications! Launch actions are defined in `commands.json`.
  - Supports two action types:
    - `"tab"`: Launches a tab inside Tern at the workspace root (e.g. `terminal`, `omp`, `codex`, `claude`).
    - `"external"`: Launches an external application on that directory (e.g. `fork`, `cursor`, `code`).
- 🛠️ **Configuration (`commands.json`)**:
  - Located in the plugin data directory. On macOS: `~/Library/Application Support/Tern/plugin-data/workspaces/commands.json`.
    ```json
    {
      "actions": [
        { "id": "omp", "label": "omp", "type": "tab", "cmd": "omp", "args": "", "tone": "accent" },
        { "id": "codex", "label": "codex", "type": "tab", "cmd": "codex", "args": "", "tone": "info" },
        { "id": "claude", "label": "claude", "type": "tab", "cmd": "claude", "args": "", "tone": "warning" },
        { "id": "fork", "label": "fork", "type": "external", "cmd": "fork", "args": "", "tone": "success" }
      ]
    }
    ```
  - To add VS Code, add `{ "id": "vscode", "label": "code", "type": "external", "cmd": "code", "tone": "info" }`. For Cursor, use `"cmd": "cursor"`.
  - Click **`[⚙ Config Commands]`** at the bottom of the sidebar to edit it anytime.
- 🗂️ **Multi-Folder Workspaces (`--add-dir`)**:
  - Multi-folder projects automatically append secondary folders as `--add-dir <extra_folder>` to OMP, Codex, and Claude.
- 💬 **Recent Agent Chat Sessions & One-Click Resume**:
  - Reads local OMP, Codex, and Claude Code session metadata directly. Requires `python3` on `PATH`.
  - Click an OMP chat row to switch to its open tab. If no matching tab exists, the plugin resumes the conversation inside its workspace. Codex and Claude rows resume directly.
  - OMP continuation chains appear once, using the newest continuation.
  - Each OMP chat row shows live status for its own continuation chain. Inactive sessions have no status indicator.
  - Independent chats and forks remain separate, even when titles match.
  - History matching resolves directory symlinks without changing saved workspace paths or session bindings.
  - **Refresh** reloads the list and recent sessions without syncing with another plugin.
  - Discovery examines the newest 150 session files per agent and displays up to 30 recent sessions.
  - Reads are capped at 64 KiB for transcript prefixes and Claude transcript tails. Title index reads are capped at 4 MiB.
- 🔒 **Root-Locked Tabs**:
  - Pressing `⌘T` (`Ctrl+T`) anywhere inside an active workspace opens new tabs **strictly at the workspace root**.
- ➕ **One-Click Add**:
  - Press `⌘⌥⇧A` from any active terminal to add the current directory as a workspace.
  - Removing a workspace changes only this plugin's list. It does not delete the folder or close running tabs.
- 📂 **Drag to Add**:
  - Drag a folder from the Files pane onto the Workspaces pane to add it to the list.
  - Multiple folders and paths with spaces are supported. Files and unreadable folders are rejected.
  - Dropping an existing workspace keeps its name and folder configuration.
- 📊 **Status Bar Segment**: Shows `📁 <Workspace Name>` in the status bar with click-to-toggle.

---

## ⌨️ Keyboard Shortcuts

| Action | macOS | Linux / Windows |
| :--- | :--- | :--- |
| **Toggle Workspaces Sidebar (List View)** | `⌘ ⌥ B` | `Ctrl + Alt + B` |
| **Switch Workspace (Modal Picker)** | `⌘ ⌥ ⇧ O` | `Ctrl + Alt + Shift + O` |
| **Add Current Folder to Workspaces** | `⌘ ⌥ ⇧ A` | `Ctrl + Alt + Shift + A` |
| **New Tab in Workspace Root** | `⌘ T` | `Ctrl + T` |
| **Open OMP in Workspace Root** | `⌘ ⌥ ⇧ M` | `Ctrl + Alt + Shift + M` |
| **Open Codex in Workspace Root** | `⌘ ⌥ ⇧ X` | `Ctrl + Alt + Shift + X` |
| **Open Claude in Workspace Root** | `⌘ ⌥ ⇧ C` | `Ctrl + Alt + Shift + C` |

---

## 📄 License

[MIT](LICENSE)
