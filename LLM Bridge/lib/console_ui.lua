-- @noindex

-- The bridge console's window (D-50, D-52): draws the state of scripts/lib/console.lua with
-- ReaImGui and turns button presses into console:start / console:cancel. It never polls; the
-- caller runs console:tick() before each frame. Shim style (`ImGui.X(ctx, ...)`, typed by
-- docs/reference/luals/imgui_defs.lua); End, EndTabBar, EndTabItem, EndCombo and EndChild are called
-- only after their Begin returned true.
local here = debug.getinfo(1, "S").source:match("^@(.*[\\/])")   -- <scripts>/lib/
local console = dofile(here .. "console.lua")

local M = {}

M.TITLE = "cb console"
local ERROR_RGBA = 0xFF7070FF

-- Per-window UI state: `select` names a tab to bring to the front (the request is kept until that
-- tab is drawn, which then focuses its instruction box); `error` is the last error the window
-- body raised.
function M.new_state() return { select = nil, focus = nil, error = nil } end

-- A combo over `list`; the config's default is marked so a remembered pick is not mistaken for
-- it. Returns the value picked this frame, or nil.
local function picker(ImGui, ctx, label, current, list, default)
  local function shown(v) return v == default and (v .. " (default)") or v end
  local picked
  if ImGui.BeginCombo(ctx, label, shown(current or "")) then
    for _, v in ipairs(list) do
      if ImGui.Selectable(ctx, shown(v), v == current) then picked = v end
    end
    ImGui.EndCombo(ctx)
  end
  return picked
end

local function draw_tab(ImGui, ctx, c, tab, state)
  local running = tab.state == "running"
  ImGui.Text(ctx, "Instruction (optional)")
  if state.focus == tab.name then
    ImGui.SetKeyboardFocusHere(ctx)
    state.focus = nil
  end
  local changed, text = ImGui.InputTextMultiline(ctx, "##extra", tab.extra, -1, ImGui.GetTextLineHeight(ctx) * 5)
  if changed then c:set(tab.name, "extra", text) end
  local too_long = #tab.extra > console.MAX_EXTRA
  local count = string.format("%d/%d characters", #tab.extra, console.MAX_EXTRA)
  if too_long then ImGui.TextColored(ctx, ERROR_RGBA, count) else ImGui.TextDisabled(ctx, count) end

  ImGui.SetNextItemWidth(ctx, 220)
  local model = picker(ImGui, ctx, "Model", tab.model, tab.models, tab.default_model)
  if model then c:set(tab.name, "model", model) end
  ImGui.SameLine(ctx)
  ImGui.SetNextItemWidth(ctx, 150)
  local effort = picker(ImGui, ctx, "Reasoning effort", tab.effort, console.EFFORTS, tab.default_effort)
  if effort then c:set(tab.name, "effort", effort) end

  ImGui.BeginDisabled(ctx, running or too_long)
  if ImGui.Button(ctx, tab.state == "idle" and "Run" or "Run again") then c:start(tab.name) end
  ImGui.EndDisabled(ctx)
  ImGui.SameLine(ctx)
  ImGui.BeginDisabled(ctx, not running)
  if ImGui.Button(ctx, "Cancel") then c:cancel(tab.name) end
  ImGui.EndDisabled(ctx)

  ImGui.Separator(ctx)
  local status = tab.status ~= "" and tab.status or "Ready."
  if tab.state == "error" or tab.state == "timeout" then
    ImGui.PushTextWrapPos(ctx, 0)
    ImGui.TextColored(ctx, ERROR_RGBA, status)
    ImGui.PopTextWrapPos(ctx)
  else
    ImGui.TextWrapped(ctx, status)
  end
  if tab.job then
    for _, line in ipairs(tab.log) do ImGui.TextDisabled(ctx, line) end
    ImGui.SetNextItemWidth(ctx, -1)
    ImGui.InputText(ctx, "##jobdir", tab.job.dir, ImGui.InputTextFlags_ReadOnly)
  end
  ImGui.Separator(ctx)
  if ImGui.BeginChild(ctx, "##result", 0, 0, ImGui.ChildFlags_Borders) then
    ImGui.TextWrapped(ctx, table.concat(tab.result, "\n"))
    ImGui.EndChild(ctx)
  end
end

local function draw_body(ImGui, ctx, c, state)
  if state.error then ImGui.TextColored(ctx, ERROR_RGBA, "window error: " .. state.error) end
  if ImGui.BeginTabBar(ctx, "##actions") then
    for _, name in ipairs(c.order) do
      local tab = c.tabs[name]
      local flags = state.select == name and ImGui.TabItemFlags_SetSelected or ImGui.TabItemFlags_None
      if ImGui.BeginTabItem(ctx, tab.label .. "###" .. name, nil, flags) then
        if state.select == name then state.select, state.focus = nil, name end
        draw_tab(ImGui, ctx, c, tab, state)
        ImGui.EndTabItem(ctx)
      end
    end
    ImGui.EndTabBar(ctx)
  end
end

-- One frame. Returns false once the user has closed the window.
function M.frame(ImGui, ctx, c, state)
  ImGui.SetNextWindowSize(ctx, 560, 520, ImGui.Cond_FirstUseEver)
  local visible, open = ImGui.Begin(ctx, M.TITLE, true)
  if visible then
    -- End is reached even when the body raises (docs/reference/prior-art.md, ReaSpeech); the error
    -- is shown at the top of the window from the next frame on.
    local ok, err = pcall(draw_body, ImGui, ctx, c, state)
    if not ok then state.error = tostring(err) end
    ImGui.End(ctx)
  end
  return open
end

return M
