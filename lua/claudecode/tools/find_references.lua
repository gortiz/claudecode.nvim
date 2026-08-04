--- Tool implementation for finding all references to a symbol via LSP.

local schema = {
  description = "Find all references to a symbol at the given position across the workspace. The file must be open in the editor.",
  inputSchema = {
    type = "object",
    properties = {
      uri = {
        type = "string",
        description = "File URI (file:///path) or absolute path of the file containing the symbol",
      },
      line = {
        type = "integer",
        description = "1-indexed line number of the symbol",
      },
      character = {
        type = "integer",
        description = "1-indexed character offset of the symbol",
      },
      includeDeclaration = {
        type = "boolean",
        description = "Whether to include the symbol's own declaration in the results. Defaults to true.",
        default = true,
      },
    },
    required = { "uri", "line", "character" },
    additionalProperties = false,
    ["$schema"] = "http://json-schema.org/draft-07/schema#",
  },
}

---@param params table
---@return table MCP-compliant response
local function handler(params)
  local utils = require("claudecode.utils")
  local bufnr = utils.get_bufnr_from_uri(params.uri)

  local file_uri = vim.startswith(params.uri, "file://") and params.uri or vim.uri_from_fname(params.uri)
  local lsp_params = {
    textDocument = { uri = file_uri },
    position = { line = params.line - 1, character = params.character - 1 },
    context = { includeDeclaration = params.includeDeclaration ~= false },
  }

  local result = utils.lsp_request(bufnr, "textDocument/references", lsp_params)

  if not result or #result == 0 then
    return {
      content = {
        { type = "text", text = vim.json.encode({ success = true, references = {}, count = 0 }) },
      },
    }
  end

  local references = {}
  for _, loc in ipairs(result) do
    table.insert(references, {
      filePath = vim.uri_to_fname(loc.uri),
      line = loc.range.start.line + 1,
      character = loc.range.start.character + 1,
      endLine = loc.range["end"].line + 1,
      endCharacter = loc.range["end"].character + 1,
    })
  end

  return {
    content = {
      {
        type = "text",
        text = vim.json.encode({ success = true, references = references, count = #references }),
      },
    },
  }
end

return {
  name = "findReferences",
  schema = schema,
  handler = handler,
}
