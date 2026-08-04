--- Tool implementation for displaying content in a scratch buffer.

local schema = {
  description = "Display text content in a new buffer in the editor. Use this to show plans, summaries, reports, diffs, or any content longer than a few lines that the user should read in a proper editor window. Do NOT use nvim --server, nvim --remote, or shell commands to open content in the editor — always call this tool instead.",
  inputSchema = {
    type = "object",
    properties = {
      content = {
        type = "string",
        description = "The text content to display",
      },
      filetype = {
        type = "string",
        description = "Filetype for syntax highlighting (e.g. 'markdown', 'lua', 'python'). Defaults to 'markdown'.",
      },
      title = {
        type = "string",
        description = "Name shown in the statusline for the buffer. Defaults to a timestamped name.",
      },
      focus = {
        type = "boolean",
        description = "Whether to move editor focus to the new buffer. Defaults to true.",
        default = true,
      },
    },
    required = { "content" },
    additionalProperties = false,
    ["$schema"] = "http://json-schema.org/draft-07/schema#",
  },
}

---@param params table
---@return table MCP-compliant response
local function handler(params)
  if not params.content then
    error({ code = -32602, message = "Invalid params", data = "Missing required parameter: content" })
  end

  local filetype = params.filetype or "markdown"
  local focus = params.focus ~= false
  -- Avoid :// in the name — nvim treats it as a network path and may reject it
  local title = params.title or ("claude-output-" .. os.date("%H%M%S"))

  local bufnr = vim.api.nvim_create_buf(false, true)

  local lines = vim.split(params.content, "\n", { plain = true })
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

  -- Set options before naming so nvim doesn't try to stat the name as a file
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = bufnr })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = bufnr })
  vim.api.nvim_set_option_value("swapfile", false, { buf = bufnr })
  vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })
  vim.api.nvim_set_option_value("filetype", filetype, { buf = bufnr })
  vim.api.nvim_buf_set_name(bufnr, title)

  local target_win = require("claudecode.utils").find_main_editor_window()

  if target_win then
    vim.api.nvim_win_set_buf(target_win, bufnr)
    if focus then
      vim.api.nvim_set_current_win(target_win)
    end
  else
    -- No editor window found — navigate away from the terminal before splitting
    vim.cmd("wincmd t")
    local cur_buf = vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win())
    local cur_buftype = vim.api.nvim_get_option_value("buftype", { buf = cur_buf })
    if cur_buftype == "terminal" or cur_buftype == "nofile" or cur_buftype == "prompt" then
      vim.cmd("leftabove vsplit")
    else
      vim.cmd("vsplit")
    end
    vim.api.nvim_win_set_buf(vim.api.nvim_get_current_win(), bufnr)
  end

  return {
    content = {
      {
        type = "text",
        text = "Opened buffer '" .. title .. "' with " .. #lines .. " lines (" .. filetype .. ")",
      },
    },
  }
end

return {
  name = "showBuffer",
  schema = schema,
  handler = handler,
}
