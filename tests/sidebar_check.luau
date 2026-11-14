-- Run in a disposable Tern plugin data directory with require("../sidebar").
return function(sidebar)
	local focused = 2
	local panes = {
		[1] = { pane = 1, tab = 1, block = "terminal" },
		[2] = { pane = 2, tab = 2, block = "terminal" },
		[3] = { pane = 3, tab = 1, block = sidebar.kind, parked = false },
	}
	local layouts = {
		[1] = { tab = 1, root = { split = "right", ratio = 0.22, { pane = 3 }, { pane = 1 } }, floats = {} },
		[2] = { tab = 2, root = { pane = 2 }, floats = {} },
	}
	local cx = {
		session = {
			focused = function() return focused end,
			pane = function(_, id) return panes[id] end,
			tab_of = function(_, id) return panes[id].tab end,
			tabs = function() return { { id = 1 }, { id = 2 } } end,
			layout = function(_, id) return layouts[id] end,
		},
		layout = {
			park = function(_, id)
				local pane = panes[id]
				layouts[pane.tab].root = { pane = pane.tab }
				if focused == id then focused = pane.tab end
				pane.tab, pane.parked = nil, true
				return true
			end,
			unpark = function(_, id)
				panes[id].tab, panes[id].parked = panes[focused].tab, false
				return true
			end,
			move = function(_, id, target)
				local pane = panes[id]
				if pane.tab then layouts[pane.tab].root = { pane = pane.tab } end
				pane.tab = panes[target].tab
				layouts[pane.tab].root = { split = "right", ratio = 0.22, { pane = id }, { pane = target } }
				return true
			end,
		},
		window_key = function() return "sidebar-check" end,
		new_block = function() error("Do not replace the shared sidebar") end,
	}
	tern.kv.set("sidebar_enabled", true)
	tern.kv.set("sidebar_fraction", 0.22)
	tern.kv.set("sidebar_pane:sidebar-check", 3)

	-- Tab 2 is focused before the sidebar has moved out of tab 1.
	sidebar.toggle(cx)
	assert(tern.kv.get("sidebar_enabled") == false and panes[3].parked, "Toggle must hide globally, not restore a missing per-tab pane")
	focused = 1
	assert(sidebar.sync(cx) == nil and panes[3].parked, "Switching tabs must not reopen a hidden sidebar")
	sidebar.toggle(cx)
	assert(panes[3].tab == 1 and not panes[3].parked and focused == 1)
	focused = 2
	assert(sidebar.sync(cx) == 3 and panes[3].tab == 2 and focused == 2, "An existing tab must reuse the same sidebar without stealing focus")
	assert(not sidebar.close(cx), "Ordinary terminal close must use Tern's normal handler")
	assert(tern.kv.get("sidebar_enabled") == true)
	focused = 3
	assert(sidebar.close(cx) and panes[3].parked, "Closing the sidebar must park its native surface")
	assert(tern.kv.get("sidebar_enabled") == false and focused == 2)
	focused = 1
	assert(sidebar.sync(cx) == nil, "Native close must stay closed in other tabs")
	sidebar.toggle(cx)
	assert(panes[3].tab == 1 and not panes[3].parked, "Reopening must reuse the parked surface")

	-- Native header closes bypass the keyboard override and destroy the pane.
	panes[3] = nil
	layouts[1].root = { pane = 1 }
	assert(sidebar.sync(cx) == nil and tern.kv.get("sidebar_enabled") == false, "A destroyed sidebar must close globally, not recreate itself")
end