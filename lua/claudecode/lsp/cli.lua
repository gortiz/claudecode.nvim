--- Shell entry point for language-server actions, mirroring claudecode.notes.cli.
---
--- Claude Code never offers the plugin's LSP tools (findReferences, renameSymbol,
--- formatDocument, ...) to the model, so this exposes the same handlers through the
--- shell route instead. Same contract as the other CLIs: ONE function, taking a path
--- to a JSON request and returning a JSON response. The set of actions is fixed here;
--- the request carries data, never Lua or editor commands.
---
--- Differences from calling the MCP tools directly:
---   * the file does not have to be open: it is loaded into a hidden buffer, and the
---     call waits briefly for a language server to attach to it.
---   * a position can be given as a symbol name on a line instead of a column.
---   * rename and format write the buffers they changed to disk, so the caller's own
---     file reads see the result. Buffers that already had unsaved edits are left
---     alone and reported, never written over the user's work.
---   * status, start and stop manage the servers themselves. Large Java worktrees
---     are kept without a server on purpose (RAM), so nothing here starts one
---     implicitly: start is always an explicit request.

local M = {}

local DEFAULT_ATTACH_WAIT_MS = 5000

---Load a file into a buffer and give it a filetype, so its FileType autocommands
---run and language servers attach exactly as when the user opens it. bufload()
---alone reads the file but detects no filetype.
---@param path string
---@param force boolean|nil set b:lsp_force_start first, to bypass "no autostart here" rules
---@return number|nil bufnr
---@return string|nil error
local function load_buffer(path, force)
  if type(path) ~= "string" or path == "" then
    return nil, "missing path"
  end
  if vim.fn.filereadable(path) == 0 then
    return nil, "no such file: " .. path
  end

  local bufnr = vim.fn.bufnr(path)
  if bufnr == -1 then
    bufnr = vim.fn.bufadd(path)
  end
  if not vim.api.nvim_buf_is_loaded(bufnr) then
    -- The file is often open in another editor too (the user's own Neovim, in
    -- another pane). bufload() loads it anyway, but reports the swap file as
    -- E325, which --remote-expr turns into a failure. shortmess+=A silences it.
    local shortmess = vim.o.shortmess
    vim.opt.shortmess:append("A")
    local ok, err = pcall(vim.fn.bufload, bufnr)
    vim.o.shortmess = shortmess
    if not ok or not vim.api.nvim_buf_is_loaded(bufnr) then
      return nil, "could not load " .. path .. ": " .. tostring(err)
    end
  end
  if force then
    vim.b[bufnr].lsp_force_start = true
  end

  -- buf_call: configs resolve their root from buffer 0.
  vim.api.nvim_buf_call(bufnr, function()
    if vim.bo[bufnr].filetype == "" then
      vim.cmd("filetype detect")
    elseif force and #vim.lsp.get_clients({ bufnr = bufnr }) == 0 then
      vim.api.nvim_exec_autocmds("FileType", { pattern = vim.bo[bufnr].filetype, modeline = false })
    end
  end)
  -- One-shot: left set, a later :edit would restart a server the user stopped.
  vim.b[bufnr].lsp_force_start = nil
  return bufnr
end

---@param path string
---@return number|nil bufnr
---@return string|nil error
local function ensure_buffer(path, wait_ms)
  local bufnr, err = load_buffer(path, false)
  if not bufnr then
    return nil, err
  end

  local attached = vim.wait(wait_ms or DEFAULT_ATTACH_WAIT_MS, function()
    return #vim.lsp.get_clients({ bufnr = bufnr }) > 0
  end, 50)
  if not attached then
    return nil,
      "no language server attached to "
        .. path
        .. " (none running for it? start one with the start action; still starting? retry, or raise wait_ms)"
  end
  return bufnr
end

