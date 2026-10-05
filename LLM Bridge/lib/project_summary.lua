-- @noindex

-- Read-only summary of a REAPER project for the LLM bridge (narrator, D-29): project settings,
-- tracks with their FX and items, master FX, markers and regions. Lists are capped so a request
-- stays small; what was left out is counted under "omitted". Times are seconds, bars are 1-based,
-- an end_bar is the bar line where something ends, and length_bars is how many bars it lasts
-- (fractional when it starts or ends inside a bar), so the model never has to count bars itself.
local M = {}

M.MAX_TRACKS, M.MAX_ITEMS, M.MAX_FX, M.MAX_MARKERS = 64, 24, 16, 64

local function round(x) return math.floor(x * 1000 + 0.5) / 1000 end

-- 1 µs late, so a position exactly on a bar line is not read as the end of the bar before.
local function bar_of(proj, t)
  local _, measures = reaper.TimeMap2_timeToBeats(proj, t + 1e-6)
  return (measures or 0) + 1
end

-- Bars from the project start to t, fractional inside a bar. The fraction is taken in quarter
-- notes, so it holds across time signature and tempo changes.
local function bar_pos(proj, t)
  local _, measure = reaper.TimeMap2_timeToBeats(proj, t + 1e-6)
  local _, qn_start, qn_end = reaper.TimeMap_GetMeasureInfo(proj, measure)
  return measure + (reaper.TimeMap2_timeToQN(proj, t) - qn_start) / (qn_end - qn_start)
end

function M.length_bars(proj, from, to) return round(bar_pos(proj, to) - bar_pos(proj, from)) end

local function fx_names(track, omitted)
  local names, n = {}, reaper.TrackFX_GetCount(track)
  for i = 0, math.min(n, M.MAX_FX) - 1 do
    local _, name = reaper.TrackFX_GetFXName(track, i)
    names[#names + 1] = reaper.TrackFX_GetEnabled(track, i) and name or (name .. " (bypassed)")
  end
  omitted.fx = omitted.fx + math.max(0, n - M.MAX_FX)
  return names
end

local function item_summary(proj, item)
  local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  local s = {
    start_s = round(pos), end_s = round(pos + len), length_s = round(len),
    start_bar = bar_of(proj, pos), end_bar = bar_of(proj, pos + len), length_bars = M.length_bars(proj, pos, pos + len),
    muted = reaper.GetMediaItemInfo_Value(item, "B_MUTE") == 1,
  }
  local take = reaper.GetActiveTake(item)
  if not take then
    s.kind = "empty"
  else
    s.take = reaper.GetTakeName(take) or ""
    if reaper.TakeIsMIDI(take) then
      local _, notes = reaper.MIDI_CountEvts(take)
      s.kind, s.notes = "midi", notes
    else
      s.kind = "audio"
    end
  end
  return s
end

function M.collect(proj)
  proj = proj or 0
  local num, denom, bpm = reaper.TimeMap_GetTimeSigAtTime(proj, 0)
  local length = reaper.GetProjectLength(proj)
  local ntracks = reaper.CountTracks(proj)
  local s = {
    project = {
      name = reaper.GetProjectName(proj),
      tempo_bpm = math.floor(bpm * 100 + 0.5) / 100,
      time_signature = string.format("%d/%d", num, denom),
      tempo_markers = reaper.CountTempoTimeSigMarkers(proj),
      length_s = round(length),
      end_bar = bar_of(proj, length),
      length_bars = M.length_bars(proj, 0, length),
      tracks = ntracks,
    },
    tracks = {}, markers = {}, regions = {},
    omitted = { tracks = math.max(0, ntracks - M.MAX_TRACKS), items = 0, fx = 0, markers = 0 },
  }
  s.master_fx = fx_names(reaper.GetMasterTrack(proj), s.omitted)

  for ti = 0, math.min(ntracks, M.MAX_TRACKS) - 1 do
    local tr = reaper.GetTrack(proj, ti)
    local _, name = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
    local nitems = reaper.CountTrackMediaItems(tr)
    local t = {
      index = ti + 1, name = name,
      depth = reaper.GetTrackDepth(tr),
      is_folder = reaper.GetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH") == 1,
      muted = reaper.GetMediaTrackInfo_Value(tr, "B_MUTE") == 1,
      solo = reaper.GetMediaTrackInfo_Value(tr, "I_SOLO") > 0,
      fx = fx_names(tr, s.omitted),
      item_count = nitems, items = {},
    }
    for ii = 0, math.min(nitems, M.MAX_ITEMS) - 1 do
      t.items[#t.items + 1] = item_summary(proj, reaper.GetTrackMediaItem(tr, ii))
    end
    s.omitted.items = s.omitted.items + math.max(0, nitems - M.MAX_ITEMS)
    s.tracks[#s.tracks + 1] = t
  end

  local nmarks = reaper.GetNumRegionsOrMarkers(proj)
  for i = 0, nmarks - 1 do
    if #s.markers + #s.regions >= M.MAX_MARKERS then
      s.omitted.markers = nmarks - i
      break
    end
    local m = reaper.GetRegionOrMarker(proj, i, "")
    local _, name = reaper.GetSetRegionOrMarkerInfo_String(proj, m, "P_NAME", "", false)
    local start = reaper.GetRegionOrMarkerInfo_Value(proj, m, "D_STARTPOS")
    if reaper.GetRegionOrMarkerInfo_Value(proj, m, "B_ISREGION") == 1 then
      local stop = reaper.GetRegionOrMarkerInfo_Value(proj, m, "D_ENDPOS")
      s.regions[#s.regions + 1] = { name = name, start_s = round(start), end_s = round(stop), start_bar = bar_of(proj, start), end_bar = bar_of(proj, stop), length_bars = M.length_bars(proj, start, stop) }
    else
      s.markers[#s.markers + 1] = { name = name, position_s = round(start), bar = bar_of(proj, start) }
    end
  end
  table.sort(s.markers, function(a, b) return a.position_s < b.position_s end)
  table.sort(s.regions, function(a, b) return a.start_s < b.start_s end)
  return s
end

return M
