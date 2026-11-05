--!strict
-- window.luau: Window half for Tern Workspaces.
-- Provides persistent workspace sidebar list, picker,
-- root-locked tab enforcement, and generalized data-driven action execution
-- for tab agents (terminal, omp, codex, claude) and external tools (fork, etc.).

local workspace = require("./workspace")
local sidebar = require("./sidebar")

local PICKER_CMD = "plugin.workspaces.picker"
local SIDEBAR_CMD = "plugin.workspaces.sidebar"
local ADD_WS_CMD = "plugin.workspaces.add_workspace"
local OPEN_OMP_CMD = "plugin.workspaces.open_omp"
local OPEN_CODEX_CMD = "plugin.workspaces.open_codex"
local OPEN_CLAUDE_CMD = "plugin.workspaces.open_claude"
local OPEN_SHELL_CMD = "plugin.workspaces.open_shell"
local CONFIGURE_CMD = "plugin.workspaces.configure"
local EDIT_CMD = "plugin.workspaces.edit"

-- Live status crosses to host blocks as events, never as persisted workspace data.
local sidebar_status: { [number]: string } = {}
local live_files: { [number]: string } = {}
local live_signature = "[]"
local inspection_pending = false

local function sync_omp_status(cx: WindowCx, force: boolean?, refresh_history: boolean?): boolean
	local panes = cx.session:panes()
	local sidebars = sidebar.panes()
	local by_pane: { [number]: PaneInfo } = {}
	for _, pane in panes do
		by_pane[pane.pane] = pane
	end
	if #sidebars == 0 then
		table.clear(sidebar_status)
		table.clear(live_files)
		live_signature = "[]"
		return false
	end

	local bindings = tern.kv.get("workspace_sessions:" .. cx:window_key()) or {}
	local sessions: { [number]: ManagedSession } = {}
	for _, session in cx.sessions:list() do
		sessions[session.id] = session
	end
	local roots: { [number]: string } = {}
	for root, binding in bindings do
		local session = sessions[binding.id]
		if session and session.host == binding.host then
			roots[session.id] = root
		end
	end
	local root_of_tab: { [number]: string } = {}
	for _, tab in cx.session:tabs() do
		root_of_tab[tab.id] = roots[tab.session]
	end
	local status: { [string]: { [string]: number } } = {}
	local session_status: { [string]: { [string]: number } } = {}
	for _, agent in cx.agents:list() do
		-- The bulk pane listing is session-scoped; agent ids span the whole window.
		local pane = by_pane[agent.pane] or cx.session:pane(agent.pane)
		local root = if pane and pane.tab then root_of_tab[pane.tab] else nil
		-- Shell-launched OMP can retain the shell program and omit agent.command.
		if not pane or (pane.program ~= "omp" and agent.command ~= "omp" and not live_files[agent.pane]) then
			continue
		end
		local mark = if agent.state == "waiting_input" then "waiting"
			elseif agent.state == "working" then "working"
			elseif agent.state == "idle" and pane.alert then "finished"
			else nil
		if mark then
			if root then
				local counts = status[root]
				if not counts then
					counts = {}
					status[root] = counts
				end
				counts[mark] = (counts[mark] or 0) + 1
			end
			local file = live_files[agent.pane]
			if file then
				local counts = session_status[file]
				if not counts then
					counts = {}
					session_status[file] = counts
				end
				counts[mark] = (counts[mark] or 0) + 1
			end
		end
	end
	local payload = tern.json.encode({ workspaces = status, sessions = session_status })
	local sent: { [number]: string } = {}
	for _, pane in sidebars do
		if not force and sidebar_status[pane] == payload then
			sent[pane] = payload
		else
			-- Listed plugin panes can still be starting or already closing on the host.
			local ok, err = pcall(function()
				cx.session:event(pane, { ev = "action", act = "omp_status", text = payload, refresh_history = refresh_history == true })
			end)
			if ok then
				sent[pane] = payload
			else
				tern.log.debug("Workspace status delivery pending", pane, err)
			end
		end
	end
	sidebar_status = sent
	return true
end

