-- @noindex

-- The MIDI variation action (D-51): one variation of the selected MIDI item through the LLM bridge
-- (docs/llm-bridge.md §7; D-26, D-27, D-31, D-32), added to the same item as a new, active take in
-- its own undo point; the existing takes are never changed. Used by scripts/midi_variation.lua,
-- scripts/lib/console.lua and tests/cases/midi_variation.lua.
local here = debug.getinfo(1, "S").source:match("^@(.*[\\/])")      -- <scripts>/lib/actions/
local root = here:match("^(.*[\\/])lib[\\/]actions[\\/]$")           -- <scripts>/
local bridge = dofile(root .. "lib/bridge.lua")
local midi = dofile(root .. "lib/midi_take.lua")

local M = { name = "midi_variation", title = "cb midi variation", label = "MIDI variation" }

-- opts: { extra? }. Reads the selected item now, so the run keeps the item it was started on.
-- Returns a run ({ spec, item, context }), or nil and a message for the user.
function M.build_request(opts)
  opts = opts or {}
  if reaper.CountSelectedMediaItems(0) ~= 1 then return nil, "Select one MIDI item." end
  local item = reaper.GetSelectedMediaItem(0, 0)
  local context, err = midi.read(item)
  if not context then return nil, "Cannot vary this item: " .. err .. "." end
  if #context.notes == 0 then return nil, "The item has no notes to vary." end
  local prompt, perr = bridge.read_prompt(M.name)
  if not prompt then return nil, perr end
  return { item = item, context = context,
    spec = { action = M.name, prompt = prompt, extra = (opts.extra or ""):sub(1, 500), context = context } }
end

-- Adds the result as a new take in one undo point (D-27). The undo block and the refresh hold are
-- closed even when writing the take raises (docs/reference/prior-art.md, Reaper-MCP).
-- Returns { name, take, stats }, or nil and a message.
function M.apply(run, result)
  local item = run.item
  if not reaper.ValidatePtr2(0, item, "MediaItem*") then return nil, "the item was deleted while waiting; nothing was added." end
  local name = "cb variation " .. reaper.CountTakes(item)
  reaper.PreventUIRefresh(1)
  reaper.Undo_BeginBlock2(0)
  local ok, take, stats = pcall(midi.add_take, item, result.notes, name, run.context.length_qn, run.context.channel)
  reaper.Undo_EndBlock2(0, M.title .. ": " .. name, -1)
  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  if not ok then return nil, "writing the take failed: " .. tostring(take) end
  if not take then return nil, stats end
  return { name = name, take = take, stats = stats }
end

-- What was added, what was fixed in the answer, and the model's own summary.
function M.describe(run, result, applied)
  local s = applied.stats
  local lines = { string.format('Added take "%s" with %d notes (the original has %d).', applied.name, s.kept, #run.context.notes) }
  if s.shortened + s.dropped + s.trimmed > 0 then
    lines[#lines + 1] = string.format("Fixed in the answer: %d notes shortened at the item end, %d dropped past it, %d cut where the same pitch overlapped.",
      s.shortened, s.dropped, s.trimmed)
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = result.summary
  return lines
end

return M
