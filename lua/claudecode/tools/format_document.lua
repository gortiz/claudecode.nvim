--- Tool implementation for formatting a document.
--- Prefers conform.nvim if available, falls back to LSP formatting.

local schema = {
  description = "Format a document using the configured formatter. The file must be open in the editor.",
  inputSchema = {
    type = "object",
    properties = {
      uri = {
        type = "string",
        description = "File URI (file:///path) or absolute path of the file to format",
      },
    },
    required = { "uri" },
    additionalProperties = false,
    ["$schema"] = "http://json-schema.org/draft-07/schema#",
  },
}

---@param params table
---@return table MCP-compliant response
local function handler(params)
  local utils = require("claudecode.utils")
  local bufnr, filepath = utils.get_bufnr_from_uri(params.uri)

  -- Prefer conform.nvim if available
  local conform_ok, conform = pcall(require, "conform")
  if conform_ok then
    local ok, err = conform.format({ bufnr = bufnr, async = false, lsp_fallback = true })
    if not ok then
      error({ code = -32000, message = "Format error", data = tostring(err) })
    end
    return {
      content = {
        { type = "text", text = vim.json.encode({ success = true, filePath = filepath, formatter = "conform" }) },
      },
    }
  end

  -- Fall back to LSP formatting
  local file_uri = vim.startswith(params.uri, "file://") and params.uri or vim.uri_from_fname(params.uri)
  local result, offset_encoding = utils.lsp_request(bufnr, "textDocument/formatting", {
    textDocument = { uri = file_uri },
    options = {
      tabSize = vim.api.nvim_get_option_value("tabstop", { buf = bufnr }),
      insertSpaces = vim.api.nvim_get_option_value("expandtab", { buf = bufnr }),
    },
  })

  if not result or #result == 0 then
    return {
      content = {
        {
          type = "text",
          text = vim.json.encode({ success = true, filePath = filepath, message = "No formatting changes" }),
        },
      },
    }
  end

  vim.lsp.util.apply_text_edits(result, bufnr, offset_encoding or "utf-16")

  return {
    content = {
      { type = "text", text = vim.json.encode({ success = true, filePath = filepath, formatter = "lsp" }) },
    },
  }
end

return {
  name = "formatDocument",
  schema = schema,
  handler = handler,
}
