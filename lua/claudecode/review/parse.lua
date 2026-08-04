--- Unified diff parsing for the review UI.
---
--- Pure Lua on purpose: no `vim.*` calls, so the parser is testable under plain
--- busted without a Neovim host.
---
--- The output model mirrors what a reviewer needs to address a line: every
--- content line carries the old and/or new line number it belongs to, which is
--- what comments anchor to.

local M = {}

---@class ClaudeCodeReviewLine
---@field kind "context"|"add"|"delete"|"message"
---@field text string Line content without the leading diff marker
---@field old_line number|nil Line number in the old file (nil for additions)
---@field new_line number|nil Line number in the new file (nil for deletions)

---@class ClaudeCodeReviewHunk
---@field header string|nil The raw `@@ ... @@` line
---@field context string|nil Trailing context after the second `@@` (function name)
---@field old_start number
---@field new_start number
---@field lines ClaudeCodeReviewLine[]

---@class ClaudeCodeReviewFile
---@field path string Path in the new tree (or old tree for deletions)
---@field old_path string|nil Path in the old tree when it differs (renames)
---@field status "modified"|"added"|"deleted"|"renamed"|"binary"|"view"
---@field hunks ClaudeCodeReviewHunk[]
---@field additions number
---@field deletions number

---Split text into lines, tolerating CRLF and a missing trailing newline.
---@param text string
---@return string[]
local function split_lines(text)
  local lines = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    lines[#lines + 1] = (line:gsub("\r$", ""))
  end
  -- The trailing "" produced by a text that already ended in \n is noise.
  if #lines > 0 and lines[#lines] == "" and text:sub(-1) == "\n" then
    table.remove(lines)
  end
  return lines
end

---Undo git's C-style quoting of paths containing special characters.
---@param path string
---@return string
local function unquote(path)
  if path:sub(1, 1) ~= '"' or path:sub(-1) ~= '"' then
    return path
  end
  local inner = path:sub(2, -2)
  local out = inner:gsub("\\(%d%d%d)", function(octal)
    return string.char(tonumber(octal, 8))
  end)
  out = out:gsub("\\(.)", function(char)
    local escapes = { t = "\t", n = "\n", r = "\r", ['"'] = '"', ["\\"] = "\\" }
    return escapes[char] or char
  end)
  return out
end

---Strip the `a/` or `b/` prefix git puts on diff paths.
---@param path string
---@return string
local function strip_prefix(path)
  path = unquote(path)
  if path == "/dev/null" then
    return path
  end
  return (path:gsub("^[ab]/", ""))
end

---Extract the path from a `--- ` / `+++ ` header, dropping the trailing tab
---metadata that some diff producers append.
---@param line string
---@return string
local function header_path(line)
  local path = line:sub(5)
  path = path:gsub("\t.*$", "")
  return strip_prefix(path)
end

---@return ClaudeCodeReviewFile
local function new_file_entry()
  return { path = nil, old_path = nil, status = "modified", hunks = {}, additions = 0, deletions = 0 }
end

---Parse a unified diff into a list of files.
---
---Accepts `git diff` output (with `diff --git` headers) as well as bare
---`diff -u` output that only has `---`/`+++`/`@@` lines.
---@param diff_text string
---@return ClaudeCodeReviewFile[] files
---@return string|nil error
function M.parse(diff_text)
  if type(diff_text) ~= "string" then
    return {}, "diff must be a string"
  end

  local files = {}
  local file = nil
  local hunk = nil
  local pending_old, pending_new = 0, 0
  local old_line, new_line = 0, 0

  ---Close the current file, keeping it only if it carried any information.
  local function flush_file()
    if file and file.path then
      files[#files + 1] = file
    end
    file = nil
    hunk = nil
    pending_old, pending_new = 0, 0
  end

  local function ensure_file()
    if not file then
      file = new_file_entry()
    end
    return file
  end

  local lines = split_lines(diff_text)

  for _, line in ipairs(lines) do
    local in_hunk = hunk ~= nil and (pending_old > 0 or pending_new > 0)

    if in_hunk then
      local marker = line:sub(1, 1)
      local text = line:sub(2)

      if marker == "+" then
        new_line = new_line + 1
        pending_new = pending_new - 1
        hunk.lines[#hunk.lines + 1] = { kind = "add", text = text, new_line = new_line }
        file.additions = file.additions + 1
      elseif marker == "-" then
        old_line = old_line + 1
        pending_old = pending_old - 1
        hunk.lines[#hunk.lines + 1] = { kind = "delete", text = text, old_line = old_line }
        file.deletions = file.deletions + 1
      elseif marker == "\\" then
        -- "\ No newline at end of file" — annotates the previous line, consumes no count.
        hunk.lines[#hunk.lines + 1] = { kind = "message", text = line:sub(3) }
      elseif marker == " " or line == "" then
        -- An empty line in a diff body is an unchanged empty line; some tools
        -- strip the single leading space.
        old_line = old_line + 1
        new_line = new_line + 1
        pending_old = pending_old - 1
        pending_new = pending_new - 1
        hunk.lines[#hunk.lines + 1] = { kind = "context", text = text, old_line = old_line, new_line = new_line }
      else
        -- Unexpected content: the hunk counts lied. Bail out of the hunk and
        -- reprocess this line as a header below.
        pending_old, pending_new = 0, 0
        hunk = nil
        in_hunk = false
      end
    end

    if not in_hunk then
      if line:match("^diff %-%-git ") then
        flush_file()
        file = new_file_entry()
        local old, new = line:match("^diff %-%-git (.+) (.+)$")
        if old and new then
          file.old_path = strip_prefix(old)
          file.path = strip_prefix(new)
        end
      elseif line:match("^new file mode") then
        ensure_file().status = "added"
      elseif line:match("^deleted file mode") then
        ensure_file().status = "deleted"
      elseif line:match("^rename from ") then
        ensure_file().old_path = strip_prefix(line:sub(13))
        file.status = "renamed"
      elseif line:match("^rename to ") then
        ensure_file().path = strip_prefix(line:sub(11))
        file.status = "renamed"
      elseif line:match("^Binary files ") or line:match("^GIT binary patch") then
        ensure_file().status = "binary"
      elseif line:match("^%-%-%- ") then
        local path = header_path(line)
        ensure_file()
        if path ~= "/dev/null" then
          file.old_path = path
          file.path = file.path or path
        else
          file.status = "added"
        end
      elseif line:match("^%+%+%+ ") then
        local path = header_path(line)
        ensure_file()
        if path ~= "/dev/null" then
          file.path = path
        else
          file.status = "deleted"
          file.path = file.path or file.old_path
        end
      elseif line:match("^@@") then
        local old_start, old_count, new_start, new_count, context =
          line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@(.*)$")
        if old_start then
          ensure_file()
          old_start, new_start = tonumber(old_start), tonumber(new_start)
          -- An omitted count means 1 ("@@ -5 +5 @@").
          pending_old = old_count == "" and 1 or tonumber(old_count)
          pending_new = new_count == "" and 1 or tonumber(new_count)
          hunk = {
            header = line,
            context = context ~= "" and context:gsub("^%s+", "") or nil,
            old_start = old_start,
            new_start = new_start,
            lines = {},
          }
          -- A zero count means the hunk starts *after* the given line.
          old_line = pending_old == 0 and old_start or old_start - 1
          new_line = pending_new == 0 and new_start or new_start - 1
          file.hunks[#file.hunks + 1] = hunk
        end
      end
    end
  end

  flush_file()

  if #files == 0 and diff_text:gsub("%s", "") ~= "" then
    return files, "no files found in diff"
  end

  return files, nil
end

---Build a file entry that renders an entire file as unchanged context, so every
---line is addressable even when there is no diff to show.
---@param path string Path used to address comments
---@param content string File contents
---@return ClaudeCodeReviewFile
function M.whole_file(path, content)
  local lines = split_lines(content)
  local hunk = { header = nil, context = nil, old_start = 1, new_start = 1, lines = {} }
  for index, text in ipairs(lines) do
    hunk.lines[index] = { kind = "context", text = text, old_line = index, new_line = index }
  end
  return {
    path = path,
    old_path = path,
    status = "view",
    hunks = { hunk },
    additions = 0,
    deletions = 0,
  }
end

M._split_lines = split_lines
M._unquote = unquote

return M
