--!nonstrict
-- Turns Noctalia's GUI layer (settings.toml in the state dir) into a Nix file.
-- This only ever writes the target file; building or switching is up to the user.

local toml = require("./toml.luau")
local nix = require("./nix.luau")

local M = {}

-- Same lookup as Noctalia's FileUtils::stateDir().
function M.settingsPath()
	for _, var in { "NOCTALIA_STATE_HOME", "XDG_STATE_HOME" } do
		local dir = noctalia.getenv(var)
		if dir and dir ~= "" then
			return dir .. "/noctalia/settings.toml"
		end
	end
	return noctalia.expandPath("~/.local/state/noctalia/settings.toml")
end

function M.targetPath(raw)
	raw = noctalia.string.trim(tostring(raw or ""))
	if raw == "" then
		return nil
	end
	return noctalia.expandPath(raw)
end

-- Exclude patterns are dotted paths; `*` matches exactly one level.
function M.compilePatterns(list)
	local patterns = {}
	for _, p in list or {} do
		local segs = {}
		for seg in string.gmatch(noctalia.string.trim(tostring(p)), "[^%.]+") do
			table.insert(segs, seg)
		end
		if #segs > 0 then
			table.insert(patterns, segs)
		end
	end
	return patterns
end

function M.excluded(patterns, path)
	for _, segs in patterns do
		if #segs == #path then
			local hit = true
			for n, seg in segs do
				if seg ~= "*" and seg ~= path[n] then
					hit = false
					break
				end
			end
			if hit then
				return true
			end
		end
	end
	return false
end

local function countValues(node)
	if node.t ~= "table" then
		return 1
	end
	local n = 0
	for _, k in node.keys do
		n += countValues(node.map[k])
	end
	return n
end

-- Removes excluded paths and values Nix cannot express (inf/nan); prunes tables left empty.
local function filter(node, path, patterns, stats)
	local kept = {}
	for _, k in node.keys do
		local child = node.map[k]
		local childPath = table.clone(path)
		table.insert(childPath, k)
		if M.excluded(patterns, childPath) then
			stats.excluded += countValues(child)
			node.map[k] = nil
		elseif child.special then
			stats.skipped += 1
			node.map[k] = nil
		elseif child.t == "table" then
			local before = #child.keys
			filter(child, childPath, patterns, stats)
			if before > 0 and #child.keys == 0 then
				node.map[k] = nil
			else
				table.insert(kept, k)
			end
		else
			stats.values += 1
			table.insert(kept, k)
		end
	end
	node.keys = kept
end

local function header(source)
	return table.concat({
		"# Noctalia settings changed in the GUI, collected by the dmopp/settings-to-nix plugin",
		"# from " .. source .. ".",
		"# Every export rewrites this file. Values stay in it after they are cleaned up from",
		"# settings.toml. Nothing changes on your system until you rebuild/switch",
		"# (nixos-rebuild switch, home-manager switch, ...).",
		"",
	}, "\n")
end

local function emptyTable()
	return { t = "table", map = {}, keys = {} }
end

-- Parses a TOML file; a missing file is an empty table.
local function readToml(path)
	if not noctalia.fileExists(path) then
		return emptyTable()
	end
	local text, readErr = noctalia.readFile(path)
	if not text then
		return nil, noctalia.tr("errors.read", { path = path, error = tostring(readErr) })
	end
	local parsed, parseErr = toml.parse(text)
	if not parsed then
		return nil, noctalia.tr("errors.parse", { path = path, error = parseErr })
	end
	return parsed
end

-- Merges `from` into `into`; tables merge key by key, anything else is replaced.
local function merge(into, from)
	for _, k in from.keys do
		local a, b = into.map[k], from.map[k]
		if a and a.t == "table" and b.t == "table" then
			merge(a, b)
		else
			if a == nil then
				table.insert(into.keys, k)
			end
			into.map[k] = b
		end
	end
end

-- Everything exported to a target so far, kept in the plugin data dir as TOML. It is
-- what keeps values in the Nix file after the clean-up removed them from settings.toml.
function M.storePath(target)
	local dir = noctalia.pluginDataDir()
	if not dir then
		return nil
	end
	return dir .. "/exported-" .. string.gsub(target, "[^%w%.%-]", "_") .. ".toml"
