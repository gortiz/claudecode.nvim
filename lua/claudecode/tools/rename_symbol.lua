--- Tool implementation for renaming a symbol across the workspace via LSP.

local schema = {
  description = "Rename a symbol (variable, function, class, etc.) at the given position across all files in the workspace using the language server. The file must be open in the editor.",
  inputSchema = {
    type = "object",
    properties = {
      uri = {
        type = "string",
        description = "File URI (file:///path) or absolute path of the file containing the symbol",
      },
      line = {
        type = "integer",
        description = "1-indexed line number of the symbol to rename",
      },
      character = {
        type = "integer",
        description = "1-indexed character offset of the symbol to rename",
      },
      newName = {
        type = "string",
        description = "The new name for the symbol",
      },
    },
    required = { "uri", "line", "character", "newName" },
    additionalProperties = false,
    ["$schema"] = "http://json-schema.org/draft-07/schema#",
  },
}

---@param params table
---@return table MCP-compliant response
local function handler(params)
  if not params.newName or params.newName == "" then
    error({ code = -32602, message = "Invalid params", data = "Missing or empty newName parameter" })
  end

  local utils = require("claudecode.utils")
  local bufnr, filepath = utils.get_bufnr_from_uri(params.uri)

  local file_uri = vim.startswith(params.uri, "file://") and params.uri or vim.uri_from_fname(params.uri)
  local lsp_params = {
    textDocument = { uri = file_uri },
    position = { line = params.line - 1, character = params.character - 1 },
    newName = params.newName,
  }

  local result, offset_encoding = utils.lsp_request(bufnr, "textDocument/rename", lsp_params)

  if not result then
    return {
      content = {
        {
          type = "text",
          text = vim.json.encode({ success = false, message = "Language server returned no rename result" }),
        },
      },
    }
  end

  -- Apply the workspace edit returned by the LSP
  vim.lsp.util.apply_workspace_edit(result, offset_encoding or "utf-16")

  -- Count affected files
  local changed_files = {}
  if result.changes then
    for uri in pairs(result.changes) do
      table.insert(changed_files, vim.uri_to_fname(uri))
    end
  elseif result.documentChanges then
    for _, change in ipairs(result.documentChanges) do
      if change.textDocument then
        table.insert(changed_files, vim.uri_to_fname(change.textDocument.uri))
      end
    end
  end

  return {
    content = {
      {
        type = "text",
        text = vim.json.encode({
          success = true,
          newName = params.newName,
          filePath = filepath,
          changedFiles = changed_files,
          changedFileCount = #changed_files,
          message = "Renamed symbol to '" .. params.newName .. "' across " .. #changed_files .. " file(s)",
        }),
      },
    },
  }
end

return {
  name = "renameSymbol",
  schema = schema,
  handler = handler,
}
