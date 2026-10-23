--!nonstrict
-- Mirrors Noctalia's GUI layer (settings.toml in the state dir) into a Nix file. Every
-- export writes the file anew from settings.toml, so a setting deleted in the GUI also
-- disappears from the file. The file is a small Nix expression that, run by hand, writes
-- the settings back as settings.toml. This only ever writes the target file.

local toml = require("./toml.luau")
local nix = require("./nix.luau")

local M = {}

-- Part of the first line of every file this plugin writes; an existing target without
-- it is not overwritten.
local MARKER = "dmopp/settings-to-nix"

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

local function header(source, name)
	return table.concat({
		"# Noctalia settings, mirrored from the GUI by the " .. MARKER .. " plugin",
		"# (" .. source .. "). Every export overwrites this file.",
		"#",
		"# This file is your backup: keep it somewhere safe, for example in git.",
		"#",
		"# To restore, run this as your user in the directory of this file:",
		"#   $(nix-build --no-out-link ./" .. name .. ")/bin/noctalia-restore-settings",
		"# It replaces settings.toml (the old one is kept as settings.toml.bak-<time>).",
		"# Then restart Noctalia; it installs the plugins listed here again on startup.",
		"",
	}, "\n")
end

-- The restore script around the rendered settings. It writes them back as settings.toml
-- to the state dir Noctalia uses (same lookup as FileUtils::stateDir()).
local function script(settings)
	return table.concat({
		"{ pkgs ? import <nixpkgs> { } }:",
		"let",
		"  settings = " .. settings .. ";",
		'  settingsToml = (pkgs.formats.toml { }).generate "noctalia-settings.toml" settings;',
		"in",
		'pkgs.writeShellScriptBin "noctalia-restore-settings" \'\'',
		"  set -eu",
		"  PATH=${pkgs.coreutils}/bin:$PATH",
		'  if [ -n "\'\'${NOCTALIA_STATE_HOME:-}" ]; then',
		'    dir="$NOCTALIA_STATE_HOME/noctalia"',
		'  elif [ -n "\'\'${XDG_STATE_HOME:-}" ]; then',
		'    dir="$XDG_STATE_HOME/noctalia"',
		"  else",
		'    dir="$HOME/.local/state/noctalia"',
		"  fi",
		'  mkdir -p "$dir"',
		'  if [ -e "$dir/settings.toml" ]; then',
		'    backup="$dir/settings.toml.bak-$(date +%Y%m%d-%H%M%S)"',
		'    cp "$dir/settings.toml" "$backup"',
		'    echo "Previous settings saved to $backup"',
		"  fi",
		'  install -m 644 ${settingsToml} "$dir/settings.toml.tmp"',
		'  mv "$dir/settings.toml.tmp" "$dir/settings.toml"',
		"  # Skip the first-run wizard; it would write its own choices over the restored ones.",
		'  touch "$dir/.setup-complete"',
		'  echo "Noctalia settings restored to $dir/settings.toml."',
		'  echo "Restart Noctalia so it installs the plugins from the restored settings."',
		"\'\'",
		"",
	}, "\n")
end

-- Builds the file content from the current settings.toml.
-- Returns { content, current, target, stats } or nil, err.
function M.plan(cfg)
	local target = M.targetPath(cfg.target)
	if not target then
		return nil, noctalia.tr("errors.no_target")
	end

	local current = noctalia.fileExists(target) and noctalia.readFile(target) or nil
	local firstLine = current and string.match(current, "^[^\n]*") or ""
	if current and current ~= "" and not string.find(firstLine, MARKER, 1, true) then
		return nil, noctalia.tr("errors.foreign", { path = target })
	end

	local source = M.settingsPath()
	local root = { t = "table", map = {}, keys = {} }
	if noctalia.fileExists(source) then
		local text, readErr = noctalia.readFile(source)
		if not text then
			return nil, noctalia.tr("errors.read", { path = source, error = tostring(readErr) })
		end
		local parsed, parseErr = toml.parse(text)
		if not parsed then
			return nil, noctalia.tr("errors.parse", { path = source, error = parseErr })
		end
		root = parsed
	end

	local stats = { values = 0, excluded = 0, skipped = 0 }
	filter(root, {}, M.compilePatterns(cfg.exclude), stats)

	return {
		content = header(source, string.match(target, "[^/]*$")) .. script(nix.render(root, "  ")),
		current = current,
		target = target,
		stats = stats,
	}
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
