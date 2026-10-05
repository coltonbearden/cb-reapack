-- @noindex

-- State machine of the bridge console (D-52), with no ImGui in it: one tab per action module
-- (scripts/lib/actions/, D-51), each idle, running, done, error, timeout or cancelled, with the
-- text the window shows already rendered (status line, log, result). scripts/cb_console.lua calls
-- tick() once per defer cycle and then draws (scripts/lib/console_ui.lua); tests/cases/console.lua
-- drives it with no window. The instruction and the picks are remembered in ExtState (D-53).
local here = debug.getinfo(1, "S").source:match("^@(.*[\\/])")   -- <scripts>/lib/
local bridge = dofile(here .. "bridge.lua")
local json = dofile(here .. "json.lua")

local M = {}

M.POLL_S = 0.1          -- a running job is polled at most this often (docs/llm-bridge.md §2)
M.MAX_EXTRA = 500       -- request.schema.json's limit for the instruction
M.EFFORTS = { "low", "medium", "high" }
M.SECTION = "cb_console"
M.ALIVE_S = 2           -- the console's heartbeat (ExtState "alive", every defer cycle) counts this long

-- The console's command ID: _CB_CONSOLE where this repo's reaper-kb.ini registers it, else the
-- action ReaPack registered for the cb_console.lua package, which REAPER names after the file
-- (D-74; read-only, nothing is registered here). 0 when neither exists.
function M.console_command()
  local id = reaper.NamedCommandLookup("_CB_CONSOLE")
  if id ~= 0 then return id end
  local section = reaper.SectionFromUniqueID(0)
  local i = 0
  while true do
    local cmd, text = reaper.kbd_enumerateActions(section, i)
    if cmd == 0 then return 0 end
    if text:sub(-#"cb_console.lua") == "cb_console.lua" then return cmd end
    i = i + 1
  end
end

-- What scripts/narrator.lua and scripts/midi_variation.lua do (D-50): ask the console to show the
-- tab of `name` (non-persistent ExtState "tab"), and start the console (M.console_command) unless
-- its heartbeat is fresh. Returns true, or nil and a message.
function M.open(name)
  reaper.SetExtState(M.SECTION, "tab", name, false)
  local alive = tonumber(reaper.GetExtState(M.SECTION, "alive"))
  if alive and reaper.time_precise() - alive < M.ALIVE_S then return true end
  local id = M.console_command()
  if id == 0 then return nil, "cb console is not registered: install the cb_console.lua package with ReaPack" end
  reaper.Main_OnCommand(id, 0)
  return true
end

local Console = {}
Console.__index = Console

local function contains(list, value)
  for _, v in ipairs(list) do if v == value then return true end end
  return false
end

-- opts: { actions = { <module>, ... }, jobs_dir?, timeout_s?, memory? (true: load and save ExtState) }
function M.new(opts)
  local c = setmetatable({ order = {}, actions = {}, tabs = {}, jobs_dir = opts.jobs_dir, timeout_s = opts.timeout_s or bridge.TIMEOUT_S, memory = opts.memory }, Console)
  local config, err = bridge.config()
  c.config_error = err
  for _, action in ipairs(opts.actions) do
    local s = config and bridge.settings(action.name, config) or { models = {} }
    c.order[#c.order + 1] = action.name
    c.actions[action.name] = action
    c.tabs[action.name] = {
      name = action.name, title = action.title, label = action.label or action.title, state = "idle",
      status = err and ("error: " .. err) or "", log = {}, result = {},
      extra = "", models = s.models, default_model = s.model, default_effort = s.reasoningEffort,
      model = s.model, effort = s.reasoningEffort,
    }
    if c.memory then c:recall(action.name) end
  end
  return c
end

-- ExtState holds JSON-encoded values, so a multi-line instruction survives reaper-extstate.ini.
local function read_memory(key)
  local raw = reaper.GetExtState(M.SECTION, key)
  if raw == "" then return nil end
  local ok, value = pcall(json.decode, raw)
  return ok and type(value) == "string" and value or nil
end

-- Loads the remembered instruction and picks; a pick that is no longer offered falls back to the
-- action's default.
function Console:recall(name)
  local tab = self.tabs[name]
  tab.extra = read_memory(name .. ".extra") or tab.extra
  local model = read_memory(name .. ".model")
  if model and contains(tab.models, model) then tab.model = model end
  local effort = read_memory(name .. ".effort")
  if effort and contains(M.EFFORTS, effort) then tab.effort = effort end
end

-- Sets a tab's "extra", "model" or "effort", and remembers it when the console has memory.
function Console:set(name, key, value)
  local tab = self.tabs[name]
  assert(key == "extra" or key == "model" or key == "effort", "unknown field " .. tostring(key))
  tab[key] = value
  if self.memory then reaper.SetExtState(M.SECTION, name .. "." .. key, json.encode(value), true) end
end

local function fail(tab, state, message)
  tab.state, tab.status = state, state .. ": " .. message
  if tab.job then tab.status = tab.status .. " (job files: " .. tab.job.dir .. ")" end
  return false
end

-- Starts the tab's action with its instruction and picks. opts may override them for this call
-- ({ extra?, model?, effort?, offline_result? }; offline_result is the bridge's test field, D-29).
-- Returns true when a job is running; otherwise the tab's status says why.
function Console:start(name, opts)
  opts = opts or {}
  local tab, action = self.tabs[name], self.actions[name]
  if tab.state == "running" then return false end
  tab.job, tab.run, tab.applied, tab.elapsed = nil, nil, nil, nil
  tab.log, tab.result = {}, {}
  local extra, model, effort = opts.extra or tab.extra, opts.model or tab.model, opts.effort or tab.effort
  if #extra > M.MAX_EXTRA then return fail(tab, "error", string.format("the instruction has %d characters; the limit is %d", #extra, M.MAX_EXTRA)) end

  local ok, run, err = pcall(action.build_request, { extra = extra })
  if not ok then return fail(tab, "error", tostring(run)) end
  if not run then return fail(tab, "error", tostring(err)) end
  run.spec.options = { model = model, reasoningEffort = effort }
  run.spec.offline_result = opts.offline_result

  local job, serr = bridge.start(run.spec, { jobs_dir = self.jobs_dir, timeout_s = self.timeout_s })
  if not job then return fail(tab, "error", "the bridge did not start: " .. tostring(serr)) end
  tab.job, tab.run, tab.state, tab.next_poll = job, run, "running", 0
  tab.log = { "job " .. job.id, string.format("model %s, reasoning effort %s", tostring(model), tostring(effort)) }
  tab.status = string.format("waiting for the model, 0 s (gives up at %g s)", self.timeout_s)
  return true
end

-- Stops waiting for the tab's job (Job:cancel); the job directory stays.
function Console:cancel(name)
  local tab = self.tabs[name]
  if tab.state ~= "running" then return false end
  tab.job:cancel()
  tab.elapsed = tab.job:elapsed()
  fail(tab, "cancelled", string.format("after %d s; the bridge run finishes on its own and its answer is ignored", math.floor(tab.elapsed)))
  return true
end

local function finish_ok(self, tab)
  local job, action = tab.job, self.actions[tab.name]
  local ok, applied, err = pcall(action.apply, tab.run, job.result)
  if not ok then return fail(tab, "error", "applying the answer failed: " .. tostring(applied)) end
  if not applied then return fail(tab, "error", tostring(err)) end
  tab.applied = applied
  local dok, lines = pcall(action.describe, tab.run, job.result, applied)
  tab.result = dok and lines or { "describing the answer failed: " .. tostring(lines) }
  tab.state = "done"
  tab.status = string.format("done in %d s (%s)", math.floor(tab.elapsed), tostring(job.response.model))
end

-- One defer cycle: polls each running job (at most every POLL_S) and renders its state.
-- now defaults to reaper.time_precise().
function Console:tick(now)
  now = now or reaper.time_precise()
  for _, name in ipairs(self.order) do
    local tab = self.tabs[name]
    if tab.state == "running" then
      local status = "pending"
      if now >= tab.next_poll then
        tab.next_poll = now + M.POLL_S
        status = tab.job:poll()
      end
      if status == "pending" then
        tab.status = string.format("waiting for the model, %d s (gives up at %g s)", math.floor(tab.job:elapsed()), self.timeout_s)
      else
        tab.elapsed = tab.job:elapsed()
        if status == "ok" then finish_ok(self, tab) else fail(tab, status, tostring(tab.job.error)) end
      end
    end
  end
end

return M
