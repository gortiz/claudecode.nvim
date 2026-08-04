--- Shell entry point for inline notes, mirroring claudecode.review.cli.
---
--- Same contract: ONE function, taking a path to a JSON request and returning a JSON
--- response, so a caller sends data rather than Lua and the editor never evaluates
--- anything an agent composed.

local notes = require("claudecode.notes")

local M = {}

---@param request table
---@return table response
local function dispatch(request)
  local action = request.action

  if action == "add" then
    local incoming = request.notes
    if type(incoming) ~= "table" or #incoming == 0 then
      -- Accept a single note too, so the common case is not a one-element array.
      if request.path and request.line and request.body then
        incoming = { { path = request.path, line = request.line, body = request.body } }
      else
        return { ok = false, error = "add needs a non-empty 'notes' array, or path/line/body" }
      end
    end

    local added, rejected = {}, {}
    for _, entry in ipairs(incoming) do
      local note, err = notes.add({
        path = entry.path,
        line = entry.line,
        body = entry.body,
        author = entry.author or request.author or "agent",
      })
      if note then
        added[#added + 1] = { id = note.id, path = note.path, line = note.line }
      else
        rejected[#rejected + 1] = { note = entry, reason = tostring(err) }
      end
    end

    if #added == 0 then
      return { ok = false, error = rejected[1] and rejected[1].reason or "no notes added" }
    end
    return { ok = true, data = { added = added, rejected = rejected } }
  end

  if action == "list" then
    return {
      ok = true,
      data = {
        notes = notes.list({ author = request.author, since = request.since, path = request.path }),
      },
    }
  end

  if action == "goto" then
    local ok, err = notes.goto_location(request.path, tonumber(request.line))
    if not ok then
      return { ok = false, error = tostring(err) }
    end
    return { ok = true, data = { path = request.path, line = request.line } }
  end

  if action == "remove" then
    if not request.id then
      return { ok = false, error = "remove needs an id" }
    end
    return { ok = true, data = { removed = notes.remove(request.id) } }
  end

  if action == "clear" then
    return { ok = true, data = { removed = notes.clear({ path = request.path }) } }
  end

  return { ok = false, error = "unknown action: " .. tostring(action) }
end

---@param request_path string
---@return string json
function M.run(request_path)
  local ok, result = pcall(function()
    if vim.fn.filereadable(request_path) == 0 then
      return { ok = false, error = "request file not readable: " .. request_path }
    end
    local raw = table.concat(vim.fn.readfile(request_path), "\n")
    local decoded_ok, request = pcall(vim.json.decode, raw)
    if not decoded_ok or type(request) ~= "table" then
      return { ok = false, error = "request is not valid JSON" }
    end
    return dispatch(request)
  end)

  if not ok then
    result = { ok = false, error = tostring(result) }
  end

  local encoded_ok, encoded = pcall(vim.json.encode, result)
  if not encoded_ok then
    return '{"ok":false,"error":"could not encode response"}'
  end
  return encoded
end

M._dispatch = dispatch

return M
