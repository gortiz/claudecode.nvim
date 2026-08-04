--- Shared rendering for inline comments.
---
--- Both surfaces draw the same thing — a note attributed to "claude" or "you",
--- wrapped, as virtual lines under the line it is about. Only the *placement*
--- differs: a review resolves (path, side, line) through its diff coordinate map,
--- while annotations live on real buffers and ride extmarks. Keeping the drawing
--- here stops the two from drifting apart.

local M = {}

---Highlight groups, all linked by default so colorschemes can override them.
function M.setup_highlights()
  local links = {
    ClaudeCodeReviewFile = "Title",
    ClaudeCodeReviewStat = "Comment",
    ClaudeCodeReviewLineNr = "LineNr",
    ClaudeCodeReviewAgent = "DiagnosticVirtualTextInfo",
    ClaudeCodeReviewAgentLabel = "DiagnosticInfo",
    ClaudeCodeReviewUser = "DiagnosticVirtualTextWarn",
    ClaudeCodeReviewUserLabel = "DiagnosticWarn",
  }
  for group, target in pairs(links) do
    vim.api.nvim_set_hl(0, group, { link = target, default = true })
  end
end

---Wrap a comment body to the available width.
---@param body string
---@param width number
---@return string[]
function M.wrap_body(body, width)
  local out = {}
  for _, paragraph in ipairs(vim.split(body or "", "\n", { plain = true })) do
    if paragraph == "" then
      out[#out + 1] = ""
    end
    local current = ""
    for word in paragraph:gmatch("%S+") do
      if current == "" then
        current = word
      elseif #current + #word + 1 <= width then
        current = current .. " " .. word
      else
        out[#out + 1] = current
        current = word
      end
    end
    if current ~= "" then
      out[#out + 1] = current
    end
  end
  if #out == 0 then
    out[1] = ""
  end
  return out
end

---@param author string
---@return string body_hl, string label_hl, string label
function M.styles(author)
  if author == "agent" then
    return "ClaudeCodeReviewAgent", "ClaudeCodeReviewAgentLabel", "claude"
  end
  return "ClaudeCodeReviewUser", "ClaudeCodeReviewUserLabel", "you"
end

---Build the virt_lines for a group of comments that share a line.
---@param comments table[] Each needs `author`, `id` and `body`
---@param width number Text width available for the body
---@param indent string|nil Leading whitespace, defaults to four spaces
---@return table virt_lines
function M.virt_lines(comments, width, indent)
  indent = indent or "    "
  local virt_lines = {}

  for _, comment in ipairs(comments) do
    local body_hl, label_hl, label = M.styles(comment.author)
    local prefix = label .. " #" .. tostring(comment.id) .. ": "

    for index, text in ipairs(M.wrap_body(comment.body, width)) do
      if index == 1 then
        virt_lines[#virt_lines + 1] = {
          { indent .. "▌ ", label_hl },
          { prefix, label_hl },
          { text, body_hl },
        }
      else
        virt_lines[#virt_lines + 1] = {
          { indent .. "▌ ", label_hl },
          { string.rep(" ", #prefix) .. text, body_hl },
        }
      end
    end
  end

  return virt_lines
end

---Text width to wrap to, given the window a buffer is shown in (if any).
---@param winid number|nil
---@return number
function M.wrap_width(winid)
  local width = 100
  if winid and vim.api.nvim_win_is_valid(winid) then
    width = vim.api.nvim_win_get_width(winid)
  end
  return math.max(30, width - 16)
end

return M
