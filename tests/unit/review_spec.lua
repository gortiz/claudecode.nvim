-- luacheck: globals expect
require("tests.busted_setup")

describe("review session", function()
  local review
  local keymaps
  local cursor
  local input_response

  local SAMPLE_DIFF = table.concat({
    "diff --git a/src/app.lua b/src/app.lua",
    "--- a/src/app.lua",
    "+++ b/src/app.lua",
    "@@ -10,3 +10,4 @@ function M.run()",
    " local a = 1",
    "-local b = 2",
    "+local b = 3",
    "+local c = 4",
  }, "\n")

  ---Install the slice of the Neovim API the review UI touches.
  local function install_stubs()
    keymaps = {}
    cursor = { 1, 0 }
    input_response = nil

    local buffers = {}
    local namespace_counter = 0
    local buffer_counter = 0

    local api = vim.api
    api.nvim_create_namespace = function()
      namespace_counter = namespace_counter + 1
      return namespace_counter
    end
    api.nvim_create_buf = function()
      buffer_counter = buffer_counter + 1
      buffers[buffer_counter] = { lines = {}, valid = true }
      return buffer_counter
    end
    api.nvim_buf_set_lines = function(bufnr, _, _, _, lines)
      buffers[bufnr] = buffers[bufnr] or { lines = {}, valid = true }
      buffers[bufnr].lines = lines
    end
    api.nvim_buf_get_lines = function(bufnr)
      return (buffers[bufnr] or { lines = {} }).lines
    end
    api.nvim_buf_set_name = function() end
    api.nvim_buf_is_valid = function(bufnr)
      return buffers[bufnr] ~= nil and buffers[bufnr].valid
    end
    api.nvim_buf_delete = function(bufnr)
      if buffers[bufnr] then
        buffers[bufnr].valid = false
      end
    end
    api.nvim_buf_clear_namespace = function() end
    api.nvim_buf_set_extmark = function() end
    api.nvim_set_option_value = function() end
    api.nvim_set_hl = function() end
    api.nvim_win_set_buf = function() end
    api.nvim_win_is_valid = function()
      return true
    end
    api.nvim_win_get_width = function()
      return 100
    end
    api.nvim_win_get_cursor = function()
      return { cursor[1], cursor[2] }
    end
    api.nvim_win_set_cursor = function(_, position)
      cursor = { position[1], position[2] }
    end
    api.nvim_win_call = function(_, fn)
      fn()
    end
    api.nvim_get_current_win = function()
      return 1000
    end
    api.nvim_set_current_win = function() end
    api.nvim_create_autocmd = function()
      return 1
    end
    api.nvim_create_augroup = function()
      return 1
    end

    vim.keymap = vim.keymap or {}
    vim.keymap.set = function(_, lhs, rhs)
      keymaps[lhs] = rhs
    end
    vim.trim = function(text)
      return (tostring(text):gsub("^%s+", ""):gsub("%s+$", ""))
    end
    vim.ui = {
      input = function(_, callback)
        callback(input_response)
      end,
    }
    vim.cmd = function() end
    vim.notify = function() end
    vim.fn = vim.fn or {}
    vim.fn.has = function()
      return 1
    end
    vim.fn.getcwd = function()
      return "/tmp/repo"
    end
    vim.fn.filereadable = function()
      return 0
    end
  end

  ---Move the cursor to the buffer row whose text matches `needle`.
  local function cursor_to_line(needle)
    local lines = vim.api.nvim_buf_get_lines(review.session.bufnr, 0, -1, false)
    for index, text in ipairs(lines) do
      if text:find(needle, 1, true) then
        cursor = { index, 0 }
        return index
      end
    end
    error("no buffer line matching " .. needle)
  end

  before_each(function()
    install_stubs()
    package.loaded["claudecode.utils"] = {
      find_main_editor_window = function()
        return 1000
      end,
    }
    package.loaded["claudecode.review"] = nil
    review = require("claudecode.review")
  end)

  after_each(function()
    if review and review.session then
      review.close("test teardown")
    end
    package.loaded["claudecode.utils"] = nil
    package.loaded["claudecode.review"] = nil
  end)

  describe("open", function()
    it("summarises the diff it opened", function()
      local summary, err = review.open({ diff = SAMPLE_DIFF, title = "My review" })

      assert.is_nil(err)
      assert.are.equal("My review", summary.title)
      assert.are.equal(1, #summary.files)
      assert.are.equal("src/app.lua", summary.files[1].path)
      assert.are.equal(2, summary.files[1].additions)
      assert.are.equal(1, summary.files[1].deletions)
      assert.are.equal(1, #summary.files[1].hunks)
      assert.are.equal(10, summary.files[1].hunks[1].new_first_line)
      assert.are.equal(12, summary.files[1].hunks[1].new_last_line)
    end)

    it("renders the diff as buffer text with a file header", function()
      review.open({ diff = SAMPLE_DIFF })
      local lines = vim.api.nvim_buf_get_lines(review.session.bufnr, 0, -1, false)

      assert.are.equal("▸ src/app.lua  +2 −1", lines[1])
      assert.are.equal("@@ -10,3 +10,4 @@ function M.run()", lines[2])
      assert.are.equal(" local a = 1", lines[3])
      assert.are.equal("-local b = 2", lines[4])
      assert.are.equal("+local b = 3", lines[5])
    end)

    it("refuses to open nothing", function()
      local summary, err = review.open({ diff = "" })

      assert.is_nil(summary)
      assert.is_not_nil(err)
    end)

    it("replaces a previous session", function()
      review.open({ diff = SAMPLE_DIFF })
      local first = review.session.id
      review.open({ diff = SAMPLE_DIFF })

      assert.are_not.equal(first, review.session.id)
    end)
  end)

  describe("add_comments", function()
    before_each(function()
      review.open({ diff = SAMPLE_DIFF })
    end)

    it("anchors a comment on a line that is in the diff", function()
      local result = review.add_comments({
        { path = "src/app.lua", line = 11, body = "why 3?" },
      })

      assert.are.equal(1, #result.placed)
      assert.are.equal(0, #result.rejected)
      assert.is_true(result.placed[1].anchored)
      assert.are.equal(11, result.placed[1].line)
    end)

    it("snaps to the nearest line and reports the move", function()
      local result = review.add_comments({
        { path = "src/app.lua", line = 900, body = "far away" },
      })

      assert.are.equal(1, #result.placed)
      assert.is_false(result.placed[1].anchored)
      assert.are.equal(900, result.placed[1].requested_line)
      assert.are.equal(12, result.placed[1].line)
    end)

    it("comments on the old side of the diff", function()
      local result = review.add_comments({
        { path = "src/app.lua", line = 11, side = "old", body = "this was wrong" },
      })

      assert.is_true(result.placed[1].anchored)
      assert.are.equal("old", review.session.comments[1].side)
    end)

    it("rejects an unknown path", function()
      local result = review.add_comments({
        { path = "nope.lua", line = 1, body = "..." },
      })

      assert.are.equal(0, #result.placed)
      assert.are.equal(1, #result.rejected)
      assert.is_not_nil(result.rejected[1].reason:find("not in this review"))
    end)

    it("rejects a malformed comment but keeps the good ones", function()
      local result = review.add_comments({
        { path = "src/app.lua", body = "no line" },
        { path = "src/app.lua", line = 11, body = "fine" },
      })

      assert.are.equal(1, #result.placed)
      assert.are.equal(1, #result.rejected)
    end)

    it("errors without an active review", function()
      review.close("test")
      local result, err = review.add_comments({ { path = "a", line = 1, body = "b" } })

      assert.is_nil(result)
      assert.is_not_nil(err)
    end)
  end)

  describe("get_comments", function()
    before_each(function()
      review.open({ diff = SAMPLE_DIFF })
      review.add_comments({ { path = "src/app.lua", line = 11, body = "agent note" } })
      cursor_to_line("+local c = 4")
      input_response = "user note"
      keymaps["c"]()
    end)

    it("defaults to every author", function()
      assert.are.equal(2, #review.get_comments())
    end)

    it("filters by author", function()
      local user_comments = review.get_comments({ author = "user" })

      assert.are.equal(1, #user_comments)
      assert.are.equal("user note", user_comments[1].body)
      assert.are.equal("src/app.lua", user_comments[1].path)
      assert.are.equal(12, user_comments[1].line)
    end)

    it("filters by id so callers can poll", function()
      local all = review.get_comments()
      local newer = review.get_comments({ since = all[1].id })

      assert.are.equal(1, #newer)
      assert.are.equal(all[2].id, newer[1].id)
    end)
  end)

  describe("waiting", function()
    before_each(function()
      review.open({ diff = SAMPLE_DIFF })
    end)

    it("resolves a finish waiter when the user finishes", function()
      local payload
      local registered = review.wait({ mode = "finish", author = "user" }, function(result)
        payload = result
      end)

      assert.is_true(registered)
      assert.is_nil(payload)

      cursor_to_line("+local b = 3")
      input_response = "please explain"
      keymaps["c"]()
      assert.is_nil(payload, "a finish waiter must not fire on a comment")

      review.finish("test")

      assert.is_not_nil(payload)
      assert.are.equal("finished", payload.status)
      assert.are.equal(1, #payload.comments)
      assert.are.equal("please explain", payload.comments[1].body)
    end)

    it("resolves a comment waiter as soon as the user comments", function()
      local payload
      review.wait({ mode = "comment", author = "user" }, function(result)
        payload = result
      end)

      cursor_to_line("+local c = 4")
      input_response = "typo here"
      keymaps["c"]()

      assert.is_not_nil(payload)
      assert.are.equal("comment", payload.status)
      assert.are.equal("typo here", payload.comments[1].body)
    end)

    it("resolves with 'closed' when the review is discarded", function()
      local payload
      review.wait({ mode = "finish" }, function(result)
        payload = result
      end)

      review.close("discarded")

      assert.is_not_nil(payload)
      assert.are.equal("closed", payload.status)
    end)

    it("does not register a waiter without a session", function()
      review.close("test")
      local registered = review.wait({ mode = "finish" }, function() end)

      assert.is_false(registered)
    end)
  end)

  describe("send", function()
    before_each(function()
      review.open({ diff = SAMPLE_DIFF })
      cursor_to_line("+local b = 3")
      input_response = "have a look at this"
      keymaps["c"]()
    end)

    it("releases waiters without closing the review", function()
      local payload
      review.wait({ mode = "finish", author = "user" }, function(result)
        payload = result
      end)

      local sent = review.send("user wrote")

      assert.is_true(sent)
      assert.are.equal("sent", payload.status)
      assert.are.equal("have a look at this", payload.comments[1].body)
      -- The whole point: the pane survives so the conversation can continue.
      assert.is_not_nil(review.session)
    end)

    it("marks replies as sent so they stop counting as unsent", function()
      review.send("user wrote")

      local comments = review.get_comments({ author = "user" })
      assert.is_true(comments[1].sent)
    end)

    it("carries only the new reply on a second round", function()
      review.send("first round")
      local first = review.get_comments({ author = "user" })[1]

      local second
      review.wait({ mode = "finish", author = "user", since = first.id }, function(result)
        second = result
      end)
      assert.is_nil(second, "the second wait must block until the user writes again")

      input_response = "and another thing"
      keymaps["c"]()
      review.send("second round")

      assert.are.equal(1, #second.comments)
      assert.are.equal("and another thing", second.comments[1].body)
    end)

    it("is a no-op without a review", function()
      review.close("test")

      assert.is_false(review.send("nothing to send"))
    end)
  end)

  describe("results after the session is gone", function()
    before_each(function()
      review.open({ diff = SAMPLE_DIFF })
      cursor_to_line("+local b = 3")
      input_response = "one last thing"
      keymaps["c"]()
    end)

    it("hands a closed waiter the comments the session held", function()
      -- close() clears M.session before resolving; reading global state there used
      -- to report zero comments, which looks exactly like nobody replied.
      local payload
      review.wait({ mode = "finish", author = "user" }, function(result)
        payload = result
      end)

      review.close("discarded")

      assert.are.equal("closed", payload.status)
      assert.are.equal(1, #payload.comments)
      assert.are.equal("one last thing", payload.comments[1].body)
    end)

    it("still reports comments to a poller after finishing", function()
      review.finish("user pressed q")

      assert.is_nil(review.session)
      local comments = review.get_comments({ author = "user" })
      assert.are.equal(1, #comments)
      assert.are.equal("one last thing", comments[1].body)
      assert.are.equal("finished", review.last_result.status)
    end)

    it("records why a discarded review ended", function()
      review.close("discarded")

      assert.are.equal("closed", review.last_result.status)
      assert.are.equal("discarded", review.last_result.reason)
    end)

    it("clears the previous result when a new review opens", function()
      review.finish("done")
      assert.is_not_nil(review.last_result)

      review.open({ diff = SAMPLE_DIFF })

      assert.is_nil(review.last_result)
      assert.are.equal(0, #review.get_comments())
    end)
  end)

  describe("user comments", function()
    before_each(function()
      review.open({ diff = SAMPLE_DIFF })
    end)

    it("ignores an empty comment", function()
      cursor_to_line("+local b = 3")
      input_response = "   "
      keymaps["c"]()

      assert.are.equal(0, #review.get_comments())
    end)

    it("refuses to comment on a hunk header", function()
      cursor_to_line("@@ -10,3")
      input_response = "not a real line"
      keymaps["c"]()

      assert.are.equal(0, #review.get_comments())
    end)

    it("anchors a comment on a deleted line to the old side", function()
      cursor_to_line("-local b = 2")
      input_response = "why remove this?"
      keymaps["c"]()

      local comments = review.get_comments({ author = "user" })
      assert.are.equal(1, #comments)
      assert.are.equal("old", comments[1].side)
      assert.are.equal(11, comments[1].line)
    end)

    it("deletes the user's own comment but not the agent's", function()
      review.add_comments({ { path = "src/app.lua", line = 11, body = "agent note" } })
      cursor_to_line("+local b = 3")
      input_response = "user note"
      keymaps["c"]()
      assert.are.equal(2, #review.get_comments())

      keymaps["x"]()

      local remaining = review.get_comments()
      assert.are.equal(1, #remaining)
      assert.are.equal("agent", remaining[1].author)
    end)
  end)

  describe("navigate", function()
    before_each(function()
      review.open({ diff = SAMPLE_DIFF })
    end)

    it("moves the cursor to the requested line", function()
      local ok = review.navigate("src/app.lua", 12, "new")

      assert.is_true(ok)
      local lines = vim.api.nvim_buf_get_lines(review.session.bufnr, 0, -1, false)
      assert.are.equal("+local c = 4", lines[cursor[1]])
    end)

    it("falls back to the file header for a line outside the diff", function()
      local ok = review.navigate("src/app.lua", 999, "new")

      assert.is_true(ok)
      local lines = vim.api.nvim_buf_get_lines(review.session.bufnr, 0, -1, false)
      assert.are.equal("▸ src/app.lua  +2 −1", lines[cursor[1]])
    end)

    it("errors on an unknown path", function()
      local ok, err = review.navigate("nope.lua", 1)

      assert.is_false(ok)
      assert.is_not_nil(err)
    end)

    it("errors without an active review", function()
      review.close("test")
      local ok, err = review.navigate("src/app.lua", 10)

      assert.is_false(ok)
      assert.is_not_nil(err)
    end)
  end)
end)