local function inspect_live_sessions(callback: (files: { [number]: string }?, signature: string?, cx: WindowCx?) -> ())
	tern.process.run({ "python3", tern.plugin.dir .. "/sessions.py", "--live" }, { timeout_ms = 3000 }, function(result: ProcessResult, cx: WindowCx?)
		local decoded, data = pcall(tern.json.decode, result.stdout)
		if result.status ~= 0 or not decoded or type(data) ~= "table" then
			tern.log.debug("Live OMP session inspection unavailable", result.stderr)
			callback(nil, nil, cx)
			return
		end
		local files: { [number]: string } = {}
		for index, entry in data do
			if type(index) ~= "number" or type(entry) ~= "table" or type(entry.pane) ~= "number"
				or type(entry.file) ~= "string" then
				callback(nil, nil, cx)
				return
			end
			files[entry.pane] = entry.file
		end
		callback(files, result.stdout, cx)
	end)
end

local function refresh_live_sessions()
	if inspection_pending then
		return
	end
	inspection_pending = true
	local ok, err = pcall(function()
		inspect_live_sessions(function(files, signature, cx)
			inspection_pending = false
			local current = signature or "[]"
			local changed = current ~= live_signature
			live_signature = current
			live_files = files or {}
			if cx then
				sync_omp_status(cx, changed, changed)
			end
		end)
	end)
	if not ok then
		inspection_pending = false
		table.clear(live_files)
		live_signature = "[]"
		tern.log.debug("Could not start live OMP session inspection", err)
	end
end

-- URL decode helper
local function url_decode(str: string): string
	local decoded = string.gsub(str, "%%(%x%x)", function(hex)
		return string.char(tonumber(hex, 16) or 0)
	end)
	return decoded
end

type WorkspaceGroup = { name: string, root: string }

-- Derived from the current session; the persistent binding owns group membership.
local active_group: WorkspaceGroup? = nil

local function active_owner(cx: WindowCx): WorkspaceGroup?
	local bindings = tern.kv.get("workspace_sessions:" .. cx:window_key())
	if type(bindings) ~= "table" then
		return nil
	end
	local current = cx.sessions:current()
	for root, binding in bindings do
		if binding.id == current.id and binding.host == current.host then
			return { name = current.name, root = root }
		end
	end
	return nil
end

local function focus_content(cx: WindowCx)
	local focused = cx.session:focused()
	local info = if focused then cx.session:pane(focused) else nil
	if info and info.block == sidebar.kind then
		for _, pane in cx.session:panes() do
			if pane.tab == info.tab and pane.block ~= sidebar.kind then
				cx.layout:focus(pane.pane)
				return
			end
		end
	end
end

-- Returns the working directory of the currently focused pane.
local function focused_cwd(cx: WindowCx): string?
	local id = cx.session:focused()
	local focused = if id then cx.session:pane(id) else nil
	if not focused then return nil end
	if focused.block == sidebar.kind then
		for _, pane in cx.session:panes() do
			if pane.tab == focused.tab and pane.block ~= sidebar.kind and pane.cwd and pane.cwd ~= "" then
				return pane.cwd
			end
		end
		return nil
	end
	return if focused.cwd ~= "" then focused.cwd else nil
end

-- Custom layouts only seed newly created sessions.
local function build(cx: WindowCx, w: workspace.Workspace): boolean
	local count = 0
	local problems: { string } = {}

	for _, spec in w.tabs do
		local tab, err = cx.layout:tab(spec)
		if tab then
			count += 1
		end
		if err then
			table.insert(problems, err)
		end
	end

	if count == 0 then
		local why = if #problems > 0 then table.concat(problems, "; ") else workspace.tilde(w.root)
		cx:toast("error", "Workspace " .. w.name .. " opened no tabs", why)
		return false
	end

	if #problems > 0 then
		cx:toast("warning", "Opened " .. w.name .. " (incomplete)", table.concat(problems, "; "))
	else
		cx:toast("success", "Workspace: " .. w.name, string.format("%d tabs · %s", count, workspace.tilde(w.root)))
	end
	return true
end

