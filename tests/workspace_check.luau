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
	assert(workspace.set_pinned("/project/", true))
	local pinned = workspace.get_workspaces()[1]
	assert(pinned.pinned == true and pinned.name == "Renamed" and pinned.icon == "star" and pinned.folders[2] == "/extra")
	workspace.add_workspace("/project", "Still pinned")
	workspace.add_workspace("/other", "Other")
	assert(workspace.get_workspaces()[1].pinned == true, "Renaming or adding another workspace must preserve pins")
	assert(workspace.set_pinned("/project", true), "Pin must be idempotent")
	assert(not workspace.set_pinned("/missing", true), "Pin must not create a workspace")
	assert(workspace.set_pinned("/project", false))
	local unpinned = workspace.get_workspaces()
	assert(#unpinned == 2 and unpinned[1].pinned == nil and unpinned[1].path == "/project" and unpinned[2].path == "/other")
	assert(unpinned[1].name == "Still pinned" and unpinned[1].icon == "star" and unpinned[1].folders[2] == "/extra")
	assert(workspace.set_pinned("/project", false), "Unpin must be idempotent")
	assert(workspace.remove_workspace("/other"))
	assert(workspace.set_pinned("/project", true))
	assert(not workspace.remove_workspace("/imported"))
	assert(workspace.remove_workspace("/project"))
	assert(#workspace.get_workspaces() == 0 and tern.kv.get("tp_projects")[1].name == "Imported")
end
