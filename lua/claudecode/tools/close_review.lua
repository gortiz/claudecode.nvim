--- Tool implementation for closing the active review session.

local schema = {
  description = "Close the active review and remove it from the editor. Call this when the discussion is over, so the user is not left with a stale diff on screen. Opening a new review closes the previous one automatically, so this is only needed to clean up.",
  inputSchema = {
    type = "object",
    properties = {
      reason = {
        type = "string",
        description = "Why the review is being closed. Shown in the log.",
      },
    },
    required = {},
    additionalProperties = false,
    ["$schema"] = "http://json-schema.org/draft-07/schema#",
  },
}

---@param params table
---@return table MCP-compliant response
local function handler(params)
  params = params or {}
  local review = require("claudecode.review")

  if not review.session then
    return { content = { { type = "text", text = "No active review to close" } } }
  end

  local id = review.session.id
  review.close(params.reason or "closed by the agent")

  return { content = { { type = "text", text = "Closed review " .. id } } }
end

return {
  name = "closeReview",
  schema = schema,
  handler = handler,
}
