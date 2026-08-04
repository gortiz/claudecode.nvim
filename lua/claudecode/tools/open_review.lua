--- Tool implementation for opening an interactive review session.

local schema = {
  description = "Open an interactive review in the editor: a diff (or whole files) that you and the user annotate together with inline comments. Use this instead of pasting a large diff, a plan, or a walkthrough into chat — anything worth looking at together. After opening, call addReviewComments to explain the lines that matter, then getReviewComments with wait='finish' to block until the user has replied. Pass a unified diff in 'diff' (generate it yourself, e.g. `git diff`), or paths in 'files' to show whole files with every line addressable.",
  inputSchema = {
    type = "object",
    properties = {
      diff = {
        type = "string",
        description = "Unified diff text, e.g. the output of `git diff`, `git diff --staged` or `git show`.",
      },
      files = {
        type = "array",
        items = { type = "string" },
        description = "Paths to show in full (every line commentable). Use for walkthroughs of unchanged code, or for a plan written to a temp file.",
      },
      title = {
        type = "string",
        description = "Title shown above the review. Defaults to a generated name.",
      },
      cwd = {
        type = "string",
        description = "Base directory that relative paths resolve against. Defaults to Neovim's working directory.",
      },
      focus = {
        type = "boolean",
        description = "Whether to move editor focus to the review. Defaults to true.",
        default = true,
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

  if not params.diff and not params.files then
    error({
      code = -32602,
      message = "Invalid params",
      data = "Provide either 'diff' (unified diff text) or 'files' (paths to show in full)",
    })
  end

  local review = require("claudecode.review")
  local summary, err = review.open({
    diff = params.diff,
    files = params.files,
    title = params.title,
    cwd = params.cwd,
    focus = params.focus,
  })

  if not summary then
    error({ code = -32000, message = "Error opening review", data = tostring(err) })
  end

  return {
    content = {
      {
        type = "text",
        text = "Review opened. Use the paths and line numbers below when calling addReviewComments "
          .. "(line numbers are new-side unless you pass side='old').\n"
          .. vim.json.encode(summary),
      },
    },
  }
end

return {
  name = "openReview",
  schema = schema,
  handler = handler,
}
