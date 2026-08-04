--- Tool implementation for getting symbol information via LSP.

local schema = {
  description = "Get information about a symbol at a given position: its documentation (hover) and definition location. The file must be open in the editor.",
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
    },
    required = { "uri", "line", "character" },
    additionalProperties = false,
    ["$schema"] = "http://json-schema.org/draft-07/schema#",
  },
}

---Extracts a plain string from an LSP hover response.
---@param contents any MarkupContent | MarkedString | MarkedString[]
---@return string
local function hover_to_string(contents)
  if type(contents) == "string" then
    return contents
  end
  if type(contents) == "table" then
    if contents.value then
      return contents.value
    end
    local parts = {}
    for _, item in ipairs(contents) do
      if type(item) == "string" then
        table.insert(parts, item)
      elseif type(item) == "table" and item.value then
        table.insert(parts, item.value)
      end
    end
    return table.concat(parts, "\n")
  end
  return ""
end

---@param params table
---@return table MCP-compliant response
local function handler(params)
  local utils = require("claudecode.utils")
  local bufnr = utils.get_bufnr_from_uri(params.uri)

  -- LSP uses 0-indexed positions; params are 1-indexed
  local position = { line = params.line - 1, character = params.character - 1 }
  local file_uri = vim.startswith(params.uri, "file://") and params.uri or vim.uri_from_fname(params.uri)
  local lsp_params = {
    textDocument = { uri = file_uri },
    position = position,
  }

  local hover_result = utils.lsp_request(bufnr, "textDocument/hover", lsp_params)
  local def_result = utils.lsp_request(bufnr, "textDocument/definition", lsp_params)

  local info = {}

  if hover_result and hover_result.contents then
    info.documentation = hover_to_string(hover_result.contents)
  end

  if def_result then
    local locations = vim.islist(def_result) and def_result or { def_result }
    local defs = {}
    for _, loc in ipairs(locations) do
      local loc_uri = loc.uri or loc.targetUri
      local range = loc.range or loc.targetSelectionRange
      if loc_uri and range then
        table.insert(defs, {
          filePath = vim.uri_to_fname(loc_uri),
          line = range.start.line + 1,
          character = range.start.character + 1,
        })
      end
    end
    if #defs > 0 then
      info.definitions = defs
    end
  end

  if not info.documentation and not info.definitions then
    return {
      content = {
        {
          type = "text",
          text = vim.json.encode({ success = false, message = "No symbol information found at this position" }),
        },
      },
    }
  end

  info.success = true
  return {
    content = {
      { type = "text", text = vim.json.encode(info) },
    },
  }
end

return {
  name = "getSymbolInfo",
  schema = schema,
  handler = handler,
}
