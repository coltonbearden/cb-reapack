-- @noindex

-- Custom: cb midi variation — opens the bridge console ("Custom: cb console", scripts/cb_console.lua)
-- on its MIDI variation tab with the instruction box focused (D-50); Run there adds one variation of
-- the selected MIDI item as a new take (docs/llm-bridge.md §7, §8). The action itself is
-- lib/actions/midi_variation.lua (D-51).
local here = debug.getinfo(1, "S").source:match("^@(.*[\\/])")
local console = dofile(here .. "lib/console.lua")

local ok, err = console.open("midi_variation")
if not ok then reaper.ShowMessageBox(err, "cb midi variation", 0) end
