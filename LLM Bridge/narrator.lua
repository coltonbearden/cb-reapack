-- @noindex

-- Custom: cb narrator — opens the bridge console ("Custom: cb console", scripts/cb_console.lua) on
-- its Narrator tab with the instruction box focused (D-50); Run there describes the open project
-- through the LLM bridge (docs/llm-bridge.md §6, §8). The action itself is lib/actions/narrator.lua
-- (D-51).
local here = debug.getinfo(1, "S").source:match("^@(.*[\\/])")
local console = dofile(here .. "lib/console.lua")

local ok, err = console.open("narrator")
if not ok then reaper.ShowMessageBox(err, "cb narrator", 0) end
