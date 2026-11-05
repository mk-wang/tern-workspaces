-- Run only in a disposable Tern plugin data directory. The harness calls this
-- function with require("../workspace").
return function(workspace)
	local checked = {}
	for _, action in workspace.default_launch_config().actions do
		if action.id == "codex" or action.id == "claude" then
			local command = workspace.build_tab_command(action, "/project", nil)
			assert(not string.find(command, "--dangerously-", 1, true), "Default agent launch must preserve approval protections")
			checked[action.id] = true
		end
	end
	assert(checked.codex and checked.claude)

	tern.kv.set("workspaces", nil)
	tern.kv.set("favorites", { { name = "Legacy", path = "/legacy" } })
	tern.kv.set("tp_projects", { { name = "Imported", path = "/imported" } })
	tern.kv.set("tp_sessions", { { command = "not a native resume command" } })

	local migrated = workspace.get_workspaces()
	assert(#migrated == 1 and migrated[1].path == "/legacy" and migrated[1].name == "Legacy")
	assert(tern.kv.get("favorites") == nil)
	workspace.save_user_workspaces({ { name = "Custom", path = "/project", icon = "star", folders = { "/project", "/extra" } } })
	local existing = workspace.add_workspace("/project/")
	assert(existing.name == "Custom" and existing.icon == "star" and existing.folders[2] == "/extra")
	local saved = workspace.get_workspaces()
	assert(#saved == 1 and saved[1].name == "Custom" and saved[1].folders[2] == "/extra")
	workspace.add_workspace("/project", "Renamed")
	assert(workspace.get_workspaces()[1].name == "Renamed" and workspace.get_workspaces()[1].folders[2] == "/extra")
	assert(not workspace.remove_workspace("/imported"))
	assert(workspace.remove_workspace("/project"))
	assert(#workspace.get_workspaces() == 0 and tern.kv.get("tp_projects")[1].name == "Imported")
end
