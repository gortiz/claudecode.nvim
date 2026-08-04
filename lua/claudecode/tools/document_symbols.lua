--- Tool implementation for listing document symbols (outline) via LSP.

local schema = {
  description = "Get the list of symbols (functions, classes, variables, etc.) defined in a file. Returns a structured outline of the document. The file must be open in the editor.",
  inputSchema = {
    type = "object",
    properties = {
      uri = {
        type = "string",
        description = "File URI (file:///path) or absolute path of the file",
      },
    },
    required = { "uri" },
    additionalProperties = false,
    ["$schema"] = "http://json-schema.org/draft-07/schema#",
  },
}

local SYMBOL_KIND = {
  [1] = "File",
  [2] = "Module",
  [3] = "Namespace",
  [4] = "Package",
  [5] = "Class",
  [6] = "Method",
  [7] = "Property",
  [8] = "Field",
  [9] = "Constructor",
  [10] = "Enum",
  [11] = "Interface",
  [12] = "Function",
  [13] = "Variable",
  [14] = "Constant",
  [15] = "String",
  [16] = "Number",
  [17] = "Boolean",
  [18] = "Array",
  [19] = "Object",
  [20] = "Key",
  [21] = "Null",
  [22] = "EnumMember",
  [23] = "Struct",
  [24] = "Event",
  [25] = "Operator",
  [26] = "TypeParameter",
}

---Flattens a DocumentSymbol tree into a list, preserving hierarchy via `containerName`.
---@param symbols table[]
---@param parent_name? string
---@return table[]
local function flatten_symbols(symbols, parent_name)
  local result = {}
  for _, sym in ipairs(symbols) do
    local entry = {
      name = sym.name,
      kind = SYMBOL_KIND[sym.kind] or tostring(sym.kind),
      line = sym.range and (sym.range.start.line + 1) or (sym.location and sym.location.range.start.line + 1),
      character = sym.range and (sym.range.start.character + 1)
        or (sym.location and sym.location.range.start.character + 1),
    }
    if parent_name then
      entry.containerName = parent_name
    elseif sym.containerName then
      entry.containerName = sym.containerName
    end
    table.insert(result, entry)
    -- Recurse into children (DocumentSymbol hierarchy)
    if sym.children and #sym.children > 0 then
      local children = flatten_symbols(sym.children, sym.name)
      for _, child in ipairs(children) do
        table.insert(result, child)
      end
    end
  end
  return result
end

---@param params table
---@return table MCP-compliant response
local function handler(params)
  local utils = require("claudecode.utils")
  local bufnr = utils.get_bufnr_from_uri(params.uri)

  local file_uri = vim.startswith(params.uri, "file://") and params.uri or vim.uri_from_fname(params.uri)
  local result = utils.lsp_request(bufnr, "textDocument/documentSymbol", {
    textDocument = { uri = file_uri },
  })

  if not result or #result == 0 then
    return {
      content = {
        { type = "text", text = vim.json.encode({ success = true, symbols = {}, count = 0 }) },
      },
    }
  end

  local symbols = flatten_symbols(result)

  return {
    content = {
      {
        type = "text",
        text = vim.json.encode({ success = true, symbols = symbols, count = #symbols }),
      },
    },
  }
end

return {
  name = "documentSymbols",
  schema = schema,
  handler = handler,
}
