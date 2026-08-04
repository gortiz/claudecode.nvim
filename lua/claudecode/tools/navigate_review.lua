--- Tool implementation for steering the user's view inside a review.

local schema = {
  description = "Move the user's cursor to a specific line of the active review. Use it to walk them through a change in the order that tells the clearest story — jump to a line, then explain it. Does not steal focus from whatever they are typing into.",
  inputSchema = {
    type = "object",
    properties = {
      path = {
        type = "string",
        description = "File path exactly as reported by openReview.",
      },
      line = {
        type = "number",
        description = "Line number to jump to. Falls back to the file header when the line is not part of the diff.",
      },
      side = {
        type = "string",
        enum = { "new", "old" },
        description = "Which side of the diff the line belongs to. Defaults to 'new'.",
      },
    },
    required = { "path", "line" },
    additionalProperties = false,
    ["$schema"] = "http://json-schema.org/draft-07/schema#",
  },
}

---@param params table
---@return table MCP-compliant response
local function handler(params)
  params = params or {}
  if not params.path or not params.line then
    error({ code = -32602, message = "Invalid params", data = "Missing required parameter: path and line" })
  end

  local review = require("claudecode.review")
  local ok, err = review.navigate(params.path, params.line, params.side)
  if not ok then
    error({ code = -32000, message = "Error navigating review", data = tostring(err) })
  end

  return {
    content = {
      { type = "text", text = string.format("Moved the review to %s:%d", params.path, params.line) },
    },
  }
end

return {
  name = "navigateReview",
  schema = schema,
  handler = handler,
}
