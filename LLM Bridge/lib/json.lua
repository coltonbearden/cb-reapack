-- @noindex

-- Minimal JSON for the LLM bridge (D-24, D-29): encode requests, decode the bridge's responses.
-- Objects are tables with string keys, arrays are sequences. An empty table encodes as [];
-- json.object(t) marks a table as an object (decoded objects carry the mark, so {} survives a
-- round trip). JSON null decodes to json.null, so arrays keep their length.
local M = {}

M.null = setmetatable({}, { __tostring = function() return "null" end })
local OBJECT = {}

function M.object(t) return setmetatable(t or {}, OBJECT) end

-- ---------------------------------------------------------------- encode
local ESCAPES = { ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }

local function encode_string(s)
  return '"' .. s:gsub('[%c"\\]', function(c) return ESCAPES[c] or string.format("\\u%04x", c:byte()) end) .. '"'
end

local function is_array(t)
  if getmetatable(t) == OBJECT then return false end
  local n = 0
  for k in pairs(t) do
    if math.type(k) ~= "integer" or k < 1 then return false end
    n = n + 1
  end
  for i = 1, n do
    if t[i] == nil then error("json: sparse array", 0) end
  end
  return true
end

local function encode(v, out)
  local t = type(v)
  if v == nil or v == M.null then
    out[#out + 1] = "null"
  elseif t == "boolean" then
    out[#out + 1] = tostring(v)
  elseif t == "number" then
    if v ~= v or v == math.huge or v == -math.huge then error("json: cannot encode " .. tostring(v), 0) end
    out[#out + 1] = math.type(v) == "integer" and string.format("%d", v) or string.format("%.14g", v)
  elseif t == "string" then
    out[#out + 1] = encode_string(v)
  elseif t == "table" then
    if is_array(v) then
      out[#out + 1] = "["
      for i = 1, #v do
        if i > 1 then out[#out + 1] = "," end
        encode(v[i], out)
      end
      out[#out + 1] = "]"
    else
      local keys = {}
      for k in pairs(v) do
        if type(k) ~= "string" then error("json: object key is not a string: " .. tostring(k), 0) end
        keys[#keys + 1] = k
      end
      table.sort(keys)
      out[#out + 1] = "{"
      for i, k in ipairs(keys) do
        if i > 1 then out[#out + 1] = "," end
        out[#out + 1] = encode_string(k)
        out[#out + 1] = ":"
        encode(v[k], out)
      end
      out[#out + 1] = "}"
    end
  else
    error("json: cannot encode a " .. t, 0)
  end
end

function M.encode(v)
  local out = {}
  encode(v, out)
  return table.concat(out)
end

-- ---------------------------------------------------------------- decode
local function fail(i, msg) error(string.format("json: %s at position %d", msg, i), 0) end

local function skip_ws(s, i) return s:find("[^ \t\r\n]", i) or #s + 1 end

local SIMPLE = { ['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b', f = '\f', n = '\n', r = '\r', t = '\t' }

local function parse_string(s, i)   -- s:sub(i, i) is the opening quote
  local out, j = {}, i + 1
  while true do
    local c = s:sub(j, j)
    if c == "" then fail(j, "unterminated string") end
    if c == '"' then return table.concat(out), j + 1 end
    if c == "\\" then
      local e = s:sub(j + 1, j + 1)
      if SIMPLE[e] then
        out[#out + 1] = SIMPLE[e]
        j = j + 2
      elseif e == "u" then
        local hex = s:match("^%x%x%x%x", j + 2)
        if not hex then fail(j, "bad \\u escape") end
        local cp = tonumber(hex, 16)
        j = j + 6
        if cp >= 0xD800 and cp <= 0xDBFF then
          local lo = s:match("^\\u(%x%x%x%x)", j)
          local low = lo and tonumber(lo, 16)
          if not low or low < 0xDC00 or low > 0xDFFF then fail(j, "unpaired surrogate") end
          cp = 0x10000 + (cp - 0xD800) * 0x400 + (low - 0xDC00)
          j = j + 6
        elseif cp >= 0xDC00 and cp <= 0xDFFF then
          fail(j, "unpaired surrogate")
        end
        out[#out + 1] = utf8.char(cp)
      else
        fail(j, "bad escape")
      end
    elseif c:byte() < 32 then
      fail(j, "control character in string")
    else
      local k = s:find('[\0-\31"\\]', j) or #s + 1   -- copy the run of plain characters
      out[#out + 1] = s:sub(j, k - 1)
      j = k
    end
  end
end

local function parse_number(s, i)
  local j = s:match("^-?%d+()", i)
  if not j then fail(i, "bad number") end
  j = s:match("^%.%d+()", j) or j
  j = s:match("^[eE][-+]?%d+()", j) or j
  return tonumber(s:sub(i, j - 1)), j
end

local parse_value

local function parse_object(s, i)   -- s:sub(i, i) is "{"
  local obj = M.object({})
  i = skip_ws(s, i + 1)
  if s:sub(i, i) == "}" then return obj, i + 1 end
  while true do
    if s:sub(i, i) ~= '"' then fail(i, "expected a string key") end
    local key, v
    key, i = parse_string(s, i)
    i = skip_ws(s, i)
    if s:sub(i, i) ~= ":" then fail(i, "expected ':'") end
    v, i = parse_value(s, i + 1)
    obj[key] = v
    i = skip_ws(s, i)
    local d = s:sub(i, i)
    if d == "}" then return obj, i + 1 end
    if d ~= "," then fail(i, "expected ',' or '}'") end
    i = skip_ws(s, i + 1)
  end
end

local function parse_array(s, i)    -- s:sub(i, i) is "["
  local arr = {}
  i = skip_ws(s, i + 1)
  if s:sub(i, i) == "]" then return arr, i + 1 end
  while true do
    local v
    v, i = parse_value(s, i)
    arr[#arr + 1] = v
    i = skip_ws(s, i)
    local d = s:sub(i, i)
    if d == "]" then return arr, i + 1 end
    if d ~= "," then fail(i, "expected ',' or ']'") end
    i = i + 1
  end
end

function parse_value(s, i)
  i = skip_ws(s, i)
  local c = s:sub(i, i)
  if c == "{" then return parse_object(s, i) end
  if c == "[" then return parse_array(s, i) end
  if c == '"' then return parse_string(s, i) end
  if c == "-" or c:match("%d") then return parse_number(s, i) end
  if s:sub(i, i + 3) == "true" then return true, i + 4 end
  if s:sub(i, i + 4) == "false" then return false, i + 5 end
  if s:sub(i, i + 3) == "null" then return M.null, i + 4 end
  fail(i, c == "" and "unexpected end of input" or "unexpected character '" .. c .. "'")
end

function M.decode(s)
  if s:sub(1, 3) == "\239\187\191" then s = s:sub(4) end   -- UTF-8 BOM
  local v, i = parse_value(s, 1)
  i = skip_ws(s, i)
  if i <= #s then fail(i, "trailing characters") end
  return v
end

return M
