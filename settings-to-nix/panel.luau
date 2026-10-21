--!nonstrict
-- Panel: the three steps export -> rebuild (done by the user) -> clean up settings.toml.
-- Clean-up needs two clicks: the first states that the rebuild happened, the second confirms.

local STATUS_KEY = "settings_to_nix.status"
local COMMAND_KEY = "settings_to_nix.command"

local status = noctalia.state.get(STATUS_KEY) or {}
local armed = false

local function send(action)
	noctalia.state.set(COMMAND_KEY, { action = action, nonce = tostring(noctalia.nowMs()) })
end

local function text(value, props)
	props = props or {}
	props.text = value
	props.fontSize = props.fontSize or 12
	props.color = props.color or "on_surface_variant"
	return ui.label(props)
end

local function step(title, children)
	local body = { text(title, { fontSize = 13, fontWeight = "bold", color = "on_surface" }) }
	for _, child in children do
		table.insert(body, child)
	end
	return ui.column({ gap = 6 }, body)
end

local function exportStep()
	local lines = {}
	if status.error and status.error ~= "" then
		table.insert(lines, text(status.error, { color = "error" }))
	else
		local key = status.pending and "panel.export_pending" or "panel.export_current"
		table.insert(lines, text(noctalia.trp(key, status.values or 0)))
		table.insert(lines, text(status.target or "", { maxLines = 2 }))
	end
	table.insert(lines, ui.row({ gap = 8 }, {
		ui.button({
			text = noctalia.tr("panel.export_button"),
			glyph = "file-export",
			variant = status.pending and "primary" or "default",
			flexGrow = 1,
			onClick = "onExportClicked",
		}),
		ui.button({
			text = noctalia.tr("panel.import_button"),
			glyph = "file-import",
			variant = "ghost",
			tooltip = noctalia.tr("panel.import_tooltip"),
			onClick = "onImportClicked",
		}),
	}))
	return step(noctalia.tr("panel.export_title"), lines)
end

local function cleanupStep()
	local lines = { text(noctalia.tr("panel.cleanup_intro")) }
	local applied = status.applied
	local canClean = false
	if status.cleaning then
		table.insert(lines, text(noctalia.tr("panel.cleanup_checking")))
	elseif status.cleanupError and status.cleanupError ~= "" then
		table.insert(lines, text(status.cleanupError, { color = "error" }))
	elseif applied == 0 then
		table.insert(lines, text(noctalia.tr("panel.cleanup_none")))
	elseif type(applied) == "number" then
		canClean = true
		table.insert(lines, text(noctalia.trp("panel.cleanup_ready", applied), { color = "on_surface" }))
	end

	local label = armed and noctalia.trp("panel.cleanup_confirm", applied or 0) or noctalia.tr("panel.cleanup_button")
	table.insert(lines, ui.row({ gap = 8 }, {
		ui.button({
			text = label,
			glyph = "trash",
			variant = armed and "destructive" or "default",
			enabled = canClean,
			onClick = "onCleanupClicked",
		}),
		ui.button({ glyph = "refresh", variant = "ghost", tooltip = noctalia.tr("panel.recheck"), onClick = "onCheckClicked" }),
	}))
	return step(noctalia.tr("panel.cleanup_title"), lines)
end

local function render()
	panel.render(ui.column({ flexGrow = 1, gap = 16 }, {
		ui.row({ align = "center", gap = 8 }, {
			ui.glyph({ name = "snowflake", size = 18, color = "primary" }),
			ui.label({ text = noctalia.tr("panel.title"), fontSize = 16, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
			ui.button({ glyph = "settings", variant = "ghost", onClick = "onSettingsClicked" }),
			ui.button({ glyph = "close", variant = "ghost", onClick = "onCloseClicked" }),
		}),
		exportStep(),
		ui.separator({}),
		step(noctalia.tr("panel.rebuild_title"), { text(noctalia.tr("panel.rebuild_body")) }),
		ui.separator({}),
		cleanupStep(),
	}))
end

noctalia.state.watch(STATUS_KEY, function(value)
	if type(value) ~= "table" then
		return
	end
	status = value
	if status.applied == nil and not status.cleaning and (status.cleanupError or "") == "" then
		send("check")
	end
	if type(status.applied) ~= "number" or status.applied == 0 then
		armed = false
	end
	render()
end)

function onOpen(_context)
	armed = false
	send("check")
	render()
end

function onExportClicked()
	send("export")
end

function onImportClicked()
	send("import")
end

function onCheckClicked()
	armed = false
	send("check")
end

function onCleanupClicked()
	if not armed then
		armed = true
		render()
		return
	end
	armed = false
	send("cleanup")
end

function onSettingsClicked()
	noctalia.openSettings()
end

function onCloseClicked()
	panel.close()
end

render()
