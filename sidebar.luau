--!strict
-- Move one native surface instead of copying it: Tern owns its scroll position.
local sidebar = { kind = tern.plugin.id .. ".sidebar" }

type Geometry = { tab: number, ratio: number, share: number, target: number? }
local pane_id: number? = nil
local rail_ids: { number } = {}
local previous: Geometry? = nil
local migrated = false
local EPSILON = 0.0001

local function preferences(cx: WindowCx): (boolean, number?)
	local enabled = tern.kv.get("sidebar_enabled")
	if not migrated then
		local key = "sidebar_enabled:" .. cx:window_key()
		local legacy = tern.kv.get(key)
		if type(enabled) ~= "boolean" then
			enabled = legacy ~= false
			tern.kv.set("sidebar_enabled", enabled)
		end
		if legacy ~= nil then tern.kv.set(key, nil) end
		migrated = true
	end
	local fraction = tern.kv.get("sidebar_fraction")
	if type(fraction) ~= "number" or fraction < 0.1 or fraction > 0.9 then fraction = nil end
	return enabled ~= false, fraction
end

local function placement(tree: TabTree, pane: number, share: number): (number?, number)
	if tree.pane then return nil, share end
	local left, right = tree[1], tree[2]
	if not left or not right then return nil, share end
	local ratio = tree.ratio or 0.5
	local horizontal = tree.split ~= "down"
	if horizontal and left.pane == pane then return ratio, share end
	local found, outer = placement(left, pane, if horizontal then share * ratio else share)
	if found then return found, outer end
	return placement(right, pane, if horizontal then share * (1 - ratio) else share)
end

local function geometry(cx: WindowCx, pane: number): Geometry?
	local info = cx.session:pane(pane)
	local layout = if info and info.tab then cx.session:layout(info.tab) else nil
	if not layout or layout.zoomed then return nil end
	local ratio, share = placement(layout.root, pane, 1)
	return if ratio then { tab = layout.tab, ratio = ratio, share = share } else nil
end

local function adopt(cx: WindowCx)
	local key = "sidebar_pane:" .. cx:window_key()
	local before = pane_id
	local stored = tern.kv.get(key)
	local saved = pane_id or stored
	local info = if type(saved) == "number" then cx.session:pane(saved) else nil
	pane_id = if info and info.block == sidebar.kind then info.pane else nil
	local focused = cx.session:focused()
	local current = if focused then cx.session:tab_of(focused) else nil
	local found: { number } = {}
	for _, tab in cx.session:tabs() do
		local layout = cx.session:layout(tab.id)
		if not layout then continue end
		local function visit(pane: number)
			local candidate = cx.session:pane(pane)
			if candidate and candidate.block == sidebar.kind then
				table.insert(found, pane)
				if pane_id == nil and tab.id == current then pane_id = pane end
			end
		end
		local function walk(tree: TabTree)
			if tree.pane then visit(tree.pane); return end
			if tree[1] then walk(tree[1]) end
			if tree[2] then walk(tree[2]) end
		end
		walk(layout.root)
		for _, float in layout.floats do visit(float.pane) end
	end
	pane_id = pane_id or found[1]
	-- Retire the old per-tab replicas, never a terminal or agent pane.
	for _, pane in found do
		if pane ~= pane_id then cx.layout:close(pane) end
	end
	if stored ~= pane_id then tern.kv.set(key, pane_id) end
	if pane_id ~= before then previous = nil end
	table.clear(rail_ids)
	if pane_id then table.insert(rail_ids, pane_id) end
end

local function content(tree: TabTree, cx: WindowCx, share: number): (number?, number)
	if tree.pane then
		local info = cx.session:pane(tree.pane)
		return if info and info.block ~= sidebar.kind then tree.pane else nil, share
	end
	local ratio = tree.ratio or 0.5
	local horizontal = tree.split ~= "down"
	if tree[1] then
		local pane, width = content(tree[1], cx, if horizontal then share * ratio else share)
		if pane then return pane, width end
	end
	if tree[2] then return content(tree[2], cx, if horizontal then share * (1 - ratio) else share) end
	return nil, share
end

