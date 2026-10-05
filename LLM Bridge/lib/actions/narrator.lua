-- @noindex

-- The narrator action (D-51): describes the open project through the LLM bridge (docs/llm-bridge.md
-- §6; D-20 to D-30). Read-only: apply() changes nothing in the project. Used by scripts/narrator.lua,
-- scripts/lib/console.lua and tests/cases/narrator.lua.
local here = debug.getinfo(1, "S").source:match("^@(.*[\\/])")      -- <scripts>/lib/actions/
local root = here:match("^(.*[\\/])lib[\\/]actions[\\/]$")           -- <scripts>/
local bridge = dofile(root .. "lib/bridge.lua")
local summary = dofile(root .. "lib/project_summary.lua")

local M = { name = "narrator", title = "cb narrator", label = "Narrator" }

-- opts: { extra? }. Returns a run ({ spec } for bridge.start), or nil and a message for the user.
function M.build_request(opts)
  opts = opts or {}
  local prompt, err = bridge.read_prompt(M.name)
  if not prompt then return nil, err end
  return { spec = { action = M.name, prompt = prompt, extra = (opts.extra or ""):sub(1, 500), context = summary.collect(0) } }
end

function M.apply() return true end

-- The narration, then the highlights as a list.
function M.describe(_, result)
  local lines = { result.narration }
  if #result.highlights > 0 then lines[#lines + 1] = "" end
  for _, h in ipairs(result.highlights) do lines[#lines + 1] = "- " .. h end
  return lines
end

return M