-- Each saved project owns a Tern session; never adopt unrelated existing sessions.
local function open_at(cx: WindowCx, root: string, custom_name: string?): boolean
	if custom_name == nil then
		for _, record in workspace.get_workspaces() do
			if record.path == root then
				custom_name = record.name
				break
			end
		end
	end
	local bindings_key = "workspace_sessions:" .. cx:window_key()
	local bindings = tern.kv.get(bindings_key)
	if type(bindings) ~= "table" then
		bindings = {}
	end
	local binding = bindings[root]
	local host = cx.sessions:current().host
	if type(binding) == "table" then
		for _, session in cx.sessions:list() do
			if session.host == host and session.id == binding.id then
				cx.sessions:switch(session.id)
				focus_content(cx)
				active_group = active_owner(cx)
				tern.chrome.refresh()
				return true
			end
		end
	end
	local name = custom_name or string.match(root, "([^/]+)$") or root
	local layout: workspace.Workspace? = nil
	if tern.fs.exists(root .. "/.tern/workspace.json") then
		local ok, result = pcall(workspace.load, root)
		if not ok then
			cx:toast("error", "Could not open workspace", tostring(result))
			return false
		end
		layout = result
	end
	local session = cx.sessions:create({ name = name, cwd = root })
	bindings[root] = { id = session.id, host = session.host }
	tern.kv.set(bindings_key, bindings)
	if layout then
		local initial = cx.session:focused()
		if build(cx, layout) and initial then
			cx.layout:close(initial)
		end
	end
	active_group = active_owner(cx)
	tern.chrome.refresh()
	return true
end

local function ensure_sidebar(cx: WindowCx)
	sidebar.sync(cx)
end

local function resume_chat(cx: WindowCx, root: string, cwd: string, command: string)
	if open_at(cx, root) then
		cx.layout:new_tab({ name = "Resume Chat", cwd = cwd, command = command })
	end
end

local pending_chats: { [string]: boolean } = {}

local function open_chat(cx: WindowCx, root: string, cwd: string, command: string, files: { string })
	if #files == 0 then
		resume_chat(cx, root, cwd, command)
		return
	end
	if pending_chats[command] then
		return
	end
	pending_chats[command] = true
	local wanted: { [string]: boolean } = {}
	for _, file in files do
		wanted[file] = true
	end
	local ok, err = pcall(function()
		inspect_live_sessions(function(open_files, _signature, fresh)
			pending_chats[command] = nil
			if not fresh then
				return
			end
			if not open_files then
				fresh:toast("error", "Could not open chat", "Please try again.")
				return
			end
			local current = fresh.session:focused()
			local target: number? = nil
			for pane, file in open_files do
				if wanted[file] and fresh.session:pane(pane) then
					if pane == current then
						target = pane
						break
					end
					if target == nil or pane < target then
						target = pane
					end
				end
			end
			if target then
				local focused, reason = pcall(function()
					fresh.layout:focus(target)
				end)
				if not focused then
					tern.log.debug("Could not focus open chat", reason)
					fresh:toast("error", "Could not open chat", "Please try again.")
					return
				end
				active_group = active_owner(fresh)
				ensure_sidebar(fresh)
				tern.chrome.refresh()
				return
			end
			resume_chat(fresh, root, cwd, command)
		end)
	end)
	if not ok then
		pending_chats[command] = nil
		tern.log.debug("Could not inspect chat before opening", err)
		cx:toast("error", "Could not open chat", "Please try again.")
	end
end


tern.on("focus", function(_ev: FocusEvent, cx: WindowCx)
	active_group = active_owner(cx)
	tern.chrome.refresh()
	ensure_sidebar(cx)
	sync_omp_status(cx)
end)

tern.on("tab_created", function(_ev: TabEvent, cx: WindowCx)
	ensure_sidebar(cx)
end)


-- Helper to find folders for a workspace root
local function find_folders_for_root(root: string): { string }?
	for _, ws in workspace.get_workspaces() do
		if ws.path == root then
			return ws.folders
		end
	end
	return nil
end

-- Generalized Action Executor (tab or external) with robust process execution
local function execute_action(act: workspace.ActionConfig, path: string, cx: WindowCx)
	if act.type == "external" then
		local cmd_name = if act.cmd ~= "" then act.cmd else act.id
		local label = act.label or act.id

		local function try_open_app()
			local open_args = { "/usr/bin/open", "-a", cmd_name, path }
			local ok2, _ = pcall(tern.process.run, open_args, {}, function(res2)
				if res2.status == 0 then
					cx:toast("success", "Opened in " .. label, workspace.tilde(path))
				else
					cx:toast("error", "Could not open in " .. label, res2.stderr or "Check if app is installed")
				end
			end)
			if not ok2 then
				cx:toast("error", "Could not launch " .. label)
			end
		end

		local candidates = {
			cmd_name,
			"/usr/local/bin/" .. cmd_name,
			"/opt/homebrew/bin/" .. cmd_name,
		}

		local function try_candidate(idx: number)
			if idx > #candidates then
				try_open_app()
				return
			end
			local bin = candidates[idx]
			local argv = { bin }
			if act.args and act.args ~= "" then
				for arg in string.gmatch(act.args, "%S+") do
					table.insert(argv, arg)
				end
			end
			table.insert(argv, path)

			local ok, _ = pcall(tern.process.run, argv, {}, function(res)
				if res.status == 0 then
					cx:toast("success", "Opened in " .. label, workspace.tilde(path))
				else
					try_candidate(idx + 1)
				end
			end)

			if not ok then
				try_candidate(idx + 1)
			end
		end

		try_candidate(1)
	else
		-- Tab action
		if not open_at(cx, path) then
			return
		end
		local folders = find_folders_for_root(path)
		local cmd = workspace.build_tab_command(act, path, folders)
		if act.id == "terminal" and cmd == "" then
			cx.layout:new_tab({ cwd = path })
		else
			cx.layout:new_tab({
				name = (string.match(path, "([^/]+)$") or path) .. " (" .. act.label .. ")",
				cwd = path,
				command = if cmd ~= "" then cmd else nil,
			})
		end
	end
