--!strict
-- workspace.luau: Workspace loading, multi-folder project resolution,
-- data-driven configurable actions (tab/external), and Workspaces store.

local workspace = {}

local FILE = ".tern/workspace.json"
local HOME = tern.getenv("HOME")
local SIDES: { [string]: boolean } = { right = true, down = true, left = true, up = true }

export type SessionItem = {
	agent: string,
	title: string,
	cwd: string,
	project_root: string,
	command: string,
	updated_ms: number,
	workspace_paths: { string },
	session_files: { string },
}

export type Workspace = {
	name: string,
	root: string,
	folders: { string }?,
	tabs: { TabSpec },
	names: { string },
	icon: string?,
	sessions: { SessionItem }?,
}

export type WorkspaceRecord = {
	name: string,
	path: string,
	icon: string?,
	folders: { string }?,
	pinned: boolean?,
}

export type ActionConfig = {
	id: string,
	label: string,
	type: string, -- "tab" | "external"
	cmd: string,
	args: string?,
	tone: string?,
}

export type LaunchConfig = {
	actions: { ActionConfig },
}

-- Path without trailing slashes.
local function trim(path: string): string
	local out = string.gsub(path, "(.)/+$", "%1")
	return out
end

-- Replaces user's home prefix with ~ for clean UI display.
function workspace.tilde(path: string): string
	if HOME and string.sub(path, 1, #HOME + 1) == HOME .. "/" then
		return "~" .. string.sub(path, #HOME + 1)
	elseif HOME and path == HOME then
		return "~"
	end
	return path
end

-- Path made absolute against base; ~ is home directory.
function workspace.resolve(base: string, path: string): string
	if path == "~" or string.sub(path, 1, 2) == "~/" then
		if HOME == nil then
			error("HOME is not set, so " .. path .. " can't be resolved", 0)
		end
		return trim(HOME .. string.sub(path, 2))
	end
	if string.sub(path, 1, 1) == "/" then
		return trim(path)
	end
	path = string.gsub(path, "^%./", "")
	if path == "" or path == "." then
		return base
	end
	return trim(if base == "/" then "/" .. path else base .. "/" .. path)
end

-- The nearest directory at or above `dir` holding `.tern/workspace.json`.
function workspace.find(dir: string): string?
	local at: string? = trim(dir)
	while at do
		local candidate = if at == "/" then "/" .. FILE else at .. "/" .. FILE
		if tern.fs.exists(candidate) then
			return at
		end
		if at == "/" then
			return nil
		end
		local up = string.match(at, "^(.*)/[^/]*$")
		at = if up == nil or up == "" then "/" else up
	end
	return nil
end

-- =========================================================================
-- Data-driven Actions Configuration (commands.json)
-- =========================================================================

local function get_config_file(): string
	local data_dir = tern.plugin.data or ((HOME or "") .. "/Library/Application Support/Tern/plugin-data/workspaces")
	return data_dir .. "/commands.json"
end

function workspace.get_config_path(): string
	return get_config_file()
end

function workspace.default_launch_config(): LaunchConfig
	return {
		actions = {
			{ id = "omp", label = "omp", type = "tab", cmd = "omp", args = "", tone = "accent" },
			{ id = "codex", label = "codex", type = "tab", cmd = "codex", args = "", tone = "info" },
			{ id = "claude", label = "claude", type = "tab", cmd = "claude", args = "", tone = "warning" },
			{ id = "fork", label = "fork", type = "external", cmd = "fork", args = "", tone = "success" },
		},
	}
end

-- Reads or initializes commands.json
function workspace.get_actions(): { ActionConfig }
	local path = get_config_file()
	if tern.fs.exists(path) then
		local ok, text = pcall(tern.fs.read, path)
		if ok and text ~= "" then
			local d_ok, data = pcall(tern.json.decode, text)
			if d_ok and type(data) == "table" and type(data.actions) == "table" then
				return data.actions :: { ActionConfig }
			end
		end
	end
	local def = workspace.default_launch_config()
	pcall(function()
		local text = tern.json.encode(def, true)
		tern.fs.write(path, text)
	end)
	return def.actions
end

-- Finds action by id
function workspace.find_action(id: string): ActionConfig?
	for _, act in workspace.get_actions() do
		if act.id == id then
			return act
		end
	end
	return nil
end

-- Builds command string for tab actions (with args and multi-folder --add-dir)
function workspace.build_tab_command(act: ActionConfig, _primary_cwd: string, folders: { string }?): string
	local base_cmd = act.cmd or ""
	if base_cmd == "" and (act.args == nil or act.args == "") then
		return "" -- Clean shell
	end

	local parts: { string } = {}
	if base_cmd ~= "" then
		table.insert(parts, base_cmd)
	end
	if act.args and act.args ~= "" then
		table.insert(parts, act.args)
	end

	-- For multi-folder workspaces: add --add-dir for omp, codex, claude
	local agent_id = act.id
	if folders and #folders > 1 and (agent_id == "omp" or agent_id == "codex" or agent_id == "claude") then
		for i = 2, #folders do
			table.insert(parts, "--add-dir " .. folders[i])
		end
	end

	return table.concat(parts, " ")
end

-- =========================================================================
-- Workspace Layout Loading
-- =========================================================================

local function fail(where: string, message: string): never
	error(string.format("%s: %s", where, message), 0)
end

local function optional_string(value: any, where: string): string?
	if value ~= nil and type(value) ~= "string" then
		fail(where, "must be a string")
	end
	return value
end

local function side(value: any, where: string): Dir
	local name = optional_string(value, where) or "right"
	if not SIDES[name] then
		fail(where, "must be right, down, left or up")
	end
	return name :: Dir
end

local node: (entry: any, cwd: string, where: string) -> TabSpec

local function group(list: { any }, split: Dir, cwd: string, where: string): TabSpec
	if #list == 0 then
		return {}
	end
	local function range(from: number, to: number): TabSpec
		if from == to then
			return node(list[from], cwd, string.format("%s[%d]", where, from))
		end
		local middle = from + (to - from + 1) // 2 - 1
		return { split = split, range(from, middle), range(middle + 1, to) }
	end
	return range(1, #list)
end

node = function(entry: any, cwd: string, where: string): TabSpec
	if type(entry) ~= "table" then
		fail(where, "must be an object")
	end
	local own = optional_string(entry.cwd, where .. ".cwd")
	local here = if own then workspace.resolve(cwd, own) else cwd
	if entry.panes ~= nil then
		if type(entry.panes) ~= "table" then
			fail(where .. ".panes", "must be an array")
		end
		local spec = group(entry.panes, side(entry.split, where .. ".split"), here, where .. ".panes")
		spec.cwd = spec.cwd or here
		return spec
	end
	local command = optional_string(entry.command, where .. ".command")
	local block = optional_string(entry.block, where .. ".block")
	if command and block then
		fail(where, "has both command and block")
	end
	local args: { string }? = nil
	if entry.args ~= nil then
		if block == nil then
			fail(where .. ".args", "only blocks take args")
		end
		if type(entry.args) ~= "table" then
			fail(where .. ".args", "must be an array of strings")
		end
		args = {}
		for i, arg in entry.args do
			table.insert(args :: { string }, optional_string(arg, string.format("%s.args[%d]", where, i)) :: string)
		end
	end
	return { cwd = here, launch = { command = command, block = block, args = args } }
end

function workspace.load(root: string): Workspace
	local path = root .. "/" .. FILE
	local ok, text = pcall(tern.fs.read, path)
	if not ok then
		fail(path, "can't be read")
	end
	local decoded, data = pcall(tern.json.decode, text)
	if not decoded then
		fail(path, "isn't valid JSON (" .. tostring(data) .. ")")
	end
	if type(data) ~= "table" then
		fail(path, "must hold an object")
	end
	local folder = string.match(root, "([^/]+)$") or root
	local name = optional_string(data.name, "name") or folder
	if type(data.tabs) ~= "table" or #data.tabs == 0 then
		fail("tabs", "must be a non-empty array")
	end
	local tabs: { TabSpec } = {}
	local names: { string } = {}
	for i, tab in data.tabs do
		local where = string.format("tabs[%d]", i)
		if type(tab) ~= "table" then
			fail(where, "must be an object")
		end
		local cwd = workspace.resolve(root, optional_string(tab.cwd, where .. ".cwd") or ".")
		local panes = tab.panes or {}
		if type(panes) ~= "table" then
			fail(where .. ".panes", "must be an array")
		end
		local spec = group(panes, side(tab.split, where .. ".split"), cwd, where .. ".panes")
		spec.cwd = spec.cwd or cwd
		spec.name = optional_string(tab.name, where .. ".name")
		if spec.name then
			table.insert(names, spec.name :: string)
		end
		table.insert(tabs, spec)
	end
	return { name = name, root = root, tabs = tabs, names = names }
end

function workspace.load_or_default(root: string, custom_name: string?): Workspace
	local config_path = root .. "/" .. FILE
	if tern.fs.exists(config_path) then
		return workspace.load(root)
	end
	local folder = string.match(root, "([^/]+)$") or root
	local name = custom_name or folder
	local spec: TabSpec = {
		name = name,
		cwd = root,
		launch = { cwd = root },
	}
	return {
		name = name,
		root = root,
		tabs = { spec },
		names = { name },
	}
end

-- =========================================================================
-- Workspaces Store
-- =========================================================================
local KV_KEY = "workspaces"

-- Retrieves user-saved workspaces, migrating any legacy favorites key
function workspace.get_user_workspaces(): { WorkspaceRecord }
	local stored = tern.kv.get(KV_KEY)
	if stored == nil then
		local old_favs = tern.kv.get("favorites")
		if type(old_favs) == "table" then
			local migrated: { WorkspaceRecord } = {}
			local home = HOME or ""
			for _, item in old_favs do
				if type(item) == "table" and type(item.path) == "string" then
					local p = item.path
					-- Drop system default folders, only keep user project paths
					if p ~= home .. "/Documents" and p ~= home .. "/Desktop" and p ~= home .. "/Downloads" then
						table.insert(migrated, {
							name = item.name or string.match(p, "([^/]+)$") or p,
							path = trim(p),
							icon = "folder",
						})
					end
				end
			end
			tern.kv.set(KV_KEY, migrated)
			tern.kv.set("favorites", nil)
			stored = migrated
		end
	end

	if type(stored) == "table" then
		local out: { WorkspaceRecord } = {}
		for _, raw in stored do
			if type(raw) == "table" and type(raw.path) == "string" then
				table.insert(out, {
					name = raw.name or string.match(raw.path, "([^/]+)$") or raw.path,
					path = trim(raw.path),
					icon = raw.icon or "folder",
					folders = raw.folders,
					pinned = if raw.pinned == true then true else nil,
				})
			end
		end
		return out
	end
	return {}
end

function workspace.get_workspaces(): { WorkspaceRecord }
	return workspace.get_user_workspaces()
end

-- Session discovery runs off the host thread and returns only native metadata.
function workspace.get_recent_sessions(callback: (sessions: { SessionItem }, err: string?) -> ())
	local ok, err = pcall(function()
		local paths: { string } = {}
		for _, entry in workspace.get_workspaces() do
			table.insert(paths, entry.path)
		end
		tern.process.run({ "python3", tern.plugin.dir .. "/sessions.py", tern.json.encode(tern.json.array(paths)) }, { timeout_ms = 15000 }, function(result)
			if result.status ~= 0 then
				callback({}, if result.timed_out then "Session discovery timed out" else "Session discovery failed")
				return
			end
			local decoded, data = pcall(tern.json.decode, result.stdout)
			if not decoded or type(data) ~= "table" then
				callback({}, "Invalid session discovery output")
				return
			end
			local sessions: { SessionItem } = {}
			for _, item in data do
				if type(item) ~= "table" or type(item.agent) ~= "string" or type(item.title) ~= "string"
					or type(item.cwd) ~= "string" or type(item.project_root) ~= "string"
					or type(item.command) ~= "string" or type(item.updated_ms) ~= "number"
					or type(item.workspace_paths) ~= "table" or type(item.session_files) ~= "table" then
					callback({}, "Invalid session discovery output")
					return
				end
				for _, paths in { item.workspace_paths, item.session_files } do
					for _, path in paths do
						if type(path) ~= "string" then
							callback({}, "Invalid session discovery output")
							return
						end
					end
				end
				table.insert(sessions, item :: SessionItem)
			end
			callback(sessions, nil)
		end)
	end)
	if not ok then
		callback({}, "Could not start session discovery: " .. tostring(err))
	end
end


function workspace.save_user_workspaces(list: { WorkspaceRecord })
	tern.kv.set(KV_KEY, list)
end

function workspace.add_workspace(path: string, custom_name: string?): WorkspaceRecord
	local resolved = workspace.resolve("/", path)
	local list = workspace.get_user_workspaces()
	for _, w in list do
		if w.path == resolved then
			if custom_name ~= nil then
				w.name = custom_name
				workspace.save_user_workspaces(list)
			end
			return w
		end
	end
	local rec: WorkspaceRecord = {
		name = custom_name or string.match(resolved, "([^/]+)$") or resolved,
		path = resolved,
		icon = "folder",
	}
	table.insert(list, rec)
	workspace.save_user_workspaces(list)
	return rec
end

function workspace.set_pinned(path: string, pinned: boolean): boolean
	local resolved = workspace.resolve("/", path)
	local list = workspace.get_user_workspaces()
	for _, entry in list do
		if entry.path == resolved then
			if (entry.pinned == true) ~= pinned then
				entry.pinned = if pinned then true else nil
				workspace.save_user_workspaces(list)
			end
			return true
		end
	end
	return false
end

function workspace.remove_workspace(path_or_name: string): boolean
	local list = workspace.get_user_workspaces()
	local resolved = workspace.resolve("/", path_or_name)
	local new_list: { WorkspaceRecord } = {}
	local removed = false
	for _, w in list do
		if w.path == resolved or w.name == path_or_name then
			removed = true
		else
			table.insert(new_list, w)
		end
	end

	if removed then
		workspace.save_user_workspaces(new_list)
	end

	return removed
end

return workspace