---@param client vim.lsp.Client
---@return table
local function describe_client(client)
  local buffers = {}
  for b in pairs(client.attached_buffers or {}) do
    if vim.api.nvim_buf_is_valid(b) then
      buffers[#buffers + 1] = vim.api.nvim_buf_get_name(b)
    end
  end
  table.sort(buffers)
  local rpc = client.rpc or {}
  return {
    id = client.id,
    name = client.name,
    root_dir = client.root_dir,
    pid = type(rpc.pid) == "number" and rpc.pid or nil,
    stopped = client:is_stopped(),
    buffers = buffers,
  }
end

---Clients matching every filter that is given: name, a root_dir prefix, or the
---buffer of a file.
local function matching_clients(request)
  local filter = {}
  if type(request.name) == "string" and request.name ~= "" then
    filter.name = request.name
  end
  if type(request.path) == "string" and request.path ~= "" then
    local bufnr = vim.fn.bufnr(request.path)
    if bufnr == -1 then
      return {}
    end
    filter.bufnr = bufnr
  end
  local root = type(request.root) == "string" and request.root ~= "" and request.root or nil

  local clients = {}
  for _, client in ipairs(vim.lsp.get_clients(filter)) do
    if not root or (client.root_dir and vim.startswith(client.root_dir, root)) then
      clients[#clients + 1] = client
    end
  end
  return clients
end

local function status()
  local clients = {}
  for _, client in ipairs(vim.lsp.get_clients()) do
    clients[#clients + 1] = describe_client(client)
  end
  return { ok = true, data = { nvim_pid = vim.fn.getpid(), clients = clients } }
end

---Start the server(s) for a file the way opening it would, but bypassing the
---user's "do not autostart here" rules: the buffer is flagged with
---b:lsp_force_start before its FileType autocommands run. Configs that exclude a
---tree must honour that flag; vim.lsp.enable() configs attach on FileType anyway.
local function start(request)
  local existing = vim.fn.bufnr(request.path or "")
  local already = existing ~= -1 and vim.lsp.get_clients({ bufnr = existing }) or {}

  local bufnr, err = load_buffer(request.path, true)
  if not bufnr then
    return { ok = false, error = err }
  end
  local path = request.path

  local attached = vim.wait(tonumber(request.wait_ms) or DEFAULT_ATTACH_WAIT_MS, function()
    return #vim.lsp.get_clients({ bufnr = bufnr }) > 0
  end, 50)
  if not attached then
    return {
      ok = false,
      error = "no language server attached to "
        .. path
        .. " (filetype '"
        .. vim.bo[bufnr].filetype
        .. "' has none configured?)",
    }
  end

  local clients = {}
  for _, client in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
    clients[#clients + 1] = describe_client(client)
  end
  -- Attached is not ready: jdtls answers requests only after importing the project.
  return { ok = true, data = { started = #already == 0, clients = clients } }
end

local function stop(request)
  local has_filter = (request.name and request.name ~= "")
    or (request.root and request.root ~= "")
    or (request.path and request.path ~= "")
  if not has_filter and not request.all then
    return { ok = false, error = "stop needs a name, a root or a file to match, or all" }
  end

  local clients = matching_clients(request)
  local stopped = {}
  for _, client in ipairs(clients) do
    stopped[#stopped + 1] = describe_client(client)
    client:stop()
  end

  -- jdtls can take a while to shut down cleanly; make sure the memory comes back.
  local ids = vim.tbl_map(function(c)
    return c.id
  end, stopped)
  -- is_stopped() turns true as soon as shutdown starts; the process (and its RAM)
  -- is gone only when the client drops out of the registry.
  local gone = vim.wait(10000, function()
    for _, id in ipairs(ids) do
      if vim.lsp.get_client_by_id(id) then
        return false
      end
    end
    return true
  end, 100)
  if not gone then
    for _, id in ipairs(ids) do
      local c = vim.lsp.get_client_by_id(id)
      if c then
        c:stop(true)
      end
    end
  end

  return { ok = true, data = { stopped = stopped, forced = not gone } }
end

---Resolve the 1-indexed column of a position: an explicit column, or the first
---whole-word occurrence of `symbol` on the line.
---@return number|nil column
---@return string|nil error
local function resolve_column(bufnr, request)
  local line = tonumber(request.line)
  if not line or line < 1 or line > vim.api.nvim_buf_line_count(bufnr) then
    return nil, "line out of range: " .. tostring(request.line)
  end
  if request.column then
    return tonumber(request.column)
  end
  if type(request.symbol) ~= "string" or request.symbol == "" then
    return nil, "need a column or a symbol to locate on line " .. line
  end

  local text = vim.api.nvim_buf_get_lines(bufnr, line - 1, line, false)[1] or ""
  local from = 1
  while true do
    local s, e = text:find(request.symbol, from, true)
    if not s then
      return nil, ("symbol '%s' not found on line %d: %s"):format(request.symbol, line, text)
    end
    local before = s > 1 and text:sub(s - 1, s - 1) or ""
    local after = text:sub(e + 1, e + 1)
    if not before:match("[%w_]") and not after:match("[%w_]") then
      return s
    end
    from = e + 1
  end
end

---Call one of the plugin's MCP tool handlers and unwrap its JSON text payload.
---@return table|nil data
---@return string|nil error
local function call_tool(module, params)
  local ok, result = pcall(require("claudecode.tools." .. module).handler, params)
  if not ok then
    if type(result) == "table" then
      return nil, tostring(result.data or result.message or vim.inspect(result))
    end
    return nil, tostring(result)
  end
  local text = result and result.content and result.content[1] and result.content[1].text
  local decoded_ok, data = pcall(vim.json.decode, text or "")
  if not decoded_ok or type(data) ~= "table" then
    return nil, "unexpected tool result: " .. tostring(text)
  end
  if data.success == false then
    return nil, data.message or "the language server returned nothing"
  end
  return data
end

local function modified_buffers()
  local set = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].modified then
      set[b] = true
    end
  end
  return set
end

---Write every buffer the action modified, except those that were already dirty.
---@param before table<number, boolean> buffers modified before the action
---@return string[] written
---@return string[] unsaved buffers with earlier edits by the user, left as they are
local function write_changes(before)
  local written, unsaved = {}, {}
  for b in pairs(modified_buffers()) do
    local name = vim.api.nvim_buf_get_name(b)
    if before[b] then
      unsaved[#unsaved + 1] = name
    elseif vim.bo[b].buftype == "" and name ~= "" then
      -- noautocmd: a format-on-save hook must not reformat whole files that a
      -- rename only touched on one line.
      vim.api.nvim_buf_call(b, function()
        vim.cmd("silent noautocmd write")
      end)
      written[#written + 1] = name
    end
  end
  table.sort(written)
  table.sort(unsaved)
  return written, unsaved
end

---@param request table
---@return table response
local function dispatch(request)
  local action = request.action
  if action == "status" then
    return status()
  end
  if action == "start" then
    return start(request)
  end
  if action == "stop" then
    return stop(request)
  end

  local known = {
    references = true,
    rename = true,
    format = true,
    symbols = true,
    info = true,
  }
  if not known[action] then
    return { ok = false, error = "unknown action: " .. tostring(action) }
  end

  local bufnr, err = ensure_buffer(request.path, tonumber(request.wait_ms))
  if not bufnr then
    return { ok = false, error = err }
  end

  if action == "symbols" then
    local data, tool_err = call_tool("document_symbols", { uri = request.path })
    if not data then
      return { ok = false, error = tool_err }
    end
    return { ok = true, data = data }
  end

  if action == "format" then
    local before = modified_buffers()
    local data, tool_err = call_tool("format_document", { uri = request.path })
    if not data then
      return { ok = false, error = tool_err }
    end
    if request.save ~= false then
      data.written, data.unsaved = write_changes(before)
    end
    return { ok = true, data = data }
  end

  local column, col_err = resolve_column(bufnr, request)
  if not column then
    return { ok = false, error = col_err }
  end
  local position = { uri = request.path, line = tonumber(request.line), character = column }

  if action == "references" then
    position.includeDeclaration = request.include_declaration ~= false
    local data, tool_err = call_tool("find_references", position)
    if not data then
      return { ok = false, error = tool_err }
    end
    return { ok = true, data = data }
  end

  if action == "info" then
    local data, tool_err = call_tool("get_symbol_info", position)
    if not data then
      return { ok = false, error = tool_err }
    end
    return { ok = true, data = data }
  end

  -- rename
  if type(request.new_name) ~= "string" or request.new_name == "" then
    return { ok = false, error = "rename needs a new name" }
  end
  position.newName = request.new_name
  local before = modified_buffers()
  local data, tool_err = call_tool("rename_symbol", position)
  if not data then
    return { ok = false, error = tool_err }
  end
  if request.save ~= false then
    data.written, data.unsaved = write_changes(before)
  end
  return { ok = true, data = data }
end

---@param request_path string
---@return string json
function M.run(request_path)
  local ok, result = pcall(function()
    if vim.fn.filereadable(request_path) == 0 then
      return { ok = false, error = "request file not readable: " .. request_path }
    end
    local raw = table.concat(vim.fn.readfile(request_path), "\n")
    local decoded_ok, request = pcall(vim.json.decode, raw)
    if not decoded_ok or type(request) ~= "table" then
      return { ok = false, error = "request is not valid JSON" }
    end
    return dispatch(request)
  end)

  if not ok then
    result = { ok = false, error = tostring(result) }
  end

  local encoded_ok, encoded = pcall(vim.json.encode, result)
  if not encoded_ok then
    return '{"ok":false,"error":"could not encode response"}'
  end
  return encoded
end

M._dispatch = dispatch
M._resolve_column = resolve_column

return M