local function align(cx: WindowCx, pane: number, current: Geometry, fraction: number): Geometry
	local target = math.clamp(fraction / current.share, 0.1, 0.9)
	current.target = target
	if previous and previous.tab == current.tab and previous.ratio == current.ratio
		and previous.share == current.share and previous.target == target then return current end
	if math.abs(current.ratio - target) <= EPSILON then return current end
	-- Native resize takes integer cells. Undo the probe before applying the
	-- correction: a moved pane may still have its source tab's cached columns.
	local step = if target > current.ratio then 1 else -1
	for _ = 1, 2 do
		if cx.layout:resize(pane, "right", step) then
			local after = geometry(cx, pane)
			if after and after.ratio ~= current.ratio then
				local delta = (after.ratio - current.ratio) / step
				cx.layout:resize(pane, "right", -step)
				local restored = geometry(cx, pane) or after
				local cells = math.floor((target - restored.ratio) / delta + 0.5)
				if cells ~= 0 then cx.layout:resize(pane, "right", cells) end
				local result = geometry(cx, pane) or restored
				result.target = target
				return result
			end
		end
		step = -step
	end
	return current
end

local function reconcile(cx: WindowCx): number?
	local enabled, fraction = preferences(cx)
	adopt(cx)
	local current = if pane_id then geometry(cx, pane_id) else nil
	if current and previous and current.tab == previous.tab
		and math.abs(current.share - previous.share) <= EPSILON
		and math.abs(current.ratio - previous.ratio) > EPSILON then
		fraction = math.clamp(current.ratio * current.share, 0.1, 0.9)
		tern.kv.set("sidebar_fraction", fraction)
	elseif not fraction then
		fraction = if current then math.clamp(current.ratio * current.share, 0.1, 0.9) else 0.22
		tern.kv.set("sidebar_fraction", fraction)
	end
	local focused = cx.session:focused()
	local tab = if focused then cx.session:tab_of(focused) else nil
	local layout = if tab then cx.session:layout(tab) else nil
	local target: number? = nil
	local target_share = 1
	if layout then target, target_share = content(layout.root, cx, 1) end
	local info = if pane_id then cx.session:pane(pane_id) else nil
	if not enabled or (layout and not target and info and info.tab == tab) then
		if info and not info.parked then cx.layout:park(info.pane) end
		previous = nil
		return nil
	end
	if not layout or not target or layout.zoomed then return nil end
	if not pane_id then
		local ratio = math.clamp(fraction / target_share, 0.1, 0.9)
		pane_id = cx:new_block(sidebar.kind, nil, "beside", { target = target, dir = "left", ratio = ratio, focus = false })
		if not pane_id then
			cx:toast("error", "Workspaces sidebar unavailable", "Check tern plugin list")
			return nil
		end
		tern.kv.set("sidebar_pane:" .. cx:window_key(), pane_id)
		table.insert(rail_ids, pane_id)
		current = geometry(cx, pane_id)
	elseif info and (info.tab ~= tab or not current) then
		if info.parked then
			local ok, reason = cx.layout:unpark(pane_id, { focus = false })
			if not ok then
				cx:toast("error", "Workspaces sidebar unavailable", reason)
				return nil
			end
		end
		if not cx.layout:move(pane_id, target, "left", { focus = false }) then
			cx:toast("error", "Workspaces sidebar unavailable", "Could not move the sidebar to this tab")
			return nil
		end
		previous = nil
		current = geometry(cx, pane_id)
	end
	if current then previous = align(cx, pane_id, current, fraction) end
	return pane_id
end

function sidebar.sync(cx: WindowCx): number?
	return reconcile(cx)
end

function sidebar.panes(): { number }
	return rail_ids
end

function sidebar.toggle(cx: WindowCx)
	adopt(cx)
	local focused = cx.session:focused()
	local tab = if focused then cx.session:tab_of(focused) else nil
	local info = if pane_id then cx.session:pane(pane_id) else nil
	local present = info ~= nil and info.tab ~= nil and info.tab == tab and not info.parked
	preferences(cx)
	tern.kv.set("sidebar_enabled", not present)
	if not present and not tab then cx.layout:new_tab() end
	reconcile(cx)
end

return sidebar
