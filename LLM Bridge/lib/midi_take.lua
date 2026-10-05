-- @noindex

-- MIDI take <-> bridge notes for the MIDI variation action (D-26, D-27, D-31, D-32). A note is
-- { pitch, start, length, velocity }: start and length in quarter notes from the item start, pitch
-- and velocity as MIDI integers. read() describes an item's active take for the model; add_take()
-- writes notes into a new take on the same item and never touches the existing takes.
local M = {}

M.MAX_NOTES = 64   -- larger takes are refused: 64 notes took 23-25 s at reasoning effort low (D-31)

local here = debug.getinfo(1, "S").source:match("^@(.*[\\/])")
local summary = dofile(here .. "project_summary.lua")

local function round(x, places)
  local m = 10 ^ (places or 4)
  return math.floor(x * m + 0.5) / m
end

-- The item's start in project quarter notes and its length in quarter notes.
local function item_span(item)
  local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  local q0 = reaper.TimeMap2_timeToQN(0, pos)
  return q0, reaper.TimeMap2_timeToQN(0, pos + len) - q0
end

-- Context for the model from item's active take: the notes that sound inside the item (muted
-- notes and anything outside the item are left out), plus what the prompt explains.
-- Returns nil and a message when the active take is not MIDI or has more than MAX_NOTES notes.
function M.read(item)
  local take = reaper.GetActiveTake(item)
  if not take or not reaper.TakeIsMIDI(take) then return nil, "the item's active take is not MIDI" end
  local _, count = reaper.MIDI_CountEvts(take)
  if count > M.MAX_NOTES then return nil, string.format("the take has %d notes; the limit is %d", count, M.MAX_NOTES) end

  local q0, len = item_span(item)
  local grid, swing = reaper.MIDI_GetGrid(take)
  local notes, per_chan, offgrid = {}, {}, 0
  for i = 0, count - 1 do
    local _, _, muted, sp, ep, chan, pitch, vel = reaper.MIDI_GetNote(take, i)
    local s = reaper.MIDI_GetProjQNFromPPQPos(take, sp) - q0
    local e = reaper.MIDI_GetProjQNFromPPQPos(take, ep) - q0
    if not muted and s < len and e > 0 then
      s, e = math.max(s, 0), math.min(e, len)
      notes[#notes + 1] = { pitch = pitch, start = round(s), length = round(e - s), velocity = vel }
      per_chan[chan] = (per_chan[chan] or 0) + 1
      if grid > 0 then offgrid = math.max(offgrid, math.abs(s - math.floor(s / grid + 0.5) * grid)) end
    end
  end
  table.sort(notes, function(a, b) return a.start < b.start or (a.start == b.start and a.pitch < b.pitch) end)

  local channel, most = 0, -1
  for c, n in pairs(per_chan) do
    if n > most or (n == most and c < channel) then channel, most = c, n end
  end

  local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local num, denom, bpm = reaper.TimeMap_GetTimeSigAtTime(0, pos)
  local _, track = reaper.GetSetMediaTrackInfo_String(reaper.GetMediaItemTrack(item), "P_NAME", "", false)
  return {
    track = track,
    take = reaper.GetTakeName(take) or "",
    tempo_bpm = round(bpm, 2),
    time_signature = string.format("%d/%d", num, denom),
    length_qn = round(len),
    length_bars = summary.length_bars(0, pos, pos + reaper.GetMediaItemInfo_Value(item, "D_LENGTH")),
    grid_qn = round(grid),
    swing = round(swing, 3),
    offgrid_max_qn = round(offgrid),
    channel = channel + 1,
    notes = notes,
  }
end

-- Adds a take named name to item holding notes on MIDI channel channel (1-16), spanning
-- length_qn quarter notes from the item start, and makes it the active take. The take is built
-- in the item's state chunk (D-32): a MIDI source made through the API has no length, so notes
-- cannot be inserted into it. Notes that start at or after length_qn are dropped, notes that run
-- past it are shortened, and a note that overlaps the next note of the same pitch ends where that
-- one starts (otherwise its note-off would cut the later note short). Returns the take and
-- { kept, shortened, dropped, trimmed }, or nil and a message.
function M.add_take(item, notes, name, length_qn, channel)
  local ok, chunk = reaper.GetItemStateChunk(item, "", false)
  if not ok then return nil, "cannot read the item" end
  local block = string.format('TAKE\nNAME "%s"\n<SOURCE MIDI\nHASDATA 1 960 QN\nE %d b0 7b 00\n>\n',
    (name:gsub('["\r\n]', "")), math.floor(length_qn * 960 + 0.5))
  local new_chunk, n = chunk:gsub(">%s*$", function() return block .. ">\n" end)
  if n ~= 1 or not reaper.SetItemStateChunk(item, new_chunk, false) then return nil, "cannot add a take to the item" end
  local take = reaper.GetTake(item, reaper.CountTakes(item) - 1)
  if not take or not reaper.TakeIsMIDI(take) then return nil, "the new take is not MIDI" end

  local stats = { kept = 0, shortened = 0, dropped = 0, trimmed = 0 }
  local todo, last = {}, {}
  for _, nt in ipairs(notes) do
    todo[#todo + 1] = { pitch = nt.pitch, velocity = nt.velocity, s = nt.start, e = math.min(nt.start + nt.length, length_qn), long = nt.start + nt.length > length_qn }
  end
  table.sort(todo, function(a, b) return a.s < b.s end)
  for _, nt in ipairs(todo) do
    local prev = last[nt.pitch]
    if prev and prev.e > nt.s then
      if nt.s > prev.s then stats.trimmed = stats.trimmed + 1 end   -- same start: prev becomes empty and is dropped
      prev.e = nt.s
    end
    last[nt.pitch] = nt
  end

  local q0 = item_span(item)
  for _, nt in ipairs(todo) do
    local sp = reaper.MIDI_GetPPQPosFromProjQN(take, q0 + nt.s)
    local ep = reaper.MIDI_GetPPQPosFromProjQN(take, q0 + nt.e)
    if nt.s >= length_qn or ep <= sp then
      stats.dropped = stats.dropped + 1
    else
      reaper.MIDI_InsertNote(take, false, false, sp, ep, channel - 1, nt.pitch, nt.velocity, true)
      stats.kept = stats.kept + 1
      if nt.long then stats.shortened = stats.shortened + 1 end
    end
  end
  reaper.MIDI_Sort(take)
  reaper.SetActiveTake(take)
  reaper.UpdateItemInProject(item)
  return take, stats
end

return M
