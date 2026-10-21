--!nonstrict
-- Cleans up settings.toml after the user has rebuilt with the exported Nix file: a GUI
-- value is removed only when the config-dir layer (what Nix manages) now holds the
-- same value, so nothing is lost when the rebuild has not happened yet. Excluded
-- paths and config_version are never touched. Noctalia reloads settings.toml on change.

local toml = require("./toml.luau")
local exporter = require("./export.luau")

local M = {}

local function isNumber(node)
	return (node.t == "int" or node.t == "float") and not node.special
end

local function equal(a, b)
	if isNumber(a) and isNumber(b) then
		local x, y = tonumber(a.v), tonumber(b.v)
		return x ~= nil and y ~= nil and math.abs(x - y) <= 1e-9 * math.max(1, math.abs(x))
	end
	if a.t ~= b.t then
		return false
	end
	if a.t == "table" then
		if #a.keys ~= #b.keys then
			return false
		end
		for _, k in a.keys do
			if b.map[k] == nil or not equal(a.map[k], b.map[k]) then
				return false
			end
		end
		return true
	elseif a.t == "array" then
		if #a.items ~= #b.items then
			return false
		end
		for n, item in a.items do
			if not equal(item, b.items[n]) then
				return false
			end
		end
		return true
	elseif a.special or b.special then
		return a.special == b.special
	end
	return a.v == b.v
end

-- Removes every value of `node` that `base` holds identically; returns the count removed.
local function prune(node, base, path, patterns)
	local removed = 0
	local kept = {}
	for _, k in node.keys do
		local child = node.map[k]
		local other = base and base.t == "table" and base.map[k] or nil
		local childPath = table.clone(path)
		table.insert(childPath, k)
		local protected = (#childPath == 1 and k == "config_version") or exporter.excluded(patterns, childPath)
		if protected or other == nil then
			table.insert(kept, k)
		elseif child.t == "table" and other.t == "table" then
			local before = #child.keys
			removed += prune(child, other, childPath, patterns)
			if before > 0 and #child.keys == 0 then
				node.map[k] = nil
			else
				table.insert(kept, k)
			end
		elseif equal(child, other) then
			removed += 1
			node.map[k] = nil
		else
			table.insert(kept, k)
		end
	end
	node.keys = kept
	return removed
end

-- Counts the values of `node` (the exported settings) that `base` does not hold with
-- the same value, i.e. what a rebuild has not applied yet.
function M.missing(node, base)
	local n = 0
	for _, k in node.keys do
		local child = node.map[k]
		local other = base and base.t == "table" and base.map[k] or nil
		if child.t == "table" and other and other.t == "table" then
			n += M.missing(child, other)
		elseif other == nil or not equal(child, other) then
			n += 1
		end
	end
	return n
end

-- Reads the config-dir layer by running `noctalia config export merged` against an
-- empty state dir, so Noctalia itself merges *.toml and [include]s.
function M.loadBase(done)
	if not noctalia.commandExists("noctalia") then
		return done(nil, noctalia.tr("errors.no_cli"))
	end
	local dataDir, dirErr = noctalia.pluginDataDir()
	if not dataDir then
		return done(nil, tostring(dirErr))
	end
	local emptyState = dataDir .. "/empty-state"
	noctalia.mkdirAll(emptyState)
	local started = noctalia.runAsync(
		{ "env", "NOCTALIA_STATE_HOME=" .. emptyState, "noctalia", "config", "export", "merged" },
		function(result)
			if result.exitCode ~= 0 or result.stdoutTruncated then
				return done(nil, noctalia.tr("errors.base", { error = noctalia.string.trim(result.stderr or "") }))
			end
			local base, err = toml.parse(result.stdout or "")
			if not base then
				return done(nil, noctalia.tr("errors.base", { error = err }))
			end
			done(base)
		end
	)
	if not started then
		done(nil, noctalia.tr("errors.base", { error = "could not start noctalia" }))
	end
end

-- Reads and prunes the current settings.toml against `base`.
local function compute(base, patterns)
	local source = exporter.settingsPath()
	if not noctalia.fileExists(source) then
		return { source = source, removed = 0 }
	end
	local text, readErr = noctalia.readFile(source)
	if not text then
		return nil, noctalia.tr("errors.read", { path = source, error = tostring(readErr) })
	end
	local root, parseErr = toml.parse(text)
	if not root then
		return nil, noctalia.tr("errors.parse", { path = source, error = parseErr })
	end
	local removed = prune(root, base, {}, patterns)
	return { source = source, text = text, root = root, removed = removed }
end

-- Counts how many GUI values are already applied. Calls done(count) or done(nil, err).
function M.check(cfg, done)
	M.loadBase(function(base, err)
		if not base then
			return done(nil, err)
		end
		local result, computeErr = compute(base, exporter.compilePatterns(cfg.exclude))
		if not result then
			return done(nil, computeErr)
		end
		done(result.removed)
	end)
end

-- Removes the applied values from settings.toml, keeping a backup of the previous file
-- in the plugin data dir. Calls done(count, backupPath) or done(nil, err).
function M.run(cfg, done)
	M.loadBase(function(base, err)
		if not base then
			return done(nil, err)
		end
		-- Re-read settings.toml only now, so GUI changes made meanwhile are kept.
		local result, computeErr = compute(base, exporter.compilePatterns(cfg.exclude))
		if not result then
			return done(nil, computeErr)
		end
		if result.removed == 0 then
			return done(0)
		end

		local backup = noctalia.pluginDataDir() .. "/settings.toml.bak"
		local ok, writeErr = noctalia.writeFile(backup, result.text)
		if not ok then
			return done(nil, noctalia.tr("errors.write", { path = backup, error = tostring(writeErr) }))
		end
		local tmp = string.gsub(result.source, "[^/]*$", ".settings-to-nix.tmp")
		ok, writeErr = noctalia.writeFile(tmp, toml.stringify(result.root))
		if ok then
			ok, writeErr = noctalia.renameFile(tmp, result.source)
		end
		if not ok then
			noctalia.removeFile(tmp)
			return done(nil, noctalia.tr("errors.write", { path = result.source, error = tostring(writeErr) }))
		end
		done(result.removed, backup)
	end)
end

return M
