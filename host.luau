--!strict
-- host.luau: Host half defining the "sidebar" Workspaces List Block.
-- Completely data-driven: renders action badges based on commands.json.
-- Unified Workspaces view only (no redundant favorites concept).

local workspace = require("./workspace")
local ui = tern.ui

local OMP_STATES = {
	{ "waiting", "Waiting", "warning", "help" },
	{ "working", "Working", "info", "orbit" },
	{ "finished", "Finished", "success", "check" },
}

local function has_omp_status(counts: { [string]: number }?): boolean
	if type(counts) == "table" then
		for _, mark in OMP_STATES do
			local count = counts[mark[1]]
			if type(count) == "number" and count > 0 then
				return true
			end
		end
	end
	return false
end

local function append_omp_status(nodes: { Node }, counts: { [string]: number }?, key: string)
	if type(counts) ~= "table" then
		return
	end
	for _, mark in OMP_STATES do
		local count = counts[mark[1]]
		if type(count) == "number" and count > 0 then
			local label = "OMP: " .. mark[2]
			local indicator = if mark[1] == "working"
				then ui.node("spinner", { style = mark[4], tone = mark[3], aria = label })
				else ui.node("icon", { name = mark[4], tone = mark[3], aria = label })
			local icons = { indicator }
			if count > 1 then
				label ..= " " .. tostring(count)
				table.insert(icons, ui.text({ ui.span(tostring(count), mark[3]) }))
			end
			table.insert(nodes, ui.node("row", {
				key = key .. ":" .. mark[1],
				role = "workspaces-status-" .. mark[1],
				title = label,
				gap = "none",
				shrink = 0,
			}, icons))
		end
	end
end

