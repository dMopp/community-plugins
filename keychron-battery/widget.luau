--!nonstrict
-- Bar widget: mouse glyph + percentage, drawn with the native glyph/text API so
-- it takes the bar's own text and icon colors like the built-in widgets. Only a
-- low battery overrides them. Left-click opens the panel through the manifest
-- action.

local SNAPSHOT_KEY = "keychron_snapshot"

local snapshot = noctalia.state.get(SNAPSHOT_KEY) or {}
local overridden = false

local function levelText(device)
	if type(device.level) == "number" then
		return tostring(device.level) .. "%"
	end
	return "--"
end

local function render()
	local devices = snapshot.devices or {}
	barWidget.setVisible(#devices > 0)
	if #devices == 0 then
		return
	end

	local low = tonumber(noctalia.getConfig("low_threshold")) or 20
	local texts = {}
	local rows = {}
	local isLow = false
	local charging = false
	for _, d in ipairs(devices) do
		table.insert(texts, levelText(d))
		if type(d.level) == "number" and d.level <= low and not d.charging then
			isLow = true
		end
		charging = charging or d.charging
		local value = levelText(d) .. " · " .. noctalia.tr("connection." .. d.connection)
		if d.charging then
			value = value .. " · " .. noctalia.tr("panel.charging")
		end
		table.insert(rows, { key = d.displayName or "", value = value })
	end

	barWidget.setGlyph(charging and "battery-charging" or "mouse")
	barWidget.setText(table.concat(texts, " "))
	if isLow then
		barWidget.setColor("error")
		barWidget.setGlyphColor("error")
		overridden = true
	elseif overridden then
		-- Empty role hands the color back to the bar.
		barWidget.setColor("")
		barWidget.setGlyphColor("")
		overridden = false
	end
	barWidget.setTooltip(rows)
end

noctalia.state.watch(SNAPSHOT_KEY, function(value)
	if type(value) == "table" then
		snapshot = value
		render()
	end
end)

render()