end

-- =========================================================================
-- Commands & Keybinds
-- =========================================================================

-- Toggle Workspaces Sidebar (List UI)
tern.command({
	id = "sidebar",
	title = "Workspaces: Toggle Sidebar (List View)",
	icon = "sidebar-left",
	group = "Workspaces",
	keys = if tern.runtime.os == "macos" then { "cmd+alt+b" } else { "ctrl+alt+b" },
	run = function(cx: WindowCx)
		sidebar.toggle(cx)
	end,
})

-- Main Picker: Searchable Workspaces modal
tern.command({
	id = "picker",
	title = "Workspaces: Switch Workspace (Picker)...",
	icon = "folder",
	group = "Workspaces",
	keys = { if tern.runtime.os == "macos" then "cmd+alt+shift+o" else "ctrl+alt+shift+o" },
	run = function(cx: WindowCx)
		local workspaces_list = workspace.get_workspaces()
		local items: { PickItem } = {}
		local cwd = focused_cwd(cx)
		local current_entry = active_owner(cx)
		local bindings = tern.kv.get("workspace_sessions:" .. cx:window_key()) or {}
		local live: { [number]: boolean } = {}
		for _, session in cx.sessions:list() do
			live[session.id] = true
		end

		for _, ws in workspaces_list do
			local is_active = (current_entry and current_entry.root == ws.path) or false
			local binding = bindings[ws.path]
			local is_open = binding ~= nil and live[binding.id] == true
			local status = if is_active then " (Active)" elseif is_open then " (Open)" else ""
			table.insert(items, {
				label = ws.name,
				detail = workspace.tilde(ws.path) .. status,
				icon = ws.icon or "folder",
				path = ws.path,
				current = is_active,
			})
		end

		if cwd then
			local already_in = false
			for _, ws in workspaces_list do
				if ws.path == cwd then
					already_in = true
					break
				end
			end
			if not already_in then
				table.insert(items, {
					label = "+ Add Current Directory as Workspace",
					detail = workspace.tilde(cwd),
					icon = "plus",
					path = cwd,
					is_add_action = true,
				})
			end
		end

		if #items == 0 then
			cx:toast("info", "No workspaces yet", "Use 'Add Current Workspace' to add your first project")
			return
		end

		cx:pick({
			placeholder = "Search or select a workspace...",
			icon = "folder",
			items = items,
			action = "open",
		}):next(function(choice: PickItem?, _err: string?, post_cx: WindowCx?)
			if post_cx == nil or choice == nil then
				return
			end
			local chosen_path = choice.path :: string
			if choice.is_add_action then
				local rec = workspace.add_workspace(chosen_path)
				post_cx:toast("success", "Added Workspace", rec.name)
				open_at(post_cx, rec.path, rec.name)
			else
				open_at(post_cx, chosen_path, choice.label)
			end
		end)
	end,
})

-- Add Current Folder to Workspaces
tern.command({
	id = "add_workspace",
	title = "Workspaces: Add current folder to Workspaces",
	icon = "folder-plus",
	group = "Workspaces",
	keys = { if tern.runtime.os == "macos" then "cmd+alt+shift+a" else "ctrl+alt+shift+a" },
	run = function(cx: WindowCx)
		local cwd = focused_cwd(cx)
		if cwd == nil then
			cx:toast("error", "No active directory to add")
			return
		end
		local rec = workspace.add_workspace(cwd)
		cx:toast("success", "Added Workspace", string.format("%s (%s)", rec.name, workspace.tilde(rec.path)))
	end,
})

