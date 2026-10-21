--!nonstrict
-- Service: exports the GUI layer to the configured Nix file on request (control-center
-- tile, panel, IPC) and, with auto_export, whenever settings.toml changes. After the user
-- confirms a rebuild, it removes the values Nix now provides from settings.toml.
-- Optionally reminds the user to export and to rebuild. Publishes a status snapshot
-- for the tile and panel. It never builds or switches;
-- the only processes it runs are `nix-instantiate --parse` and `noctalia config export`.

local exporter = require("./lib/export.luau")
local cleanup = require("./lib/cleanup.luau")

local STATUS_KEY = "settings_to_nix.status"
local COMMAND_KEY = "settings_to_nix.command"

local lastSignature = nil
local busy = false
local cleaning = false
-- Result of the last cleanup check: number of applied values, or nil when unknown.
local applied = nil
local cleanupError = ""
local pending = false

-- Reminder state, kept across restarts: since when the GUI is ahead of the Nix file,
-- when the last export happened, and whether the reminders already fired.
local REMIND_CHECK_MS = 10 * 60 * 1000
local reminders = { pendingSince = nil, exportedAt = nil, exportReminded = false, rebuildReminded = false }
local lastRebuildCheck = 0

local function remindersPath()
	local dir = noctalia.pluginDataDir()
	return dir and dir .. "/reminders.json"
end

do
	local path = remindersPath()
	local raw = path and noctalia.fileExists(path) and noctalia.readFile(path)
	local saved = raw and noctalia.json.decode(raw)
	if type(saved) == "table" then
		reminders = saved
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
		remindRebuildDays = tonumber(noctalia.getConfig("remind_rebuild_days")) or 0,
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
		applied = applied,
		cleaning = cleaning,
		cleanupError = cleanupError,
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
		exporter.saveStore(plan)
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
		reminders.exportedAt = noctalia.nowMs()
		reminders.rebuildReminded = false
		saveReminders()
		if cfg.notify then
			noctalia.notify(
				noctalia.tr("notify.done_title"),
				noctalia.trp("notify.done_body", plan.stats.values, { path = plan.target })
			)
		end
	end)
end

local function republish()
	publish(exporter.plan(config()))
end

local function runCheck()
	if cleaning then
		return
	end
	cleaning = true
	republish()
	cleanup.check(config(), function(count, err)
		cleaning = false
		applied = count
		cleanupError = err or ""
		republish()
	end)
end

local function runCleanup()
	if cleaning then
		return
	end
	cleaning = true
	republish()
	local cfg = config()
	cleanup.run(cfg, function(count, info)
		cleaning = false
		if count == nil then
			cleanupError = info
			noctalia.notifyError(noctalia.tr("notify.cleanup_failed_title"), info)
		else
			cleanupError = ""
			applied = 0
			if count == 0 then
				noctalia.notify(noctalia.tr("notify.cleanup_none_title"), noctalia.tr("notify.cleanup_none_body"))
			elseif cfg.notify then
				noctalia.notify(
					noctalia.tr("notify.cleanup_done_title"),
					noctalia.trp("notify.cleanup_done_body", count, { backup = info })
				)
			end
		end
		lastSignature = nil
		republish()
	end)
end

-- Takes the current config-dir layer into the Nix file, so the file can replace a
-- hand-written config. Earlier exports and the GUI layer stay on top.
local function runImport()
	if busy then
		return
	end
	busy = true
	cleanup.loadBase(function(base, err)
		busy = false
		local ok = base ~= nil
		if ok then
			ok, err = exporter.importConfig(config(), base)
		end
		if not ok then
			noctalia.notifyError(noctalia.tr("notify.import_failed_title"), err)
			return
		end
		lastSignature = nil
		runExport(true)
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

-- After an export, checks now and then whether the config-dir layer holds the exported
-- values; if it still does not after the configured days, reminds once.
local function checkRebuildReminder(cfg, now)
	if cfg.remindRebuildDays <= 0 or not reminders.exportedAt or reminders.rebuildReminded or cleaning then
		return
	end
	if now - reminders.exportedAt < cfg.remindRebuildDays * 86400000 or now - lastRebuildCheck < REMIND_CHECK_MS then
		return
	end
	lastRebuildCheck = now
	local plan = exporter.plan(cfg)
	if not plan then
		return
	end
	cleanup.loadBase(function(base)
		if not base then
			return
		end
		if cleanup.missing(plan.collected, base) == 0 then
			reminders.exportedAt = nil
		else
			reminders.rebuildReminded = true
			noctalia.notify(noctalia.tr("notify.remind_rebuild_title"), noctalia.tr("notify.remind_rebuild_body"))
		end
		saveReminders()
	end)
end

function update()
	local cfg = config()
	local now = noctalia.nowMs()
	checkExportReminder(cfg, now)
	checkRebuildReminder(cfg, now)
	local signature = fileSignature(exporter.settingsPath())
		.. "|"
		.. fileSignature(exporter.targetPath(cfg.target))
		.. "|"
		.. tostring(cfg.target)
	if signature ~= lastSignature then
		lastSignature = signature
		-- settings.toml or the config may have changed: the cleanup count is stale.
		applied = nil
		cleanupError = ""
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
	elseif event == "import" then
		runImport()
	elseif event == "reset" then
		exporter.resetStore(config())
		runExport(true)
	elseif event == "check" then
		runCheck()
	elseif event == "cleanup" then
		runCleanup()
	end
end

noctalia.state.watch(COMMAND_KEY, function(value)
	if type(value) ~= "table" then
		return
	end
	onIpc(value.action, nil)
end)

update()
