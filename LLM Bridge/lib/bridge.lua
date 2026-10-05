-- @noindex

-- Lua side of the LLM bridge (D-21, D-22, D-28, D-29). start() writes request.json into a new job
-- directory and launches scripts/bridge/bridge.ps1 detached through conhost --headless, so no
-- window shows; job:poll() returns at once, so callers poll from reaper.defer and REAPER stays
-- usable. Used by the action modules (scripts/lib/actions/), the console (scripts/lib/console.lua)
-- and the bridge test cases.
local M = {}

M.SCHEMA_VERSION = 1
M.TIMEOUT_S = 60      -- D-22: the caller gives up after this, whatever the bridge is doing
M.READ_GRACE_S = 2    -- how long an existing response.json may refuse to open before that is an error

local here = debug.getinfo(1, "S").source:match("^@(.*[\\/])")   -- <scripts>/lib/
local root = here:sub(1, -5)                                     -- <scripts>/
local json = dofile(here .. "json.lua")

local Job = {}
Job.__index = Job

local function read_file(path)
  local fh, err = io.open(path, "rb")
  if not fh then return nil, err end
  local s = fh:read("a")
  fh:close()
  return s
end

local function write_file(path, text)
  local fh, err = io.open(path, "wb")
  if not fh then return nil, err end
  fh:write(text)
  fh:close()
  return true
end

-- The default prompt of an action, scripts/prompts/<action>.md (D-25), or nil and a message.
function M.read_prompt(action)
  local path = root .. "prompts/" .. action .. ".md"
  local text = read_file(path)
  if not text then return nil, "Prompt file missing: " .. path end
  return text
end

-- The config file the bridge uses (D-73): a user's own bridge/bridge.config.json if it exists, else
-- the shipped bridge/bridge.config.example.json. bridge.ps1 picks the same file.
function M.config_file()
  local own = root .. "bridge\\bridge.config.json"
  if reaper.file_exists(own) then return own end
  return root .. "bridge\\bridge.config.example.json"
end

-- The config (M.config_file) as a table, or nil and a message.
function M.config()
  local path = M.config_file()
  local name = path:match("[^\\/]+$")
  local text, err = read_file(path)
  if not text then return nil, "cannot read " .. name .. ": " .. tostring(err) end
  local ok, config = pcall(json.decode, text)
  if not ok or type(config) ~= "table" then return nil, name .. ": " .. tostring(config) end
  return config
end

-- What an action runs with unless the request overrides it: the config, then its
-- actions.<action> entry, as bridge.ps1 merges them (D-31, D-54). `models` is the config's list
-- of models a request may ask for.
function M.settings(action, config)
  local s = { model = config.model, reasoningEffort = config.reasoningEffort, temperature = config.temperature, maxTokens = config.maxTokens }
  local override = type(config.actions) == "table" and config.actions[action] or nil
  if type(override) == "table" then
    for _, key in ipairs({ "temperature", "maxTokens", "reasoningEffort" }) do
      if override[key] ~= nil then s[key] = override[key] end
    end
  end
  s.models = type(config.models) == "table" and config.models or { config.model }
  return s
end

function M.default_jobs_dir()
  local home = os.getenv("LOCALAPPDATA")
  return home and (home .. "\\reaper-bridge\\jobs") or nil
end

-- spec: { action, prompt, extra?, context, options?, offline_result? }  opts: { jobs_dir?, timeout_s? }
-- options: { model?, reasoningEffort? } for this run only (D-54).
-- Returns a job, or nil and a message when the request could not be started.
function M.start(spec, opts)
  opts = opts or {}
  local jobs = opts.jobs_dir or M.default_jobs_dir()
  if not jobs then return nil, "LOCALAPPDATA is not set" end
  local pwsh = (os.getenv("ProgramW6432") or os.getenv("ProgramFiles") or "C:\\Program Files") .. "\\PowerShell\\7\\pwsh.exe"
  if not reaper.file_exists(pwsh) then return nil, "PowerShell 7 not found at " .. pwsh end
  local script = root .. "bridge\\bridge.ps1"
  if not reaper.file_exists(script) then return nil, "bridge script missing: " .. script end

  local id = os.date("!%Y%m%dT%H%M%SZ") .. string.format("-%04x", math.random(0, 0xffff))
  local dir = jobs .. "\\" .. id
  if reaper.RecursiveCreateDirectory(dir, 0) == 0 then return nil, "cannot create " .. dir end

  local request = {
    schema_version = M.SCHEMA_VERSION,
    id = id,
    action = spec.action,
    created = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    prompt = spec.prompt,
    extra = spec.extra or "",
    context = json.object(spec.context),
    options = spec.options and json.object(spec.options) or nil,
    offline_result = spec.offline_result and json.object(spec.offline_result) or nil,
  }
  local ok, body = pcall(json.encode, request)
  if not ok then return nil, "cannot encode the request: " .. tostring(body) end
  local wrote, err = write_file(dir .. "\\request.json", body)
  if not wrote then return nil, "cannot write the request: " .. tostring(err) end

  local cmd = string.format('conhost.exe --headless "%s" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%s" -JobDir "%s"',
    pwsh, script, dir)
  if not reaper.ExecProcess(cmd, -2) then return nil, "could not start the bridge: " .. cmd end
  return setmetatable({ id = id, dir = dir, started = reaper.time_precise(), timeout_s = opts.timeout_s or M.TIMEOUT_S, status = "pending" }, Job)
end

function Job:elapsed() return reaper.time_precise() - self.started end

function Job:finish(status, err)
  self.status, self.error = status, err
  return status
end

-- Stops waiting: the job becomes "cancelled". bridge.ps1 is left to finish; its answer is ignored
-- and the job directory stays (D-29, D-52).
function Job:cancel()
  if self.status == "pending" then self:finish("cancelled", "cancelled; the bridge run finishes on its own and its answer is ignored") end
  return self.status
end

-- "pending" until the answer is in, then "ok" (self.result, self.response), "error" or "timeout"
-- (self.error says why), or "cancelled". Further calls return the same status.
function Job:poll()
  if self.status ~= "pending" then return self.status end
  local path = self.dir .. "\\response.json"
  if reaper.file_exists(path) then
    -- For a fraction of a millisecond after bridge.ps1 renames it into place, opening the file
    -- fails with "Permission denied"; keep polling, and only an open that keeps failing is an error.
    local text, open_err = read_file(path)
    if not text then
      self.unreadable_since = self.unreadable_since or reaper.time_precise()
      if reaper.time_precise() - self.unreadable_since < M.READ_GRACE_S then return "pending" end
      return self:finish("error", "cannot open " .. path .. ": " .. tostring(open_err))
    end
    local ok, resp = pcall(json.decode, text)
    if not ok then return self:finish("error", "unreadable response: " .. tostring(resp)) end
    if type(resp) ~= "table" then return self:finish("error", "response is not a JSON object") end
    if resp.schema_version ~= M.SCHEMA_VERSION then return self:finish("error", "unexpected schema_version " .. tostring(resp.schema_version)) end
    if resp.id ~= self.id then return self:finish("error", "response id " .. tostring(resp.id) .. " is not " .. self.id) end
    self.response = resp
    if resp.status == "ok" and type(resp.result) == "table" then
      self.result = resp.result
      return self:finish("ok")
    end
    return self:finish("error", type(resp.error) == "string" and resp.error or "the bridge reported an error")
  end
  if self:elapsed() >= self.timeout_s then
    return self:finish("timeout", string.format("no answer after %g s (bridge log: %s\\bridge.log)", self.timeout_s, self.dir))
  end
  return "pending"
end

return M