-- Remove Current Folder from Workspaces
tern.command({
	id = "remove_workspace",
	title = "Workspaces: Remove current folder from Workspaces",
	icon = "trash",
	group = "Workspaces",
	run = function(cx: WindowCx)
		local cwd = focused_cwd(cx)
		if cwd == nil then
			return
		end
		local removed = workspace.remove_workspace(cwd)
		if removed then
			cx:toast("info", "Removed from Workspaces", workspace.tilde(cwd))
		else
			cx:toast("info", "Folder is not in Workspaces", workspace.tilde(cwd))
		end
	end,
})

-- Open Terminal Shell in Current Workspace
tern.command({
	id = "open_shell",
	title = "Workspaces: Open Terminal in workspace root",
	icon = "terminal",
	group = "Workspaces",
	run = function(cx: WindowCx)
		local cwd = focused_cwd(cx)
		local entry = active_owner(cx)
		local root = if entry then entry.root else cwd
		if root == nil then
			cx:toast("error", "No workspace directory")
			return
		end
		local act = workspace.find_action("terminal") or { id = "terminal", label = "terminal", type = "tab", cmd = "", args = "" }
		execute_action(act, root, cx)
	end,
})

-- Open OMP in Current Workspace
tern.command({
	id = "open_omp",
	title = "Workspaces: Open OMP in workspace root",
	icon = "sparkle",
	group = "Workspaces",
	keys = { if tern.runtime.os == "macos" then "cmd+alt+shift+m" else "ctrl+alt+shift+m" },
	run = function(cx: WindowCx)
		local cwd = focused_cwd(cx)
		local entry = active_owner(cx)
		local root = if entry then entry.root else cwd
		if root == nil then
			cx:toast("error", "No workspace directory")
			return
		end
		local act = workspace.find_action("omp") or { id = "omp", label = "omp", type = "tab", cmd = "omp", args = "" }
		execute_action(act, root, cx)
	end,
})

-- Open Codex in Current Workspace
tern.command({
	id = "open_codex",
	title = "Workspaces: Open Codex in workspace root",
	icon = "code",
	group = "Workspaces",
	keys = { if tern.runtime.os == "macos" then "cmd+alt+shift+x" else "ctrl+alt+shift+x" },
	run = function(cx: WindowCx)
		local cwd = focused_cwd(cx)
		local entry = active_owner(cx)
		local root = if entry then entry.root else cwd
		if root == nil then
			cx:toast("error", "No workspace directory")
			return
		end
		local act = workspace.find_action("codex") or { id = "codex", label = "codex", type = "tab", cmd = "codex", args = "" }
		execute_action(act, root, cx)
	end,
})

-- Open Claude in Current Workspace
tern.command({
	id = "open_claude",
	title = "Workspaces: Open Claude in workspace root",
	icon = "sparkle",
	group = "Workspaces",
	keys = { if tern.runtime.os == "macos" then "cmd+alt+shift+c" else "ctrl+alt+shift+c" },
	run = function(cx: WindowCx)
		local cwd = focused_cwd(cx)
		local entry = active_owner(cx)
		local root = if entry then entry.root else cwd
		if root == nil then
			cx:toast("error", "No workspace directory")
			return
		end
		local act = workspace.find_action("claude") or { id = "claude", label = "claude", type = "tab", cmd = "claude", args = "" }
		execute_action(act, root, cx)
	end,
})

-- Configure Launch Commands (commands.json)
tern.command({
	id = "configure",
	title = "Workspaces: Configure Launch Commands (JSON)",
	icon = "settings",
	group = "Workspaces",
	run = function(cx: WindowCx)
		local path = workspace.get_config_path()
		workspace.get_actions()
		cx:open(path, "beside")
	end,
})

-- Edit .tern/workspace.json
tern.command({
	id = "edit",
	title = "Workspaces: Edit .tern/workspace.json",
	icon = "folder",
	group = "Workspaces",
	run = function(cx: WindowCx)
		local cwd = focused_cwd(cx)
		local root = if cwd then workspace.find(cwd) else nil
		if root == nil then
			cx:toast("error", "No workspace file", "No .tern/workspace.json above this pane")
			return
		end
		cx:open(root .. "/.tern/workspace.json", "beside")
	end,
})

-- =========================================================================
-- Route Links from Sidebar Block (Handling Clicks & Chat Resumes)
-- =========================================================================

