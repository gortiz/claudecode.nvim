--- Interactive review sessions: a diff rendered in a Neovim buffer that both
--- the agent and the user can annotate, plus the plumbing that lets the agent
--- block until the user has said their piece.
---
--- This is the Neovim-native counterpart to an external TUI reviewer: the agent
--- opens a review, drops inline notes on the lines it wants to explain, and then
--- waits; the user reads, replies inline, and finishes; the agent reads the
--- replies back. Everything travels over the existing MCP connection.

local logger = require("claudecode.logger")
local parse = require("claudecode.review.parse")
local utils = require("claudecode.utils")

local M = {}

local NS_STATIC = vim.api.nvim_create_namespace("claudecode_review_static")
local NS_COMMENTS = vim.api.nvim_create_namespace("claudecode_review_comments")

---@class ClaudeCodeReviewComment
---@field id number
---@field author "agent"|"user"
---@field path string
---@field side "new"|"old"
---@field line number
---@field body string
---@field timestamp number
---@field anchored boolean False when the line was not in the diff and we snapped elsewhere

---@class ClaudeCodeReviewSession
---@field id string
---@field title string
---@field cwd string
---@field files ClaudeCodeReviewFile[]
---@field bufnr number
---@field comments ClaudeCodeReviewComment[]
---@field finished boolean

---@type ClaudeCodeReviewSession|nil
M.session = nil

---Outcome of the most recently finished review, kept after the session is torn
---down so a poller can still collect it. Cleared when a new review opens.
---@type table|nil
M.last_result = nil

local session_counter = 0

--- Highlight groups, all linked by default so colorschemes can override them.
local function setup_highlights()
  local links = {
    ClaudeCodeReviewFile = "Title",
    ClaudeCodeReviewStat = "Comment",
    ClaudeCodeReviewLineNr = "LineNr",
    ClaudeCodeReviewAgent = "DiagnosticVirtualTextInfo",
    ClaudeCodeReviewAgentLabel = "DiagnosticInfo",
    ClaudeCodeReviewUser = "DiagnosticVirtualTextWarn",
    ClaudeCodeReviewUserLabel = "DiagnosticWarn",
  }
  for group, target in pairs(links) do
    vim.api.nvim_set_hl(0, group, { link = target, default = true })
  end
end

local function has_inline_virt_text()
  return vim.fn.has("nvim-0.10") == 1
end

---Pick a window to host the review.
---
---Uses the shared helper when this checkout has it, and otherwise falls back to a
---local scan, so the review never depends on a utils API that may not be there.
---@return number|nil window
local function find_editor_window()
  if type(utils.find_main_editor_window) == "function" then
    return utils.find_main_editor_window()
  end
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    local buftype = vim.api.nvim_get_option_value("buftype", { buf = buf })
    local config = vim.api.nvim_win_get_config(win)
    if (not config.relative or config.relative == "") and buftype == "" then
      return win
    end
  end
  return nil
end

---------------------------------------------------------------------------
-- Rendering
---------------------------------------------------------------------------

local MARKERS = { context = " ", add = "+", delete = "-", message = "\\" }

