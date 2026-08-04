--- Tool implementation for reading back the comments left on a review.
---
--- With `wait` set this blocks, the same way openDiff does: the coroutine yields
--- and the deferred-response machinery answers once the user has acted.

local logger = require("claudecode.logger")

local schema = {
  description = "Read the comments on the active review. With wait='finish' this BLOCKS until the user finishes the review (they press q), which is the normal way to hand the conversation over to them: open a review, add your notes, then wait here. wait='comment' returns as soon as the user leaves a single comment. wait='none' just snapshots what is there right now.",
  inputSchema = {
    type = "object",
    properties = {
      wait = {
        type = "string",
        enum = { "none", "comment", "finish" },
        description = "'none' returns immediately; 'comment' blocks until the user leaves a comment; 'finish' blocks until the user finishes the review. Defaults to 'none'.",
      },
      author = {
        type = "string",
        enum = { "user", "agent", "all" },
        description = "Whose comments to return. Defaults to 'user' — your own notes are rarely what you want back.",
      },
      since = {
        type = "number",
        description = "Only return comments with an id greater than this. Use the highest id you have already seen to poll for new ones.",
      },
      timeout_ms = {
        type = "number",
        description = "Give up waiting after this many milliseconds and return what exists (status 'timeout'). Defaults to no timeout.",
      },
    },
    required = {},
    additionalProperties = false,
    ["$schema"] = "http://json-schema.org/draft-07/schema#",
  },
}

---@param status string
---@param comments table[]
---@return table MCP-compliant response
local function build_response(status, comments)
  local review = require("claudecode.review")
  local payload = {
    status = status,
    comments = comments,
    review = review.summary(),
  }

  local headline
  if status == "finished" then
    headline = string.format("The user finished the review with %d comment(s).", #comments)
  elseif status == "closed" then
    headline = string.format("The review was closed before it was finished; %d comment(s).", #comments)
  elseif status == "timeout" then
    headline = string.format("Timed out waiting; %d comment(s) so far.", #comments)
  elseif status == "comment" then
    headline = string.format("The user left %d new comment(s).", #comments)
  else
    headline = string.format("%d comment(s).", #comments)
  end

  return {
    content = { { type = "text", text = headline .. "\n" .. vim.json.encode(payload) } },
  }
end

---@param params table
---@return table MCP-compliant response
local function handler(params)
  params = params or {}
  local review = require("claudecode.review")
  local mode = params.wait or "none"
  local author = params.author or "user"
  local since = tonumber(params.since) or 0

  if mode ~= "none" and mode ~= "comment" and mode ~= "finish" then
    error({ code = -32602, message = "Invalid params", data = "wait must be 'none', 'comment' or 'finish'" })
  end

  local filter = { author = author, since = since }

  if mode == "none" then
    if not review.session then
      error({ code = -32000, message = "No active review", data = "Call openReview first" })
    end
    return build_response("ok", review.get_comments(filter))
  end

  local co, is_main = coroutine.running()
  if not co or is_main then
    error({
      code = -32000,
      message = "Internal server error",
      data = "getReviewComments must run in coroutine context when waiting",
    })
  end

  -- Waiting for a comment that already arrived would be a deadlock in slow
  -- motion; hand back what is there instead.
  if mode == "comment" then
    local existing = review.get_comments(filter)
    if #existing > 0 then
      return build_response("comment", existing)
    end
  end

  local registered = review.wait({
    mode = mode,
    author = author,
    since = since,
    timeout_ms = tonumber(params.timeout_ms),
  }, function(payload)
    local response = build_response(payload.status, payload.comments)
    local resume_success, resume_result = coroutine.resume(co, response)
    local co_key = tostring(co)

    if resume_success then
      if _G.claude_deferred_responses and _G.claude_deferred_responses[co_key] then
        _G.claude_deferred_responses[co_key](resume_result)
        _G.claude_deferred_responses[co_key] = nil
      else
        logger.error("review", "No deferred response sender found for coroutine: " .. co_key)
      end
    else
      logger.error("review", "Coroutine failed: " .. tostring(resume_result))
      if _G.claude_deferred_responses and _G.claude_deferred_responses[co_key] then
        _G.claude_deferred_responses[co_key]({
          error = {
            code = -32603,
            message = "Internal error",
            data = "Coroutine failed: " .. tostring(resume_result),
          },
        })
        _G.claude_deferred_responses[co_key] = nil
      end
    end
  end)

  if not registered then
    -- No session, or it finished while we were asking: answer with what we have
    -- rather than blocking forever.
    return build_response(review.session and "ok" or "closed", review.get_comments(filter))
  end

  -- Block until the user acts; the callback above sends the real response.
  return coroutine.yield()
end

return {
  name = "getReviewComments",
  schema = schema,
  handler = handler,
  requires_coroutine = true,
}
