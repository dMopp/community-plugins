--!nonstrict
-- Service: mirrors the GUI layer into the configured Nix file on request (control-center
-- tile, panel, IPC) and, with auto_export, whenever settings.toml changes. Optionally
-- reminds the user to export. Publishes a status snapshot for the tile and panel.
-- The only process it runs is `nix-instantiate --parse` on the file it is about to write.

local exporter = require("./lib/export.luau")

local STATUS_KEY = "settings_to_nix.status"
local COMMAND_KEY = "settings_to_nix.command"

local lastSignature = nil
local busy = false
local pending = false

-- Reminder state, kept across restarts: since when the GUI is ahead of the Nix file and
-- whether the reminder already fired.
local reminders = { pendingSince = nil, exportReminded = false }

local function remindersPath()
	local dir = noctalia.pluginDataDir()
	return dir and dir .. "/reminders.json"
end

do
	local path = remindersPath()
	local raw = path and noctalia.fileExists(path) and noctalia.readFile(path)
	local saved = raw and noctalia.json.decode(raw)
	if type(saved) == "table" then
		reminders.pendingSince = saved.pendingSince
		reminders.exportReminded = saved.exportReminded == true
	end
end

local function saveReminders()
	local path = remindersPath()
	if path then
		noctalia.writeFile(path, noctalia.json.encode(reminders))
	end
end

noctalia.setUpdateInterval(2000)

local function config()
	return {
		target = noctalia.getConfig("target_path"),
		exclude = noctalia.getConfig("exclude") or {},
		validate = noctalia.getConfig("validate") ~= false,
		autoExport = noctalia.getConfig("auto_export") == true,
		notify = noctalia.getConfig("notify") ~= false,
		remindExportHours = tonumber(noctalia.getConfig("remind_export_hours")) or 0,
	}
end

local function fileSignature(path)
	local info = path and noctalia.fileInfo(path)
	if not info then
		return "-"
	end
	return `{info.mtime}:{info.size}`
end

local function publish(plan, err)
	pending = plan ~= nil and plan.content ~= plan.current
	noctalia.state.set(STATUS_KEY, {
		pending = pending,
		target = plan and plan.target or "",
		values = plan and plan.stats.values or 0,
		error = err or "",
	})
end

local runExport

local function refresh()
	local cfg = config()
	local plan, err = exporter.plan(cfg)
	publish(plan, err)
	if plan and cfg.autoExport and plan.content ~= plan.current then
		runExport(false)
	end
end

function runExport(manual)
	if busy then
		return
	end
	local cfg = config()
	local plan, err = exporter.plan(cfg)
	if not plan then
		publish(nil, err)
		noctalia.notifyError(noctalia.tr("notify.failed_title"), err)
		return
	end
	if plan.content == plan.current then
		publish(plan)
		if manual and cfg.notify then
			noctalia.notify(noctalia.tr("notify.unchanged_title"), noctalia.tr("notify.unchanged_body", { path = plan.target }))
		end
		return
	end

	busy = true
	exporter.write(cfg, plan, function(ok, writeErr)
		busy = false
		lastSignature = nil
		if not ok then
			publish(nil, writeErr)
			noctalia.notifyError(noctalia.tr("notify.failed_title"), writeErr)
			return
		end
		plan.current = plan.content
		publish(plan)
		if manual and cfg.notify then
			noctalia.notify(
				noctalia.tr("notify.done_title"),
				noctalia.trp("notify.done_body", plan.stats.values, { path = plan.target })
			)
		end
	end)
end

local function checkExportReminder(cfg, now)
	if not pending then
		if reminders.pendingSince then
			reminders.pendingSince = nil
			reminders.exportReminded = false
			saveReminders()
		end
		return
	end
	if not reminders.pendingSince then
		reminders.pendingSince = now
		saveReminders()
	end
	if cfg.autoExport or cfg.remindExportHours <= 0 or reminders.exportReminded then
		return
	end
	if now - reminders.pendingSince >= cfg.remindExportHours * 3600000 then
		reminders.exportReminded = true
		saveReminders()
		noctalia.notify(noctalia.tr("notify.remind_export_title"), noctalia.tr("notify.remind_export_body"))
	end
end

function update()
	local cfg = config()
	checkExportReminder(cfg, noctalia.nowMs())
	local signature = fileSignature(exporter.settingsPath())
		.. "|"
		.. fileSignature(exporter.targetPath(cfg.target))
		.. "|"
		.. tostring(cfg.target)
	if signature ~= lastSignature then
		lastSignature = signature
		refresh()
	end
end

function onConfigChanged()
	lastSignature = nil
	update()
end

function onIpc(event, _payload)
	if event == "export" then
		runExport(true)
	end
end

noctalia.state.watch(COMMAND_KEY, function(value)
	if type(value) == "table" then
		onIpc(value.action, nil)
	end
end)

update()
