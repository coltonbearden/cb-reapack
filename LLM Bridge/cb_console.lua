-- @description cb console: LLM narrator and MIDI variation
-- @author Colton Bearden
-- @version 0.1.0
-- @changelog
--   First release: the cb console window with its Narrator and MIDI variation tabs, and the
--   cb_narrator and cb_midi_variation actions that open it on their tab.
-- @provides
--   [windows] .
--   [main windows] narrator.lua > cb_narrator.lua
--   [main windows] midi_variation.lua > cb_midi_variation.lua
--   [windows] lib/*.lua
--   [windows] lib/actions/*.lua
--   [windows] bridge/bridge.ps1
--   [windows] bridge/bridge.config.example.json
--   [windows] bridge/schema/*.json
--   [windows] prompts/*.md
-- @links
--   Repository https://github.com/coltonbearden/cb-reapack
-- @about
--   # cb console
--
--   One ReaImGui window that sends the open project, or the selected MIDI item, to a language
--   model you run yourself and shows the answer. REAPER stays usable while a request runs.
--
--   - **cb_console.lua** opens the window, or closes it when it is open.
--   - **cb_narrator.lua** opens it on the Narrator tab: a short description of the project.
--   - **cb_midi_variation.lua** opens it on the MIDI variation tab: one variation of the
--     selected MIDI item, added to the item as a new take.
--
--   Needs Windows, PowerShell 7 at its default path, ReaImGui 0.10 or newer (ReaTeam
--   Extensions repository) and an OpenAI-compatible chat endpoint such as Ollama.
--
--   Setup: copy `bridge/bridge.config.example.json` to `bridge/bridge.config.json` in the same
--   folder and set `baseUrl` and `model`. ReaPack never updates or removes your copy. Details in
--   the repository's README.

-- Custom: cb console — one ReaImGui window for the LLM bridge actions (docs/llm-bridge.md §8;
-- D-50 to D-56): a tab per action with an instruction box, model and reasoning-effort pickers,
-- Run / Run again / Cancel, the status line, the job folder and the result. REAPER stays usable
-- while a request runs (D-22): one defer loop ticks the state machine (lib/console.lua), then
-- draws (lib/console_ui.lua). Running the action again closes the window; "Custom: cb narrator" and
-- "Custom: cb midi variation" open it on their tab (console.open).
local here = debug.getinfo(1, "S").source:match("^@(.*[\\/])")

if not reaper.APIExists("ImGui_GetBuiltinPath") then
  reaper.ShowMessageBox("cb console needs the ReaImGui extension (reaper_imgui-x64.dll in UserPlugins).", "cb console", 0)
  return
end
package.path = reaper.ImGui_GetBuiltinPath() .. "\\?.lua"
local ImGui = require "imgui" "0.10"

local console = dofile(here .. "lib/console.lua")
local ui = dofile(here .. "lib/console_ui.lua")
local actions = { dofile(here .. "lib/actions/narrator.lua"), dofile(here .. "lib/actions/midi_variation.lua") }

-- 1: a second launch ends this instance instead of asking; 4/8: toolbar toggle state on/off
reaper.set_action_options(1 | 4)
reaper.atexit(function()
  reaper.DeleteExtState(console.SECTION, "alive", false)
  reaper.set_action_options(8)
end)

local c = console.new({ actions = actions, memory = true })
local ctx = ImGui.CreateContext(ui.TITLE)
local state = ui.new_state()

local function loop()
  reaper.SetExtState(console.SECTION, "alive", tostring(reaper.time_precise()), false)
  local wanted = reaper.GetExtState(console.SECTION, "tab")
  if wanted ~= "" then
    reaper.DeleteExtState(console.SECTION, "tab", false)
    if c.tabs[wanted] then state.select = wanted end
  end
  c:tick()
  if ui.frame(ImGui, ctx, c, state) then reaper.defer(loop) end
end
reaper.defer(loop)