end

-- Builds the file content: earlier exports plus the current GUI layer, which wins.
-- Returns { content, current, target, store, collected, stats } or nil, err.
function M.plan(cfg)
	local target = M.targetPath(cfg.target)
	if not target then
		return nil, noctalia.tr("errors.no_target")
	end

	local store = M.storePath(target)
	local collected, err = emptyTable(), nil
	if store and not noctalia.fileExists(store) and noctalia.fileExists(target) then
		-- The file holds values this plugin has no record of (record lost, or a file
		-- written by hand): exporting now could drop them. Import or reset first.
		return nil, noctalia.tr("errors.no_record", { path = target })
	end
	if store then
		collected, err = readToml(store)
		if not collected then
			return nil, err
		end
	end
	local source = M.settingsPath()
	local gui
	gui, err = readToml(source)
	if not gui then
		return nil, err
	end
	merge(collected, gui)

	local stats = { values = 0, excluded = 0, skipped = 0 }
	filter(collected, {}, M.compilePatterns(cfg.exclude), stats)

	local current = noctalia.fileExists(target) and noctalia.readFile(target) or nil
	return {
		content = header(source) .. nix.render(collected),
		current = current,
		target = target,
		store = store,
		collected = collected,
		stats = stats,
	}
end

-- Records what was exported, so later exports keep it.
function M.saveStore(plan)
	if plan.store then
		noctalia.writeFile(plan.store, toml.stringify(plan.collected))
	end
end

-- Forgets earlier exports for the configured target; the next export starts from
-- the current settings.toml alone.
function M.resetStore(cfg)
	local target = M.targetPath(cfg.target)
	local store = target and M.storePath(target)
	if store then
		noctalia.writeFile(store, "")
	end
end

-- Adds a whole config (a parsed TOML root, e.g. the config-dir layer) to the record
-- of exported values, below what was exported before. Used once when the Nix file
-- takes over the complete Noctalia config. Returns true or nil, err.
function M.importConfig(cfg, base)
	local target = M.targetPath(cfg.target)
	if not target then
		return nil, noctalia.tr("errors.no_target")
	end
	local store = M.storePath(target)
	if not store then
		return nil, noctalia.tr("errors.write", { path = "plugin data dir", error = "unavailable" })
	end
	local stored, err = readToml(store)
	if not stored then
		return nil, err
	end
	merge(base, stored)
	local ok, writeErr = noctalia.writeFile(store, toml.stringify(base))
	if not ok then
		return nil, noctalia.tr("errors.write", { path = store, error = tostring(writeErr) })
	end
	return true
end

-- Writes plan.content to plan.target via a temp file, checking it with
-- `nix-instantiate --parse` first when cfg.validate is set and the tool exists.
-- Calls done(true) or done(false, err).
function M.write(cfg, plan, done)
	local target = plan.target
	local dir = string.match(target, "^(.*)/[^/]*$")
	if dir and dir ~= "" then
		local ok, err = noctalia.mkdirAll(dir)
		if not ok then
			return done(false, noctalia.tr("errors.write", { path = dir, error = tostring(err) }))
		end
	end
	local tmp = target .. ".tmp"
	local ok, err = noctalia.writeFile(tmp, plan.content)
	if not ok then
		return done(false, noctalia.tr("errors.write", { path = tmp, error = tostring(err) }))
	end

	local function commit()
		local renamed, renameErr = noctalia.renameFile(tmp, target)
		if not renamed then
			noctalia.removeFile(tmp)
			return done(false, noctalia.tr("errors.write", { path = target, error = tostring(renameErr) }))
		end
		M.saveStore(plan)
		done(true)
	end

	if not cfg.validate or not noctalia.commandExists("nix-instantiate") then
		return commit()
	end
	local started = noctalia.runAsync({ "nix-instantiate", "--parse", tmp }, function(result)
		if result.exitCode ~= 0 then
			noctalia.removeFile(tmp)
			return done(false, noctalia.tr("errors.invalid", { error = noctalia.string.trim(result.stderr or "") }))
		end
		commit()
	end)
	if not started then
		commit()
	end
end

return M