tern.route.link(function(link: LinkRequest, cx: WindowCx): RouteDecision?
	local route, query = string.match(link.url, "^workspaces://([%a_]+)%??(.*)$")
	if route == nil then
		return nil
	end

	if route == "omp_status" then
		sync_omp_status(cx, true)
		return { handled = true }
	end

	if route == "add_current" then
		local cwd = focused_cwd(cx)
		if cwd then
			local rec = workspace.add_workspace(cwd)
			cx:toast("success", "Added Workspace", rec.name)
		end
		return { handled = true }
	end

	if route == "config" then
		local path = workspace.get_config_path()
		workspace.get_actions()
		cx:open(path, "beside")
		return { handled = true }
	end

	-- Existing OMP panes take precedence over launching a resume command.
	if route == "resume" then
		local cwd = url_decode(string.match(query or "", "cwd=([^&]*)") or "")
		local cmd = url_decode(string.match(query or "", "cmd=([^&]*)") or "")
		local root = url_decode(string.match(query or "", "root=([^&]*)") or "")
		if cwd ~= "" and cmd ~= "" and root ~= "" then
			local decoded, files = pcall(tern.json.decode, url_decode(string.match(query or "", "files=([^&]*)") or "[]"))
			if not decoded or type(files) ~= "table" then
				cx:toast("error", "Could not open chat", "Please try again.")
				return { handled = true }
			end
			for index, file in files do
				if type(index) ~= "number" or type(file) ~= "string" or string.sub(file, 1, 1) ~= "/" then
					cx:toast("error", "Could not open chat", "Please try again.")
					return { handled = true }
				end
			end
			open_chat(cx, root, cwd, cmd, files)
		end
		return { handled = true }
	end

	-- Data-driven action execution: workspaces://action?id=...&path=...
	if route == "action" then
		local act_id = url_decode(string.match(query or "", "id=([^&]*)") or "")
		local path = url_decode(string.match(query or "", "path=([^&]*)") or "")
		if act_id ~= "" and path ~= "" then
			local act = workspace.find_action(act_id)
			if act then
				execute_action(act, path, cx)
			else
				cx:toast("error", "Unknown action", act_id)
			end
		end
		return { handled = true }
	end

	if route == "open" then
		local path = url_decode(string.match(query or "", "path=([^&]*)") or "")
		if path ~= "" then
			open_at(cx, path)
		end
		return { handled = true }
	end

	return { handled = true }
end)

-- =========================================================================
-- Enforcement: Root-locked Tab Creation
-- =========================================================================

-- When a pane is inside an active workspace, pressing Cmd+T / New Tab
-- opens a tab strictly in that workspace's root directory.
tern.override("new_tab", function(cx: WindowCx): boolean
	local entry = active_owner(cx)
	if entry == nil then
		return false -- Not inside an active workspace, run Tern default
	end
	return cx.layout:new_tab({ cwd = entry.root }) ~= nil
end)

-- =========================================================================
-- Status Line Segment
-- =========================================================================

-- Shows the active workspace's name in the status line. Clicking toggles sidebar.
tern.chrome.status(function(_pane: StatusPaneInfo): { StatusSegment }?
	local entry = active_group
	if entry == nil then
		return nil
	end
	return {
		{
			text = entry.name,
			icon = "folder",
			tone = "accent",
			command = SIDEBAR_CMD,
		},
	}
end)

-- =========================================================================
-- Window Lifecycle & Session Adoption
-- =========================================================================

-- Reloads replace the VM without repeating window_start.
tern.timer(0, function(cx: WindowCx?)
	if cx then
		active_group = active_owner(cx)
		ensure_sidebar(cx)
		tern.chrome.refresh()
	end
end)

for _, event in { "agent_state", "agent_finished", "pane_closed", "tab_closed", "session_ended" } do
	tern.on(event, function(_ev: any, cx: WindowCx)
		sidebar.sync(cx)
		sync_omp_status(cx)
	end)
end

local function poll_omp_status(cx: WindowCx?)
	tern.timer(1000, poll_omp_status)
	if cx then sidebar.sync(cx) end
	if cx and sync_omp_status(cx) then
		refresh_live_sessions()
	end
end
tern.timer(1000, poll_omp_status)

tern.on("window_start", function(cx: WindowCx)
	local target = tern.getenv("TERN_WORKSPACE")
	if target and target ~= "" then
		local root = workspace.resolve("/", target)
		root = string.gsub(root, "/%.tern/workspace%.json$", "")
		open_at(cx, root)
	end
	ensure_sidebar(cx)
end)
