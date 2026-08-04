---Shared utility functions for claudecode.nvim
---@module 'claudecode.utils'

local M = {}

---Normalizes focus parameter to default to true for backward compatibility
---@param focus boolean? The focus parameter
---@return boolean valid Whether the focus parameter is valid
function M.normalize_focus(focus)
  if focus == nil then
    return true
  else
    return focus
  end
end

---Finds a suitable main editor window to open files in.
---Excludes terminals, sidebars, and floating windows.
---@return integer? win_id Window ID of the main editor window, or nil if not found
function M.find_main_editor_window()
  local windows = vim.api.nvim_list_wins()

  for _, win in ipairs(windows) do
    local buf = vim.api.nvim_win_get_buf(win)
    local buftype = vim.api.nvim_get_option_value("buftype", { buf = buf })
    local filetype = vim.api.nvim_get_option_value("filetype", { buf = buf })
    local win_config = vim.api.nvim_win_get_config(win)

    local is_suitable = true

    if win_config.relative and win_config.relative ~= "" then
      is_suitable = false
    end

    if is_suitable and (buftype == "terminal" or buftype == "nofile" or buftype == "prompt") then
      is_suitable = false
    end

    if
      is_suitable
      and (
        filetype == "neo-tree"
        or filetype == "neo-tree-popup"
        or filetype == "NvimTree"
        or filetype == "oil"
        or filetype == "minifiles"
        or filetype == "netrw"
        or filetype == "aerial"
        or filetype == "tagbar"
        or filetype == "snacks_picker_list"
      )
    then
      is_suitable = false
    end

    if is_suitable then
      return win
    end
  end

  return nil
end

---Resolves a file URI or path to an open buffer number.
---@param uri string File URI (file://...) or plain path
---@return integer bufnr Buffer number
---@return string filepath Resolved absolute file path
function M.get_bufnr_from_uri(uri)
  local filepath = vim.startswith(uri, "file://") and vim.uri_to_fname(uri) or uri
  local bufnr = vim.fn.bufnr(filepath)
  if bufnr == -1 then
    error({ code = -32001, message = "File not open", data = "File must be open in the editor: " .. filepath })
  end
  return bufnr, filepath
end

---Sends a synchronous LSP request and returns the first successful result.
---@param bufnr integer Buffer to send the request for
---@param method string LSP method name
---@param params table Request parameters
---@param timeout_ms? integer Timeout in milliseconds (default 5000)
---@return any result First non-nil result from any attached client, or nil
---@return string? offset_encoding Offset encoding of the responding client
function M.lsp_request(bufnr, method, params, timeout_ms)
  local results, err = vim.lsp.buf_request_sync(bufnr, method, params, timeout_ms or 5000)
  if err then
    error({ code = -32000, message = "LSP error", data = err })
  end
  if not results or vim.tbl_isempty(results) then
    return nil, nil
  end
  for client_id, response in pairs(results) do
    if not response.error and response.result ~= nil then
      local client = vim.lsp.get_client_by_id(client_id)
      local offset_encoding = client and client.offset_encoding or "utf-16"
      return response.result, offset_encoding
    end
  end
  return nil, nil
end

return M
