--- Inline notes on the files you are actually working in.
---
--- The review surface renders a diff and owns its buffer. This one owns nothing: it
--- hangs comments off your real buffers, so editing, LSP, treesitter, undo and
--- everything else keep working exactly as they always do. There is no diff, no
--- rendered view to keep in sync, and nothing to flush — you write notes as you read,
--- and tell the agent to collect them when you are ready.
---
--- Anchoring is the whole trick: each note IS an extmark carrying its own virtual
--- lines, so it moves with your edits rather than pointing at a line number that went
--- stale ten insertions ago. When a buffer unloads, the extmark's last position is
--- written back to the stored line; when the file loads again, the note re-anchors
--- from there.

local logger = require("claudecode.logger")
local render = require("claudecode.annotations.render")

local M = {}

local NS = vim.api.nvim_create_namespace("claudecode_notes")

---@class ClaudeCodeNote
---@field id number
---@field author "agent"|"user"
---@field path string Absolute, symlink-resolved
---@field line number 1-indexed, authoritative only while not anchored
---@field body string
---@field timestamp number
---@field bufnr number|nil Set while anchored to a loaded buffer
---@field mark_id number|nil Extmark carrying both the anchor and the rendering

---@type table<number, ClaudeCodeNote>
M.notes = {}

local next_id = 1

---Absolute, symlink-resolved path, so the same file never keys two ways.
---@param path string
---@return string|nil
local function normalize(path)
  if type(path) ~= "string" or path == "" then
    return nil
  end
  local absolute = vim.fn.fnamemodify(path, ":p")
  local resolved = vim.uv and vim.uv.fs_realpath(absolute)
  return resolved or absolute
end

---@param path string
---@return number|nil bufnr Loaded buffer for that path, if any
local function loaded_buffer(path)
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      local name = vim.api.nvim_buf_get_name(bufnr)
      if name ~= "" and normalize(name) == path then
        return bufnr
      end
    end
  end
  return nil
end

---@param bufnr number
---@return number|nil winid
local function window_showing(bufnr)
  for _, winid in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(winid) == bufnr then
      return winid
    end
  end
  return nil
end

---Notes belonging to a buffer, in id order so stacking is stable.
---@param bufnr number
---@return ClaudeCodeNote[]
local function notes_for_buffer(bufnr)
  local out = {}
  for _, note in pairs(M.notes) do
    if note.bufnr == bufnr then
      out[#out + 1] = note
    end
  end
  table.sort(out, function(a, b)
    return a.id < b.id
  end)
  return out
end

---Where a note currently sits: from its extmark when anchored, else the stored line.
---@param note ClaudeCodeNote
---@return number line 1-indexed
function M.line_of(note)
  if note.bufnr and note.mark_id and vim.api.nvim_buf_is_valid(note.bufnr) then
    local position = vim.api.nvim_buf_get_extmark_by_id(note.bufnr, NS, note.mark_id, {})
    if position and position[1] then
      return position[1] + 1
    end
  end
  return note.line
end

---Draw every note in a buffer. Notes sharing a line stack in one extmark so their
---virtual lines cannot interleave with each other's.
---@param bufnr number
local function redraw(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local notes = notes_for_buffer(bufnr)
  local lines = {}
  for _, note in ipairs(notes) do
    local line = M.line_of(note)
    lines[line] = lines[line] or {}
    table.insert(lines[line], note)
  end

  vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)

  local width = render.wrap_width(window_showing(bufnr))
  local last_line = vim.api.nvim_buf_line_count(bufnr)

  for line, group in pairs(lines) do
    local row = math.max(0, math.min(line, last_line) - 1)
    local _, label_hl = render.styles(group[1].author)
    local ok, mark_id = pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, row, 0, {
      virt_lines = render.virt_lines(group, width),
      virt_lines_above = false,
      sign_text = "▌",
      sign_hl_group = label_hl,
    })
    if not ok then
      ok, mark_id = pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, row, 0, {
        virt_lines = render.virt_lines(group, width),
        virt_lines_above = false,
      })
    end
    -- Every note on this line shares the extmark, so they all move together.
    for _, note in ipairs(group) do
      note.mark_id = ok and mark_id or nil
      note.line = line
    end
  end