---Turn the parsed file list into buffer lines plus the maps that let us go
---from a buffer row to a (path, side, line) coordinate and back.
---@param session ClaudeCodeReviewSession
local function build_lines(session)
  local lines = {}
  local line_map = {} -- 0-indexed row -> location
  local row_index = {} -- path -> { new = {line -> row}, old = {line -> row} }
  local file_rows = {} -- ordered list of {path = ..., row = ...}
  local hunk_rows = {}
  local max_line_number = 1

  for file_index, file in ipairs(session.files) do
    if file_index > 1 then
      lines[#lines + 1] = ""
    end

    local stat
    if file.status == "view" then
      stat = "viewing"
    elseif file.status == "binary" then
      stat = "binary"
    else
      stat = string.format("+%d −%d", file.additions, file.deletions)
    end
    local label = file.path
    if file.status == "renamed" and file.old_path and file.old_path ~= file.path then
      label = file.old_path .. " → " .. file.path
    elseif file.status == "added" then
      label = file.path .. " (new)"
    elseif file.status == "deleted" then
      label = file.path .. " (deleted)"
    end

    lines[#lines + 1] = string.format("▸ %s  %s", label, stat)
    file_rows[#file_rows + 1] = { path = file.path, row = #lines - 1, file_index = file_index }
    row_index[file.path] = row_index[file.path] or { new = {}, old = {} }

    for _, hunk in ipairs(file.hunks) do
      if hunk.header then
        lines[#lines + 1] = hunk.header
        hunk_rows[#hunk_rows + 1] = #lines - 1
        line_map[#lines - 1] = { path = file.path, kind = "hunk", file_index = file_index }
      end

      for _, entry in ipairs(hunk.lines) do
        lines[#lines + 1] = MARKERS[entry.kind] .. entry.text
        local row = #lines - 1
        line_map[row] = {
          path = file.path,
          kind = entry.kind,
          old_line = entry.old_line,
          new_line = entry.new_line,
          file_index = file_index,
        }
        if entry.new_line then
          row_index[file.path].new[entry.new_line] = row
          max_line_number = math.max(max_line_number, entry.new_line)
        end
        if entry.old_line then
          row_index[file.path].old[entry.old_line] = row
          max_line_number = math.max(max_line_number, entry.old_line)
        end
      end
    end

    if #file.hunks == 0 then
      lines[#lines + 1] = "  (no textual changes)"
    end
  end

  session.lines = lines
  session.line_map = line_map
  session.row_index = row_index
  session.file_rows = file_rows
  session.hunk_rows = hunk_rows
  session.number_width = #tostring(max_line_number)
end

---Paint the parts of the view that never change: file headers and the old/new
---line-number gutter. The buffer text itself stays a valid unified diff so
---`filetype=diff` gives us syntax highlighting for free.
---@param session ClaudeCodeReviewSession
local function apply_static_marks(session)
  vim.api.nvim_buf_clear_namespace(session.bufnr, NS_STATIC, 0, -1)

  for _, entry in ipairs(session.file_rows) do
    local text = session.lines[entry.row + 1] or ""
    vim.api.nvim_buf_set_extmark(session.bufnr, NS_STATIC, entry.row, 0, {
      end_col = #text,
      hl_group = "ClaudeCodeReviewFile",
    })
  end

  if not has_inline_virt_text() then
    return
  end

  local width = session.number_width
  local blank = string.rep(" ", width)
  for row, location in pairs(session.line_map) do
    if location.kind ~= "hunk" then
      local old = location.old_line and string.format("%" .. width .. "d", location.old_line) or blank
      local new = location.new_line and string.format("%" .. width .. "d", location.new_line) or blank
      vim.api.nvim_buf_set_extmark(session.bufnr, NS_STATIC, row, 0, {
        virt_text = { { old .. " " .. new .. " │", "ClaudeCodeReviewLineNr" } },
        virt_text_pos = "inline",
        right_gravity = false,
      })
    end
  end
end

---Wrap a comment body to the available width.
---@param body string
---@param width number
---@return string[]
local function wrap_body(body, width)
  local out = {}
  for _, paragraph in ipairs(vim.split(body, "\n", { plain = true })) do
    if paragraph == "" then
      out[#out + 1] = ""
    end
    local current = ""
    for word in paragraph:gmatch("%S+") do
      if current == "" then
        current = word
      elseif #current + #word + 1 <= width then
        current = current .. " " .. word
      else
        out[#out + 1] = current
        current = word
      end
    end
    if current ~= "" then
      out[#out + 1] = current
    end
  end
  if #out == 0 then
    out[1] = ""
  end
  return out
end

---@param session ClaudeCodeReviewSession
---@param comment ClaudeCodeReviewComment
---@return number|nil row
local function comment_row(session, comment)
  local index = session.row_index[comment.path]
  if not index then
    return nil
  end
  return index[comment.side][comment.line]
end

---Re-render every comment. Cheap enough that we never do partial updates.
---@param session ClaudeCodeReviewSession
local function apply_comment_marks(session)
  if not vim.api.nvim_buf_is_valid(session.bufnr) then
    return
  end
  vim.api.nvim_buf_clear_namespace(session.bufnr, NS_COMMENTS, 0, -1)

  local win_width = 100
  if session.win and vim.api.nvim_win_is_valid(session.win) then
    win_width = vim.api.nvim_win_get_width(session.win)
  end
  local indent = "    "
  local wrap_width = math.max(30, win_width - #indent - 12)

  -- Group by row so several comments on one line stack in id order.
  local by_row = {}
  for _, comment in ipairs(session.comments) do
    local row = comment_row(session, comment)
    if row then
      by_row[row] = by_row[row] or {}
      table.insert(by_row[row], comment)
    end
  end

  for row, comments in pairs(by_row) do
    local virt_lines = {}
    for _, comment in ipairs(comments) do
      local body_hl = comment.author == "agent" and "ClaudeCodeReviewAgent" or "ClaudeCodeReviewUser"
      local label_hl = comment.author == "agent" and "ClaudeCodeReviewAgentLabel" or "ClaudeCodeReviewUserLabel"
      local label = comment.author == "agent" and "claude" or "you"
      for index, text in ipairs(wrap_body(comment.body, wrap_width)) do
        if index == 1 then
          virt_lines[#virt_lines + 1] = {
            { indent .. "▌ ", label_hl },
            { label .. " #" .. comment.id .. ": ", label_hl },
            { text, body_hl },
          }
        else
          virt_lines[#virt_lines + 1] = {
            { indent .. "▌ ", label_hl },
            { string.rep(" ", #label + #tostring(comment.id) + 3) .. text, body_hl },
          }
        end
      end
    end

    local opts = { virt_lines = virt_lines, virt_lines_above = false }
    local ok = pcall(vim.api.nvim_buf_set_extmark, session.bufnr, NS_COMMENTS, row, 0, {
      virt_lines = virt_lines,
      virt_lines_above = false,
      sign_text = "▌",
      sign_hl_group = comments[1].author == "agent" and "ClaudeCodeReviewAgentLabel" or "ClaudeCodeReviewUserLabel",
    })
    if not ok then
      -- Older Neovim without extmark signs.
      vim.api.nvim_buf_set_extmark(session.bufnr, NS_COMMENTS, row, 0, opts)
    end
  end
end

---------------------------------------------------------------------------
-- Waiters
---------------------------------------------------------------------------

---Collect comments from a specific session rather than from module state, so a
---session that is being torn down can still report what it held.
---@param session ClaudeCodeReviewSession|nil
---@param filter {author?: string, since?: number}|nil
---@return table[]
local function collect_comments(session, filter)
  if not session then
    return {}
  end
  filter = filter or {}
  local author = filter.author
  if author == "all" then
    author = nil
  end
  local since = tonumber(filter.since) or 0

  local out = {}
  for _, comment in ipairs(session.comments) do
    if (not author or comment.author == author) and comment.id > since then
      out[#out + 1] = {
        id = comment.id,
        author = comment.author,
        path = comment.path,
        side = comment.side,
        line = comment.line,
        body = comment.body,
        timestamp = comment.timestamp,
      }
    end
  end
  return out
end

---@param session ClaudeCodeReviewSession
---@param status string
local function resolve_waiters(session, status, only_new_comments)
  local remaining = {}
  for _, waiter in ipairs(session.waiters) do
    local should_resolve = true
    if only_new_comments and waiter.kind == "finish" then
      should_resolve = false
    end
    if should_resolve then
      if waiter.timer then
        pcall(function()
          waiter.timer:stop()
          waiter.timer:close()
        end)
      end
      -- Read from the session being resolved, not from M.session: close() clears
      -- the global before resolving, and a waiter that reported zero comments
      -- because of that would be indistinguishable from a review nobody replied to.
      local ok, err = pcall(waiter.callback, {
        status = status,
        comments = collect_comments(session, { author = waiter.author, since = waiter.since }),
      })
      if not ok then
        logger.error("review", "Waiter callback failed: " .. tostring(err))
      end
    else
      remaining[#remaining + 1] = waiter
    end
  end
  session.waiters = remaining
end

---------------------------------------------------------------------------
-- User interaction
---------------------------------------------------------------------------

---@param session ClaudeCodeReviewSession
---@return table|nil location
local function location_under_cursor(session)
  if not session.win or not vim.api.nvim_win_is_valid(session.win) then
    return nil
  end
  local row = vim.api.nvim_win_get_cursor(session.win)[1] - 1
  local location = session.line_map[row]
  if not location or location.kind == "hunk" then
    return nil
  end
  return location
end

---Record a comment and refresh the view.
---@param session ClaudeCodeReviewSession
---@param comment ClaudeCodeReviewComment
local function push_comment(session, comment)
  comment.id = session.next_comment_id
  session.next_comment_id = session.next_comment_id + 1
  comment.timestamp = os.time()
  session.comments[#session.comments + 1] = comment
  return comment
end

---Unsent replies make the buffer dirty, which is what earns us :q protection for
---free — Neovim raises E37 rather than us imitating it. Sending or discarding clears
---the flag.
---@param session ClaudeCodeReviewSession
local function sync_modified(session)
  if session.wiping or not session.bufnr or not vim.api.nvim_buf_is_valid(session.bufnr) then
    return
  end
  local unsent = false
  for _, comment in ipairs(session.comments) do
    if comment.author == "user" then
      unsent = true
      break
    end
  end
  vim.api.nvim_set_option_value("modified", unsent, { buf = session.bufnr })
end

---@param session ClaudeCodeReviewSession
---@param body string
local function add_user_comment(session, body)
  body = vim.trim(body or "")
  if body == "" then
    return
  end
  local location = location_under_cursor(session)
  if not location then
    vim.notify("Put the cursor on a diff line to comment", vim.log.levels.WARN)
    return
  end
  local side = location.new_line and "new" or "old"
  push_comment(session, {
    author = "user",
    path = location.path,
    side = side,
    line = side == "new" and location.new_line or location.old_line,
    body = body,
    anchored = true,
  })
  apply_comment_marks(session)
  sync_modified(session)
  resolve_waiters(session, "comment", true)
end

---Multi-line comment editor in a scratch split.
---@param session ClaudeCodeReviewSession
local function open_comment_editor(session)
  local location = location_under_cursor(session)
  if not location then
    vim.notify("Put the cursor on a diff line to comment", vim.log.levels.WARN)
    return
  end

  local bufnr = vim.api.nvim_create_buf(false, true)
  -- acwrite so :w reaches the BufWriteCmd below. Writing a scratch buffer is the
  -- reflex, and it works where <C-s> gets eaten by terminal flow control.
  vim.api.nvim_set_option_value("buftype", "acwrite", { buf = bufnr })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = bufnr })
  vim.api.nvim_set_option_value("filetype", "markdown", { buf = bufnr })
  vim.api.nvim_buf_set_name(bufnr, "claude-review-comment-" .. bufnr)

  vim.cmd("botright 10split")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, bufnr)
  vim.api.nvim_set_option_value(
    "winbar",
    string.format(
      "Comment on %s:%d  —  <C-s> or :w send · <C-c> or q discard",
      location.path,
      location.new_line or location.old_line
    ),
    { win = win }
  )

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  local function submit()
    local body = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
    close()
    if session.win and vim.api.nvim_win_is_valid(session.win) then
      vim.api.nvim_set_current_win(session.win)
    end
    add_user_comment(session, body)
  end

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = bufnr,
    callback = submit,
  })

  for _, mode in ipairs({ "n", "i" }) do
    vim.keymap.set(mode, "<C-s>", submit, { buffer = bufnr, desc = "Submit review comment" })
    vim.keymap.set(mode, "<C-c>", close, { buffer = bufnr, desc = "Cancel review comment" })
  end
  vim.keymap.set("n", "q", close, { buffer = bufnr, desc = "Cancel review comment" })
  vim.cmd("startinsert")
end

---Delete the user's own comment anchored to the current line.
---@param session ClaudeCodeReviewSession
local function delete_comment_under_cursor(session)
  local location = location_under_cursor(session)
  if not location then
    return
  end
  local side = location.new_line and "new" or "old"
  local line = side == "new" and location.new_line or location.old_line
  for index = #session.comments, 1, -1 do
    local comment = session.comments[index]
    if comment.author == "user" and comment.path == location.path and comment.side == side and comment.line == line then
      table.remove(session.comments, index)
      apply_comment_marks(session)
      sync_modified(session)
      return
    end
  end
  vim.notify("No comment of yours on this line", vim.log.levels.INFO)
end

---Jump from the review to the real file the cursor sits on.
---@param session ClaudeCodeReviewSession
local function open_real_file(session)
  local location = location_under_cursor(session)
  if not location then
    return
  end
  local path = location.path
  if not path:match("^/") then
    path = session.cwd .. "/" .. path
  end
  if vim.fn.filereadable(path) == 0 then
    vim.notify("File not readable: " .. path, vim.log.levels.WARN)
    return
  end
  local target = find_editor_window()
  if target and target ~= session.win then
    vim.api.nvim_set_current_win(target)
  else
    vim.cmd("vsplit")
  end
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  if location.new_line then
    pcall(vim.api.nvim_win_set_cursor, 0, { location.new_line, 0 })
    vim.cmd("normal! zz")
  end
end

---Move the cursor to the next/previous row in a precomputed list.
---@param session ClaudeCodeReviewSession
---@param rows number[]
---@param direction 1|-1
local function jump_to(session, rows, direction)
  if not session.win or not vim.api.nvim_win_is_valid(session.win) then
    return
  end
  local current = vim.api.nvim_win_get_cursor(session.win)[1] - 1
  local sorted = vim.deepcopy(rows)
  table.sort(sorted)
  local target = nil
  if direction == 1 then
    for _, row in ipairs(sorted) do
      if row > current then
        target = row
        break
      end
    end
  else
    for index = #sorted, 1, -1 do
      if sorted[index] < current then
        target = sorted[index]
        break
      end
    end
  end
  if target then
    vim.api.nvim_win_set_cursor(session.win, { target + 1, 0 })
    vim.api.nvim_win_call(session.win, function()
      vim.cmd("normal! zz")
    end)
  end
end

local HELP = [[
Claude review — keys

  c        comment on this line (one line)
  C        comment on this line (multi-line editor)
             <C-s> or :w   send the comment
             <C-c> or q    discard it
  x        delete your comment on this line
  ]h / [h  next / previous hunk
  ]f / [f  next / previous file
  ]n / [n  next / previous comment
  <CR>     open the real file at this line

  :w       finish the review and send your replies
  :q       close — refused while replies are unsent, like any modified buffer
  :q!      discard the review and your replies
  q        same as :q
  ?        this help
]]

---@param session ClaudeCodeReviewSession
local function setup_keymaps(session)
  local bufnr = session.bufnr
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = bufnr, nowait = true, silent = true, desc = desc })
  end

  map("c", function()
    vim.ui.input({ prompt = "Review comment: " }, function(input)
      if input then
        add_user_comment(session, input)
      end
    end)
  end, "Comment on this line")

  map("C", function()
    open_comment_editor(session)
  end, "Comment on this line (multi-line)")

  map("x", function()
    delete_comment_under_cursor(session)
  end, "Delete your comment")

  map("<CR>", function()
    open_real_file(session)
  end, "Open the real file here")

  map("]h", function()
    jump_to(session, session.hunk_rows, 1)
  end, "Next hunk")
  map("[h", function()
    jump_to(session, session.hunk_rows, -1)
  end, "Previous hunk")

  local function file_rows()
    local rows = {}
    for _, entry in ipairs(session.file_rows) do
      rows[#rows + 1] = entry.row
    end
    return rows
  end
  map("]f", function()
    jump_to(session, file_rows(), 1)
  end, "Next file")
  map("[f", function()
    jump_to(session, file_rows(), -1)
  end, "Previous file")

  local function comment_rows()
    local rows = {}
    for _, comment in ipairs(session.comments) do
      local row = comment_row(session, comment)
      if row then
        rows[#rows + 1] = row
      end
    end
    return rows
  end
  map("]n", function()
    jump_to(session, comment_rows(), 1)
  end, "Next comment")
  map("[n", function()
    jump_to(session, comment_rows(), -1)
  end, "Previous comment")

  -- Deliberately NOT "finish". One keystroke that sends your replies and closes
  -- everything is far too easy to hit by accident; this is an ordinary :q, which
  -- Neovim refuses while replies are unsent.
  map("q", function()
    vim.cmd("q")
  end, "Close (refused while replies are unsent)")

  map("?", function()
    vim.notify(HELP, vim.log.levels.INFO, { title = "Claude review" })
  end, "Review help")
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

---Open a review session, replacing any session already on screen.
---@param opts {diff?: string, files?: string[], title?: string, cwd?: string, focus?: boolean}
---@return table summary
---@return string|nil error
function M.open(opts)
  opts = opts or {}
  local cwd = opts.cwd or vim.fn.getcwd()

  local files = {}
  if opts.diff and vim.trim(opts.diff) ~= "" then
    local parsed, err = parse.parse(opts.diff)
    if err then
      return nil, err
    end
    files = parsed
  end

  for _, path in ipairs(opts.files or {}) do
    local absolute = path:match("^/") and path or (cwd .. "/" .. path)
    if vim.fn.filereadable(absolute) == 0 then
      return nil, "cannot read file: " .. path
    end
    local ok, content = pcall(function()
      return table.concat(vim.fn.readfile(absolute), "\n")
    end)
    if not ok then
      return nil, "cannot read file: " .. path .. " (" .. tostring(content) .. ")"
    end
    local relative = absolute:sub(1, #cwd + 1) == (cwd .. "/") and absolute:sub(#cwd + 2) or absolute
    files[#files + 1] = parse.whole_file(relative, content)
  end

  if #files == 0 then
    return nil, "nothing to review: pass a non-empty 'diff' or at least one entry in 'files'"
  end

  M.close("replaced by a new review")
  M.last_result = nil -- a poller must never read the previous review as this one
  setup_highlights()

  session_counter = session_counter + 1
  local session = {
    id = "review-" .. session_counter,
    title = opts.title or ("Claude review " .. session_counter),
    cwd = cwd,
    files = files,
    comments = {},
    next_comment_id = 1,
    waiters = {},
    finished = false,
  }

  local bufnr = vim.api.nvim_create_buf(false, true)
  session.bufnr = bufnr
  build_lines(session)

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, session.lines)
  -- acwrite rather than nofile, and wipe rather than hide, is what makes Neovim's own
  -- E37 fire on :q while there are unsent comments. Imitating that protection with a
  -- confirm prompt would behave subtly differently from every other buffer; this IS
  -- the mechanism. :w finishes the review, :q! discards it.
  vim.api.nvim_set_option_value("buftype", "acwrite", { buf = bufnr })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = bufnr })
  vim.api.nvim_set_option_value("swapfile", false, { buf = bufnr })
  vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })
  vim.api.nvim_set_option_value("filetype", "diff", { buf = bufnr })
  vim.api.nvim_buf_set_name(bufnr, "claude-review-" .. session.id)
  -- Writing the diff into the buffer marks it modified, and on an acwrite buffer that
  -- would make a brand-new review refuse :q before anyone has said anything. Only the
  -- user's own replies should count as unsent.
  vim.api.nvim_set_option_value("modified", false, { buf = bufnr })

  local target = find_editor_window()
  if target then
    vim.api.nvim_win_set_buf(target, bufnr)
    session.win = target
  else
    vim.cmd("wincmd t")
    vim.cmd("leftabove vsplit")
    session.win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(session.win, bufnr)
  end

  vim.api.nvim_set_option_value("wrap", false, { win = session.win })
  vim.api.nvim_set_option_value("number", false, { win = session.win })
  vim.api.nvim_set_option_value("relativenumber", false, { win = session.win })
  vim.api.nvim_set_option_value("signcolumn", "yes", { win = session.win })
  pcall(
    vim.api.nvim_set_option_value,
    "winbar",
    session.title .. "  —  c comment · :w send · :q! discard · ? keys",
    { win = session.win }
  )

  apply_static_marks(session)
  setup_keymaps(session)

  -- :w means "I am done, send these" — the same reflex as accepting a diff.
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = bufnr,
    callback = function()
      M.finish("user wrote the review buffer")
    end,
  })

  -- If the user wipes the buffer we must not leave the agent hanging. `wiping` marks
  -- that Neovim is already tearing the buffer down, so the teardown below does not
  -- try to delete a buffer that is mid-wipe (E937).
  vim.api.nvim_create_autocmd({ "BufWipeout" }, {
    buffer = bufnr,
    once = true,
    callback = function()
      if M.session and M.session.bufnr == bufnr then
        M.session.wiping = true
        if not M.session.finished then
          -- Closing the window without writing is a DISCARD, not a send — the same
          -- meaning :q! has anywhere else. Waiters are still released, so nobody is
          -- left hanging, but they hear "closed" rather than "finished".
          M.close("review buffer closed without writing")
        end
      end
    end,
  })

  M.session = session

  if opts.focus ~= false then
    pcall(vim.api.nvim_set_current_win, session.win)
  end

  logger.debug("review", "Opened " .. session.id .. " with " .. #files .. " file(s)")
  return M.summary()
end

---Structure of the current review, so the agent knows which coordinates exist.
---@return table|nil
function M.summary()
  local session = M.session
  if not session then
    return nil
  end
  local files = {}
  for _, file in ipairs(session.files) do
    local hunks = {}
    for _, hunk in ipairs(file.hunks) do
      local first, last
      for _, entry in ipairs(hunk.lines) do
        if entry.new_line then
          first = first or entry.new_line
          last = entry.new_line
        end
      end
      hunks[#hunks + 1] = {
        header = hunk.header,
        context = hunk.context,
        old_start = hunk.old_start,
        new_start = hunk.new_start,
        new_first_line = first,
        new_last_line = last,
        lines = #hunk.lines,
      }
    end
    files[#files + 1] = {
      path = file.path,
      old_path = file.old_path,
      status = file.status,
      additions = file.additions,
      deletions = file.deletions,
      hunks = hunks,
    }
  end
  return {
    id = session.id,
    title = session.title,
    cwd = session.cwd,
    finished = session.finished,
    files = files,
    comment_count = #session.comments,
  }
end

---Add agent-authored notes.
---@param comments table[] Each {path, line, body, side?}
---@return table result
---@return string|nil error
function M.add_comments(comments)
  local session = M.session
  if not session then
    return nil, "no active review — open one first (nvim-review open ...)"
  end

  ---@return table|nil placed
  ---@return string|nil reason
  local function place(incoming)
    local path = incoming.path
    local body = incoming.body
    local side = incoming.side == "old" and "old" or "new"
    local line = tonumber(incoming.line)

    if type(path) ~= "string" or type(body) ~= "string" or not line then
      return nil, "each comment needs path, line and body"
    end

    local index = session.row_index[path]
    if not index then
      return nil, "path not in this review: " .. path
    end

    local anchored = index[side][line] ~= nil
    local final_line = line
    if not anchored then
      -- Snap to the nearest addressable line in the same file rather than
      -- dropping the note; report the move so the agent can correct itself.
      local best, best_distance = nil, math.huge
      for candidate in pairs(index[side]) do
        local distance = math.abs(candidate - line)
        if distance < best_distance then
          best, best_distance = candidate, distance
        end
      end
      if not best then
        return nil, "no " .. side .. "-side lines for " .. path
      end
      final_line = best
    end

    local comment = push_comment(session, {
      author = "agent",
      path = path,
      side = side,
      line = final_line,
      body = body,
      anchored = anchored,
    })
    return { id = comment.id, path = path, line = final_line, requested_line = line, anchored = anchored }
  end

  local placed, rejected = {}, {}
  for _, incoming in ipairs(comments) do
    local entry, reason = place(incoming)
    if entry then
      placed[#placed + 1] = entry
    else
      rejected[#rejected + 1] = { comment = incoming, reason = reason }
    end
  end

  apply_comment_marks(session)
  return { placed = placed, rejected = rejected }
end

---@param filter {author?: string, since?: number}|nil
---@return table[]
function M.get_comments(filter)
  -- After the session is gone, a poller (the CLI) still needs the outcome, so fall
  -- back to what the last finished review held.
  if not M.session and M.last_result then
    return collect_comments(M.last_result.session, filter)
  end
  return collect_comments(M.session, filter)
end

---Move the user's view to a coordinate in the review.
---@param path string
---@param line number
---@param side "new"|"old"|nil
---@return boolean ok
---@return string|nil error
function M.navigate(path, line, side)
  local session = M.session
  if not session then
    return false, "no active review — open one first (nvim-review open ...)"
  end
  local index = session.row_index[path]
  if not index then
    return false, "path not in this review: " .. tostring(path)
  end
  side = side == "old" and "old" or "new"
  local row = index[side][tonumber(line) or -1]
  if not row then
    -- Fall back to the file header so the jump still lands somewhere useful.
    for _, entry in ipairs(session.file_rows) do
      if entry.path == path then
        row = entry.row
        break
      end
    end
  end
  if not row then
    return false, "line not in this review"
  end
  if not session.win or not vim.api.nvim_win_is_valid(session.win) then
    return false, "review window is gone"
  end
  vim.api.nvim_win_set_cursor(session.win, { row + 1, 0 })
  vim.api.nvim_win_call(session.win, function()
    vim.cmd("normal! zz")
  end)
  return true
end

---Register a waiter that fires when the user comments or finishes.
---@param opts {mode: "comment"|"finish", author?: string, since?: number, timeout_ms?: number}
---@param callback fun(payload: table)
---@return boolean registered True when the caller must wait
function M.wait(opts, callback)
  local session = M.session
  if not session or session.finished then
    return false
  end

  local waiter = {
    kind = opts.mode,
    author = opts.author,
    since = opts.since,
    callback = callback,
  }

  if opts.timeout_ms and opts.timeout_ms > 0 then
    waiter.timer = vim.defer_fn(function()
      for index, candidate in ipairs(session.waiters) do
        if candidate == waiter then
          table.remove(session.waiters, index)
          break
        end
      end
      callback({ status = "timeout", comments = M.get_comments({ author = opts.author, since = opts.since }) })
    end, opts.timeout_ms)
  end

  session.waiters[#session.waiters + 1] = waiter
  return true
end

---The user is done: unblock anyone waiting and leave the buffer on screen.
---@param reason string|nil
function M.finish(reason)
  local session = M.session
  if not session or session.finished then
    return
  end
  session.finished = true
  -- The replies are on their way out, so the buffer is no longer dirty. Clearing this
  -- before teardown also stops :wq tripping over its own protection.
  if not session.wiping and session.bufnr and vim.api.nvim_buf_is_valid(session.bufnr) then
    pcall(vim.api.nvim_set_option_value, "modified", false, { buf = session.bufnr })
  end
  logger.debug("review", "Finished " .. session.id .. ": " .. tostring(reason))
  resolve_waiters(session, "finished", false)
  vim.notify("Review finished — Claude has your comments", vim.log.levels.INFO)
  M.close(reason)
end

---Tear the session down.
---@param reason string|nil
function M.close(reason)
  local session = M.session
  if not session then
    return
  end
  M.session = nil

  local status = session.finished and "finished" or "closed"

  -- Outlives the session on purpose: a poller (the CLI) asks after the user has
  -- already pressed q, by which point the session itself is gone.
  M.last_result = {
    id = session.id,
    status = status,
    reason = reason,
    finished_at = os.time(),
    session = session,
  }

  if not session.finished then
    session.finished = true
    resolve_waiters(session, "closed", false)
  else
    resolve_waiters(session, "finished", false)
  end

  -- Skip when Neovim is already wiping it: deleting a buffer that is mid-wipe raises
  -- E937 out of the autocommand, which surfaces as a failed :q.
  if not session.wiping and session.bufnr and vim.api.nvim_buf_is_valid(session.bufnr) then
    pcall(vim.api.nvim_buf_delete, session.bufnr, { force = true })
  end
  logger.debug("review", "Closed session: " .. tostring(reason))
end

-- Never leave the agent blocked on a Neovim that is going away.
vim.api.nvim_create_autocmd("VimLeavePre", {
  group = vim.api.nvim_create_augroup("ClaudeCodeReviewShutdown", { clear = true }),
  callback = function()
    M.close("neovim exiting")
  end,
})

return M
