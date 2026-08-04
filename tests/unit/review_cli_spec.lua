-- luacheck: globals expect
require("tests.busted_setup")

describe("review CLI", function()
  local cli
  local review

  local SAMPLE_DIFF = table.concat({
    "diff --git a/src/app.lua b/src/app.lua",
    "--- a/src/app.lua",
    "+++ b/src/app.lua",
    "@@ -10,2 +10,3 @@",
    " local a = 1",
    "+local b = 2",
  }, "\n")

  local files = {}

  before_each(function()
    files = {}

    -- The CLI only touches the filesystem through these two, so a table stands in
    -- for the disk and the tests stay hermetic.
    vim.fn = vim.fn or {}
    vim.fn.filereadable = function(path)
      return files[path] and 1 or 0
    end
    vim.fn.readfile = function(path)
      return vim.split(files[path] or "", "\n", { plain = true })
    end

    review = {
      session = nil,
      last_result = nil,
      open = function(opts)
        if not opts.diff and not opts.files then
          return nil, "nothing to review"
        end
        review.session = { id = "review-1" }
        review.opened_with = opts
        return { id = "review-1", finished = false, files = {} }
      end,
      add_comments = function(comments)
        if not review.session then
          return nil, "no active review"
        end
        review.added = comments
        return { placed = comments, rejected = {} }
      end,
      navigate = function(path, line)
        if not review.session then
          return false, "no active review"
        end
        review.navigated = { path = path, line = line }
        return true
      end,
      get_comments = function(filter)
        review.filter = filter
        return { { id = 1, author = "user", body = "hi" } }
      end,
      summary = function()
        return review.session and { id = "review-1", finished = false } or nil
      end,
      close = function(reason)
        review.session = nil
        review.closed_reason = reason
      end,
      finish = function(reason)
        review.finished_reason = reason
        review.session = nil
      end,
    }

    package.loaded["claudecode.review"] = review
    package.loaded["claudecode.review.cli"] = nil
    cli = require("claudecode.review.cli")
  end)

  after_each(function()
    package.loaded["claudecode.review"] = nil
    package.loaded["claudecode.review.cli"] = nil
  end)

  -- The vim mock's json.decode is a non-functional stub, so the action logic is
  -- exercised through _dispatch (tables in, tables out) and the JSON envelope is
  -- covered separately below with decode stubbed.
  local function run(request)
    return cli._dispatch(request)
  end

  describe("open", function()
    it("reads the diff from a file and opens a review", function()
      files["/tmp/x.diff"] = SAMPLE_DIFF
      local response = run({ action = "open", diff_file = "/tmp/x.diff", title = "T" })

      assert.is_true(response.ok)
      assert.are.equal("review-1", response.data.id)
      assert.are.equal(SAMPLE_DIFF, review.opened_with.diff)
      assert.are.equal("T", review.opened_with.title)
    end)

    it("reports a missing diff file instead of opening an empty review", function()
      local response = run({ action = "open", diff_file = "/tmp/missing.diff" })

      assert.is_false(response.ok)
      assert.is_not_nil(response.error:find("not readable"))
    end)

    it("passes a file list through", function()
      local response = run({ action = "open", files = { "a.lua", "b.lua" } })

      assert.is_true(response.ok)
      assert.are.same({ "a.lua", "b.lua" }, review.opened_with.files)
    end)
  end)

  describe("comment", function()
    it("forwards a batch", function()
      review.session = { id = "review-1" }
      local response = run({
        action = "comment",
        comments = { { path = "src/app.lua", line = 11, body = "why?" } },
      })

      assert.is_true(response.ok)
      assert.are.equal(1, #response.data.placed)
      assert.are.equal("why?", review.added[1].body)
    end)

    it("rejects an empty batch", function()
      local response = run({ action = "comment", comments = {} })

      assert.is_false(response.ok)
    end)

    it("surfaces the module's error when there is no review", function()
      local response = run({ action = "comment", comments = { { path = "a", line = 1, body = "b" } } })

      assert.is_false(response.ok)
      assert.is_not_nil(response.error:find("no active review"))
    end)
  end)

  describe("get", function()
    it("reports an open review as unfinished", function()
      review.session = { id = "review-1" }
      local response = run({ action = "get", author = "user", since = 0 })

      assert.is_true(response.ok)
      assert.is_false(response.data.finished)
      assert.are.equal("open", response.data.status)
      assert.are.equal(1, #response.data.comments)
      assert.are.equal("user", review.filter.author)
    end)

    it("reports finished once the session is gone, so a poller can stop", function()
      review.session = nil
      review.last_result = { status = "finished" }
      local response = run({ action = "get" })

      assert.is_true(response.data.finished)
      assert.are.equal("finished", response.data.status)
      -- Comments still come back after teardown; that is the whole point.
      assert.are.equal(1, #response.data.comments)
    end)
  end)

  describe("navigate, close and finish", function()
    it("navigates", function()
      review.session = { id = "review-1" }
      local response = run({ action = "navigate", path = "src/app.lua", line = 11 })

      assert.is_true(response.ok)
      assert.are.equal(11, review.navigated.line)
    end)

    it("closes", function()
      review.session = { id = "review-1" }
      local response = run({ action = "close", reason = "done" })

      assert.is_true(response.ok)
      assert.is_true(response.data.closed)
      assert.are.equal("done", review.closed_reason)
    end)

    it("closing nothing is not an error", function()
      local response = run({ action = "close" })

      assert.is_true(response.ok)
      assert.is_false(response.data.closed)
    end)

    it("finishes", function()
      review.session = { id = "review-1" }
      local response = run({ action = "finish", reason = "q" })

      assert.is_true(response.ok)
      assert.are.equal("q", review.finished_reason)
    end)
  end)

  describe("bad input", function()
    it("rejects an unknown action", function()
      local response = run({ action = "explode" })

      assert.is_false(response.ok)
      assert.is_not_nil(response.error:find("unknown action"))
    end)
  end)

  describe("the JSON envelope", function()
    local original_json
    local last_encoded

    before_each(function()
      original_json = vim.json
      vim.json = {
        decode = function(raw)
          if raw == "not json" then
            error("parse error")
          end
          return { action = "close" }
        end,
        encode = function(value)
          last_encoded = value
          return "ENCODED"
        end,
      }
    end)

    after_each(function()
      vim.json = original_json
    end)

    it("reports an unreadable request file", function()
      cli.run("/tmp/nope.json")

      assert.is_false(last_encoded.ok)
      assert.is_not_nil(last_encoded.error:find("not readable"))
    end)

    it("reports a request that is not JSON", function()
      files["/tmp/bad.json"] = "not json"
      cli.run("/tmp/bad.json")

      assert.is_false(last_encoded.ok)
      assert.is_not_nil(last_encoded.error:find("valid JSON"))
    end)

    it("returns the encoded response", function()
      files["/tmp/ok.json"] = "{}"

      assert.are.equal("ENCODED", cli.run("/tmp/ok.json"))
      assert.is_true(last_encoded.ok)
    end)

    it("returns a thrown error as data rather than letting it reach the editor", function()
      review.session = { id = "review-1" }
      review.close = function()
        error("boom")
      end
      files["/tmp/ok.json"] = "{}"

      cli.run("/tmp/ok.json")

      assert.is_false(last_encoded.ok)
      assert.is_not_nil(last_encoded.error:find("boom"))
    end)
  end)
end)