local function append_section(nodes: { Node }, projects: { Node }, label: string, key: string)
	if #projects == 0 then
		return
	end
	local count = ui.badge(tostring(#projects), "default")
	count.p = count.p or {}
	count.p.role = "workspaces-section-count"
	table.insert(nodes, ui.node("row", { key = "section:" .. key, role = "workspaces-section-heading" }, {
		ui.text({ ui.span(label, "default") }), count,
	}))
	for _, project in projects do
		table.insert(nodes, project)
	end
end

local function url_encode(str: string): string
	return (string.gsub(str, "([^%w_%-%.~])", function(c)
		return string.format("%%%02X", string.byte(c))
	end))
end

-- Tern delivers dropped paths as paste keys with backslash-escaped characters.
local function dropped_paths(text: string): { string }?
	local paths: { string } = {}
	local chars: { string } = {}
	local escaped = false
	for i = 1, #text do
		local char = string.sub(text, i, i)
		if escaped then
			table.insert(chars, char)
			escaped = false
		elseif char == "\\" then
			escaped = true
		elseif string.match(char, "%s") then
			if #chars > 0 then
				table.insert(paths, table.concat(chars))
				table.clear(chars)
			end
		else
			table.insert(chars, char)
		end
	end
	if escaped then
		return nil
	end
	if #chars > 0 then
		table.insert(paths, table.concat(chars))
	end
	return if #paths > 0 then paths else nil
end

type SidebarState = {
	sessions: { workspace.SessionItem },
	refreshing: boolean,
	refresh_pending: boolean,
	query: string,
	cursor: number,
	anchor: number?,
	filter_focused: boolean,
	omp_status: { [string]: { [string]: number } },
	omp_session_status: { [string]: { [string]: number } },
}

local function refresh_sessions(state: SidebarState, cx: BlockCx)
	if state.refreshing then
		state.refresh_pending = true
		return
	end
	state.refreshing = true
	workspace.get_recent_sessions(function(sessions, err)
		state.refreshing = false
		if state.refresh_pending then
			state.refresh_pending = false
			refresh_sessions(state, cx)
			return
		end
		if err then
			cx:toast("error", "Could not refresh sessions", err)
		else
			state.sessions = sessions
		end
		cx:render()
	end)
end

-- Native input offsets use UTF-16; Luau string slicing uses UTF-8 byte indices.
local function byte_index(text: string, offset: number): number
	local units = 0
	for byte, codepoint in utf8.codes(text) do
		local width = if codepoint > 0xFFFF then 2 else 1
		if units + width > offset then return byte end
		units += width
	end
	return #text + 1
end

local function utf16_offset(text: string, at: number): number
	local units = 0
	for byte, codepoint in utf8.codes(text) do
		if byte >= at then break end
		units += if codepoint > 0xFFFF then 2 else 1
	end
	return units
end

tern.block.define("sidebar", {
	features = { "edit" },
	init = function(cx: BlockCx, _args: { string }?, _saved: any?): SidebarState
		local state: SidebarState = {
			sessions = {},
			refreshing = false,
			refresh_pending = false,
			query = "",
			cursor = 1,
			filter_focused = false,
			omp_status = {},
			omp_session_status = {},
		}
		refresh_sessions(state, cx)
		cx:open("workspaces://omp_status")

		return state
	end,

	title = function(_state: SidebarState): string
		return "Workspaces"
	end,

	view = function(state: SidebarState, _cx: BlockCx): { main: Node? }
		local workspaces_list = workspace.get_workspaces()
		local query = string.lower(state.query)
		local actions = workspace.get_actions()
		local sessions = state.sessions
		local counts_by_session: { [number]: { [string]: number } } = {}
		local session_order: { number } = {}
		for index, sess in sessions do
			if sess.agent ~= "omp" then
				continue
			end
			local counts: { [string]: number } = {}
			for _, file in sess.session_files do
				local marks = state.omp_session_status[file]
				if type(marks) == "table" then
					for _, mark in OMP_STATES do
						local amount = marks[mark[1]]
						if type(amount) == "number" and amount > 0 then
							counts[mark[1]] = (counts[mark[1]] or 0) + amount
						end
					end
				end
			end
			counts_by_session[index] = counts
			if has_omp_status(counts) then
				table.insert(session_order, index)
			end
		end
		for index in sessions do
			if not has_omp_status(counts_by_session[index]) then
				table.insert(session_order, index)
			end
		end
		local ws_rows: { Node } = {}
		local inactive_rows: { Node } = {}

		for _, ws in workspaces_list do
			if query ~= "" and not string.find(string.lower(ws.name), query, 1, true)
				and not string.find(string.lower(ws.path), query, 1, true) then
				continue
			end
			local has_status = has_omp_status(state.omp_status[ws.path])
			-- Title element: Folder icon + Name
			local icon_span = ui.span("📁 ", "accent")
			local name_span = ui.span(ws.name, "strong")
			local title_node = ui.text({ icon_span, name_span })
			local tp: { [string]: any } = title_node.p or {}
			tp.actions = { click = "open:" .. ws.path }
			tp.role = "workspaces-project-name"
			tp.title = ws.path
			tp.key = "open:" .. ws.path
			tp.wrap = "none"
			title_node.p = tp

			-- Completely dynamic action badges from commands.json configuration
			local row_nodes: { Node } = {}
			for _, act in actions do
				local badge = ui.badge(act.label or act.id, act.tone or "muted")
				local bp: { [string]: any } = badge.p or {}
				bp.actions = { click = "action:" .. act.id .. ":" .. ws.path }
				bp.key = "act:" .. act.id .. ":" .. ws.path
				badge.p = bp
				table.insert(row_nodes, badge)
			end

			-- Keep removal separate from launch actions.
			local del_badge = ui.badge("×", "muted")
			local dp: { [string]: any } = del_badge.p or {}
			dp.actions = { click = "remove:" .. ws.path }
			dp.key = "del:" .. ws.path
			dp.role = "workspaces-remove"
			dp.title = "Remove workspace"
			dp.aria = "Remove workspace"
			del_badge.p = dp

			local title_nodes = { title_node }
			append_omp_status(title_nodes, state.omp_status[ws.path], "omp:" .. ws.path)
			table.insert(title_nodes, del_badge)
			local title_row = ui.node("row", { role = "workspaces-title" }, title_nodes)
			local project_nodes = {
				title_row,
				ui.node("row", { role = "workspaces-actions" }, row_nodes),
			}
			local chat_rows: { Node } = {}

			-- Keep original session indices for resume actions after view-only ordering.
			local count = 0
			for _, sess_idx in session_order do
				local sess = sessions[sess_idx]
				if table.find(sess.workspace_paths, ws.path) == nil then
					continue
				end
				local chat_title = ui.text({ ui.span(sess.title, "default") })
				chat_title.p = chat_title.p or {}
				chat_title.p.role = "workspaces-chat-title"
				local agent_tag = ui.text({ ui.span(sess.agent, "default") })
				agent_tag.p = agent_tag.p or {}
				agent_tag.p.role = "workspaces-agent"
				local indicators: { Node } = {}
				local counts = counts_by_session[sess_idx]
				append_omp_status(indicators, counts, "omp-chat:" .. ws.path .. ":" .. tostring(sess_idx))
				has_status = has_status or has_omp_status(counts)
				table.insert(chat_rows, ui.node("row", {
					key = "chat-row:" .. ws.path .. ":" .. tostring(sess_idx),
					role = "workspaces-chat", align = "start",
					title = sess.agent .. ": " .. sess.title,
					actions = { click = "resume:" .. tostring(sess_idx) .. ":" .. ws.path },
				}, {
					agent_tag, chat_title,
					ui.node("col", { role = "workspaces-chat-status" }, indicators),
				}))
				count += 1
				if count == 2 then
					break
				end
			end
			if #chat_rows > 0 then
				table.insert(project_nodes, ui.node("col", { role = "workspaces-chats" }, chat_rows))
			end
			local project = ui.node("col", { key = "workspace:" .. ws.path, role = "workspaces-project" }, project_nodes)
			table.insert(if has_status then ws_rows else inactive_rows, project)
		end

		local heading = ui.text({ ui.span("Workspaces", "strong") })
		heading.p = heading.p or {}
		heading.p.role = "workspaces-heading"
		local content_nodes: { Node } = {
			heading,
			ui.node("input", {
				key = "filter", role = "workspaces-filter", aria = "Filter by name or path",
				placeholder = "Filter by name or path", text = state.query,
				cursor = utf16_offset(state.query, state.cursor),
				anchor = if state.anchor then utf16_offset(state.query, state.anchor) else nil,
			}),
		}
		append_section(content_nodes, ws_rows, "With Status", "status")
		append_section(content_nodes, inactive_rows, "No Status", "none")
		if #workspaces_list == 0 then
			table.insert(content_nodes, ui.text({ ui.span("No workspaces added yet.", "default") }))
		elseif #ws_rows == 0 and #inactive_rows == 0 then
			table.insert(content_nodes, ui.text({ ui.span("No matching workspaces.", "default") }))
		end

		-- Footer action buttons
		local add_btn = ui.badge("+ Add Current", "default")
		local ap: { [string]: any } = add_btn.p or {}
		ap.actions = { click = "add_current" }
		ap.key = "btn:add_current"
		add_btn.p = ap

		local cfg_btn = ui.badge("⚙ Config Commands", "default")
		local cp2: { [string]: any } = cfg_btn.p or {}
		cp2.actions = { click = "config" }
		cp2.key = "btn:config"
		cfg_btn.p = cp2

		local refresh_btn = ui.badge("⟳ Refresh", "default")
		local sp: { [string]: any } = refresh_btn.p or {}
		sp.actions = { click = "refresh" }
		sp.key = "btn:refresh"
		refresh_btn.p = sp

		local footer = ui.col({ ui.row({ add_btn, refresh_btn }), cfg_btn })
		local fp: { [string]: any } = footer.p or {}
		fp.gap = "sm"
		fp.role = "workspaces-footer"
		footer.p = fp

		table.insert(content_nodes, footer)
		table.insert(content_nodes, ui.text({ ui.span("Drop a folder here to add a workspace.", "default") }))

		return { main = ui.col(content_nodes) }
	end,

	key = function(state: SidebarState, key: Key, cx: BlockCx): boolean
		if state.filter_focused then
			local at = state.cursor
			local from = math.min(state.anchor or at, at)
			local to = math.max(state.anchor or at, at)
			if (key.meta or key.ctrl) and key.name == "a" then
				state.anchor, state.cursor = 1, #state.query + 1
				return true
			elseif key.name == "escape" then
				state.query, state.cursor, state.anchor = "", 1, nil
				return true
			elseif key.name == "left" or key.name == "right" or key.name == "home" or key.name == "end" then
				state.anchor = if key.shift then state.anchor or at else nil
				if key.name == "home" or (key.meta and key.name == "left") then
					state.cursor = 1
				elseif key.name == "end" or (key.meta and key.name == "right") then
					state.cursor = #state.query + 1
				elseif from ~= to and not key.shift then
					state.cursor = if key.name == "left" then from else to
				elseif key.name == "left" then
					state.cursor = utf8.offset(state.query, -1, at) or 1
				else
					state.cursor = utf8.offset(state.query, 2, at) or #state.query + 1
				end
				return true
			end
			local text = ""
			if key.name == "backspace" then
				if from == to then from = utf8.offset(state.query, -1, at) or 1 end
			elseif key.name == "delete" then
				if from == to then to = utf8.offset(state.query, 2, at) or #state.query + 1 end
			elseif key.text and not (key.ctrl or key.meta) then
				text = string.gsub(key.text, "[\r\n]", " ")
			else
				return false
			end
			state.query = string.sub(state.query, 1, from - 1) .. text .. string.sub(state.query, to)
			state.cursor, state.anchor = from + #text, nil
			return true
		end
		if key.name ~= "paste" or type(key.text) ~= "string" then
			return false
		end
		local paths = dropped_paths(key.text)
		if paths == nil then
			cx:toast("error", "Could not add workspace", "Drop a folder from the Files pane.")
			return true
		end
		-- Validate every path before changing the list; never execute dropped text.
		for _, path in paths do
			if string.sub(path, 1, 1) ~= "/" or not pcall(tern.fs.list, path) then
				cx:toast("error", "Could not add workspace", "Only existing, readable folders can be added.")
				return true
			end
		end
		local ok, err = pcall(function()
			for _, path in paths do
				workspace.add_workspace(path)
			end
		end)
		if not ok then
			cx:toast("error", "Could not add workspace", tostring(err))
		end
		return true
	end,

	event = function(state: SidebarState, ev: UiEvent, cx: BlockCx)
		if ev.id == "main.filter" then
			if ev.ev == "focus" then
				state.filter_focused = true
				cx:frame({ { "focus", "main.filter" } })
			elseif ev.ev == "edit" and ev.len == utf16_offset(state.query, #state.query + 1) then
				local from = byte_index(state.query, ev.from)
				local to = byte_index(state.query, ev.to)
				state.query = string.sub(state.query, 1, from - 1) .. string.gsub(ev.text, "[\r\n]", " ") .. string.sub(state.query, to)
				state.cursor, state.anchor = byte_index(state.query, ev.cursor), nil
			end
			return
		end
		if ev.ev == "action" and type(ev.act) == "string" then
			local act = ev.act
			if act == "omp_status" and type(ev.text) == "string" then
				local ok, status = pcall(tern.json.decode, ev.text)
				if ok and type(status) == "table" and type(status.workspaces) == "table" and type(status.sessions) == "table" then
					state.omp_status = status.workspaces
					state.omp_session_status = status.sessions
					if ev.refresh_history == true then
						refresh_sessions(state, cx)
					end
					cx:render()
				end
				return
			end
			if string.sub(act, 1, 7) == "action:" then
				local rest = string.sub(act, 8)
				local act_id, path = string.match(rest, "^([^:]+):(.*)$")
				if act_id and path then
					cx:open("workspaces://action?id=" .. url_encode(act_id) .. "&path=" .. url_encode(path))
				end
			elseif string.sub(act, 1, 5) == "open:" then
				local path = string.sub(act, 6)
				cx:open("workspaces://open?path=" .. url_encode(path))
			elseif string.sub(act, 1, 7) == "resume:" then
				local idx_text, root = string.match(string.sub(act, 8), "^(%d+):(.*)$")
				local idx = tonumber(idx_text)
				if idx and root and state.sessions[idx] then
					local s = state.sessions[idx]
					cx:open("workspaces://resume?root=" .. url_encode(root) .. "&cwd=" .. url_encode(s.cwd) .. "&cmd=" .. url_encode(s.command)
						.. "&files=" .. url_encode(tern.json.encode(tern.json.array(s.session_files))))
				end
			elseif string.sub(act, 1, 7) == "remove:" then
				local path = string.sub(act, 8)
				workspace.remove_workspace(path)
				cx:render()
			elseif act == "add_current" then
				cx:open("workspaces://add_current")
			elseif act == "config" then
				cx:open("workspaces://config")
			elseif act == "refresh" then
				refresh_sessions(state, cx)
				cx:render()
			end
		end
	end,
})
