-- Bar [[widget]] entry:
-- Left Click: opens the panel,
-- Right Click: picks a color directly
-- and copies the hex to clipboard (no panel).

local glyph = noctalia.getConfig("glyph")
local tr_color_picker = noctalia.tr("color_picker");

local function render()
  barWidget.setGlyph(glyph)
  barWidget.setTooltip(tr_color_picker)
end

function onClick()
  noctalia.togglePanel("ylxc/color-tools:panel")
end

function onRightClick()
  noctalia.runAsync("noctalia msg plugin ylxc/color-tools:service all pick", function(result)
    if result.exitCode ~= 0 then
      noctalia.notifyError(tr_color_picker, noctalia.tr("could_not_parse"))
    end
  end)
end

render()
