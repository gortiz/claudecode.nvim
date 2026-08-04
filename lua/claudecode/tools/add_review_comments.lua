--- Tool implementation for leaving agent-authored notes on the active review.

local schema = {
  description = "Attach inline notes to lines of the active review (opened with openReview). This is how you explain a change to the user on the exact lines you mean, instead of describing it in prose. Comment on what the user would miss — intent, risk, a tradeoff — not on every hunk. Line numbers are new-side by default; pass side='old' to comment on a removed line.",
  inputSchema = {
    type = "object",
    properties = {
      comments = {
        type = "array",
        description = "Notes to place. Send them in one call rather than one call per note.",
        items = {
          type = "object",
          properties = {
            path = {
              type = "string",
              description = "File path exactly as reported by openReview.",
            },
            line = {
              type = "number",
              description = "Line number in the file (new side unless 'side' is 'old').",
            },
            side = {
              type = "string",
              enum = { "new", "old" },
              description = "Which side of the diff the line belongs to. Defaults to 'new'.",
            },
            body = {
              type = "string",
              description = "The note. Markdown-ish plain text; newlines are preserved.",
            },
          },
          required = { "path", "line", "body" },
          additionalProperties = false,
        },
      },
    },
    required = { "comments" },
    additionalProperties = false,
    ["$schema"] = "http://json-schema.org/draft-07/schema#",
  },
}

---@param params table
---@return table MCP-compliant response
local function handler(params)
  params = params or {}
  if type(params.comments) ~= "table" or #params.comments == 0 then
    error({ code = -32602, message = "Invalid params", data = "Missing required parameter: comments (non-empty array)" })
  end

  local review = require("claudecode.review")
  local result, err = review.add_comments(params.comments)
  if not result then
    error({ code = -32000, message = "Error adding review comments", data = tostring(err) })
  end

  local text = string.format("Placed %d comment(s)", #result.placed)
  local moved = {}
  for _, entry in ipairs(result.placed) do
    if not entry.anchored then
      moved[#moved + 1] = string.format("%s:%d (requested %d)", entry.path, entry.line, entry.requested_line)
    end
  end
  if #moved > 0 then
    text = text .. ". Not on a visible diff line, snapped to the nearest one: " .. table.concat(moved, ", ")
  end
  if #result.rejected > 0 then
    text = text .. string.format(". Rejected %d: %s", #result.rejected, vim.json.encode(result.rejected))
  end

  return {
    content = { { type = "text", text = text } },
  }
end

return {
  name = "addReviewComments",
  schema = schema,
  handler = handler,
}
