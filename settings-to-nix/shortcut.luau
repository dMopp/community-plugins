--!nonstrict
-- Control-center tile: click opens the panel, right-click exports the GUI settings to
-- the Nix file directly. The tile is highlighted while the file is behind the GUI.

local STATUS_KEY = "settings_to_nix.status"
local COMMAND_KEY = "settings_to_nix.command"

local status = noctalia.state.get(STATUS_KEY) or {}

local function render()
	shortcut.setIcon("snowflake")
	if status.error and status.error ~= "" then
		shortcut.setLabel(noctalia.tr("shortcut.error"))
	elseif status.pending then
		shortcut.setLabel(noctalia.tr("shortcut.pending"))
	else
		shortcut.setLabel(noctalia.tr("shortcut.label"))
	end
	shortcut.setActive(status.pending == true)
end

noctalia.state.watch(STATUS_KEY, function(value)
	if type(value) == "table" then
		status = value
		render()
	end
end)

function onClick()
	noctalia.togglePanel("dmopp/settings-to-nix:panel")
end

function onRightClick()
	noctalia.state.set(COMMAND_KEY, { action = "export", nonce = tostring(noctalia.nowMs()) })
end

render()