end

---Attach every stored note for a path to a freshly loaded buffer.
---@param bufnr number
function M.attach(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then
    return
  end
  local path = normalize(name)

  local found = false
  for _, note in pairs(M.notes) do
    if note.path == path then
      note.bufnr = bufnr
      found = true
    end
  end
  if found then
    render.setup_highlights()
    redraw(bufnr)
  end
end

---Freeze positions before a buffer goes away, so nothing is lost on reload.
---@param bufnr number
function M.detach(bufnr)
  for _, note in pairs(M.notes) do
    if note.bufnr == bufnr then
      note.line = M.line_of(note)
      note.bufnr = nil
      note.mark_id = nil
    end
  end
end

---Add a note.
---@param opts {path: string, line: number, body: string, author?: string, open?: boolean}
---@return ClaudeCodeNote|nil note
---@return string|nil error
function M.add(opts)
  opts = opts or {}
  local path = normalize(opts.path)
  local line = tonumber(opts.line)
  local body = opts.body

  if not path then
    return nil, "a note needs a path"
  end
  if not line or line < 1 then
    return nil, "a note needs a line number (1-indexed)"
  end
  if type(body) ~= "string" or vim.trim(body) == "" then
    return nil, "a note needs a body"
  end
  if vim.fn.filereadable(path) == 0 then
    return nil, "no such file: " .. path
  end

  local bufnr = loaded_buffer(path)
  if not bufnr then
    -- Load it so the note can anchor, but do not take over the user's window;
    -- `goto` is what puts a file in front of them.
    bufnr = vim.fn.bufadd(path)
    vim.fn.bufload(bufnr)
  end

  local note = {
    id = next_id,
    author = opts.author == "user" and "user" or "agent",
    path = path,
    line = line,
    body = body,
    timestamp = os.time(),
    bufnr = bufnr,
  }
  next_id = next_id + 1
  M.notes[note.id] = note

  render.setup_highlights()
  redraw(bufnr)
  logger.debug("notes", "Added note " .. note.id .. " on " .. path .. ":" .. line)
  return note
end

---@param filter {author?: string, since?: number, path?: string}|nil
---@return table[]
function M.list(filter)
  filter = filter or {}
  local author = filter.author
  if author == "all" then
    author = nil
  end
  local since = tonumber(filter.since) or 0
  local path = filter.path and normalize(filter.path) or nil

  local out = {}
  for _, note in pairs(M.notes) do
    if (not author or note.author == author) and note.id > since and (not path or note.path == path) then
      out[#out + 1] = {
        id = note.id,
        author = note.author,
        path = note.path,
        line = M.line_of(note),
        body = note.body,
        timestamp = note.timestamp,
      }
    end
  end
  table.sort(out, function(a, b)
    return a.id < b.id
  end)
  return out
end

---@param id number
---@return boolean removed
function M.remove(id)
  local note = M.notes[tonumber(id) or -1]
  if not note then
    return false
  end
  local bufnr = note.bufnr
  M.notes[note.id] = nil
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    redraw(bufnr)
  end
  return true
end

---@param opts {path?: string}|nil
---@return number removed
function M.clear(opts)
  opts = opts or {}
  local path = opts.path and normalize(opts.path) or nil

  local buffers, removed = {}, 0
  for id, note in pairs(M.notes) do
    if not path or note.path == path then
      if note.bufnr then
        buffers[note.bufnr] = true
      end
      M.notes[id] = nil
      removed = removed + 1
    end
  end
  for bufnr in pairs(buffers) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      redraw(bufnr)
    end
  end
  return removed
end

---Put a file and line in front of the user.
---@param path string
---@param line number|nil
---@return boolean ok
---@return string|nil error
function M.goto_location(path, line)
  local resolved = normalize(path)
  if not resolved or vim.fn.filereadable(resolved) == 0 then
    return false, "no such file: " .. tostring(path)
  end

  local bufnr = loaded_buffer(resolved)
  local winid = bufnr and window_showing(bufnr)

  if winid then
    vim.api.nvim_set_current_win(winid)
  else
    local target = require("claudecode.utils").find_main_editor_window
    local main = type(target) == "function" and target() or nil
    if main and vim.api.nvim_win_is_valid(main) then
      vim.api.nvim_set_current_win(main)
    end
    vim.cmd("edit " .. vim.fn.fnameescape(resolved))
    bufnr = vim.api.nvim_get_current_buf()
  end

  if line then
    local count = vim.api.nvim_buf_line_count(bufnr)
    pcall(vim.api.nvim_win_set_cursor, 0, { math.max(1, math.min(line, count)), 0 })
    vim.cmd("normal! zz")
  end
  return true
end

---Rows in a buffer that carry a note, for ]n / [n.
---@param bufnr number
---@return number[]
local function note_rows(bufnr)
  local rows = {}
  for _, note in ipairs(notes_for_buffer(bufnr)) do
    rows[#rows + 1] = M.line_of(note) - 1
  end
  table.sort(rows)
  return rows
end

---@param direction 1|-1
function M.jump(direction)
  local bufnr = vim.api.nvim_get_current_buf()
  local rows = note_rows(bufnr)
  if #rows == 0 then
    vim.notify("No notes in this buffer", vim.log.levels.INFO)
    return
  end

  local current = vim.api.nvim_win_get_cursor(0)[1] - 1
  local target
  if direction == 1 then
    for _, row in ipairs(rows) do
      if row > current then
        target = row
        break
      end
    end
    target = target or rows[1] -- wrap
  else
    for index = #rows, 1, -1 do
      if rows[index] < current then
        target = rows[index]
        break
      end
    end
    target = target or rows[#rows]
  end

  vim.api.nvim_win_set_cursor(0, { target + 1, 0 })
  vim.cmd("normal! zz")
end

---Add a note on the current line, prompting for the body.
function M.add_here()
  local bufnr = vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then
    vim.notify("This buffer is not a file", vim.log.levels.WARN)
    return
  end
  local line = vim.api.nvim_win_get_cursor(0)[1]

  vim.ui.input({ prompt = "Note: " }, function(input)
    if not input or vim.trim(input) == "" then
      return
    end
    local note, err = M.add({ path = name, line = line, body = input, author = "user" })
    if not note then
      vim.notify("claudecode notes: " .. tostring(err), vim.log.levels.ERROR)
    end
  end)
end

---Delete your own note on the current line.
function M.remove_here()
  local bufnr = vim.api.nvim_get_current_buf()
  local line = vim.api.nvim_win_get_cursor(0)[1]

  for _, note in ipairs(notes_for_buffer(bufnr)) do
    if note.author == "user" and M.line_of(note) == line then
      M.remove(note.id)
      return
    end
  end
  vim.notify("No note of yours on this line", vim.log.levels.INFO)
end

---Re-anchor notes as buffers come and go.
local group = vim.api.nvim_create_augroup("ClaudeCodeNotes", { clear = true })

vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile" }, {
  group = group,
  callback = function(event)
    M.attach(event.buf)
  end,
})

vim.api.nvim_create_autocmd({ "BufUnload", "BufDelete" }, {
  group = group,
  callback = function(event)
    M.detach(event.buf)
  end,
})

-- Wrapping follows the window, so a resize should reflow the notes.
vim.api.nvim_create_autocmd("WinResized", {
  group = group,
  callback = function()
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(bufnr) and #notes_for_buffer(bufnr) > 0 then
        redraw(bufnr)
      end
    end
  end,
})

M._redraw = redraw
M._normalize = normalize

return M
