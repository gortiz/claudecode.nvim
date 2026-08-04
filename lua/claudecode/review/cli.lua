--- Shell entry point for driving a review from outside Neovim.
---
--- Claude Code exposes only `mcp__ide__getDiagnostics` to the model, so the review
--- MCP tools — like every other tool this plugin advertises — are unreachable from
--- an agent. The way in that does work is the shell, over `nvim --server`.
---
--- This module is the whole surface of that route: ONE function, taking a path to a
--- JSON request and returning a JSON response. The caller never sends Lua, so the
--- editor never evaluates anything an agent composed; `--remote-expr` only ever says
--- `require("claudecode.review.cli").run(path)`.
---
--- Nothing here blocks. A caller that wants to wait polls `get`, which keeps
--- Neovim's main loop free.

local review = require("claudecode.review")

local M = {}

---@param request table
---@return table response
local function dispatch(request)
  local action = request.action

  if action == "open" then
    local diff = nil
    if request.diff_file then
      if vim.fn.filereadable(request.diff_file) == 0 then
        return { ok = false, error = "diff file not readable: " .. request.diff_file }
      end
      diff = table.concat(vim.fn.readfile(request.diff_file), "\n")
    end

    local summary, err = review.open({
      diff = diff,
      files = request.files,
      title = request.title,
      cwd = request.cwd,
      focus = request.focus,
    })
    if not summary then
      return { ok = false, error = tostring(err) }
    end
    return { ok = true, data = summary }
  end

  if action == "comment" then
    if type(request.comments) ~= "table" or #request.comments == 0 then
      return { ok = false, error = "comment needs a non-empty 'comments' array" }
    end
    local result, err = review.add_comments(request.comments)
    if not result then
      return { ok = false, error = tostring(err) }
    end
    return { ok = true, data = result }
  end

  if action == "navigate" then
    local ok, err = review.navigate(request.path, request.line, request.side)
    if not ok then
      return { ok = false, error = tostring(err) }
    end
    return { ok = true, data = { path = request.path, line = request.line } }
  end

  if action == "get" then
    local comments = review.get_comments({ author = request.author, since = request.since })
    local summary = review.summary()

    -- Two different questions, and a poller needs both:
    --   closed  — the review is gone, so nothing more will ever arrive
    --   sent    — the user wrote (:w), so there are replies to read *now*, while
    --             the review stays open and the conversation continues
    local closed = summary == nil or summary.finished == true
    local sent = false
    for _, comment in ipairs(comments) do
      if comment.author == "user" and comment.sent then
        sent = true
        break
      end
    end

    local status
    if closed then
      status = review.last_result and review.last_result.status or "closed"
    elseif sent then
      status = "sent"
    else
      status = "open"
    end

    return {
      ok = true,
      data = {
        status = status,
        closed = closed,
        sent = sent,
        -- Kept so a caller written against the old shape still stops polling.
        finished = closed,
        comments = comments,
        review = summary,
      },
    }
  end

  if action == "close" then
    if not review.session then
      return { ok = true, data = { closed = false, reason = "no active review" } }
    end
    local id = review.session.id
    review.close(request.reason or "closed from the shell")
    return { ok = true, data = { closed = true, id = id } }
  end

  if action == "send" then
    if not review.session then
      return { ok = false, error = "no active review to send from" }
    end
    review.send(request.reason or "sent from the shell")
    return { ok = true, data = { sent = true } }
  end

  if action == "finish" then
    if not review.session then
      return { ok = true, data = { finished = false, reason = "no active review" } }
    end
    review.finish(request.reason or "finished from the shell")
    return { ok = true, data = { finished = true } }
  end

  return { ok = false, error = "unknown action: " .. tostring(action) }
end

---Run one request. Returns the JSON response as a string, which is what
---`--remote-expr` prints back to the caller.
---@param request_path string Path to a JSON file holding the request
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
    -- Never let an error escape into the editor's message area; the caller gets it
    -- as data instead.
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
