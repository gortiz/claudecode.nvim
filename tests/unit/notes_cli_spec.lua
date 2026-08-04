-- luacheck: globals expect
require("tests.busted_setup")

describe("notes CLI", function()
  local cli
  local notes
  local files = {}

  before_each(function()
    files = {}
    vim.fn = vim.fn or {}
    vim.fn.filereadable = function(path)
      return files[path] and 1 or 0
    end
    vim.fn.readfile = function(path)
      return vim.split(files[path] or "", "\n", { plain = true })
    end

    notes = {
      added = {},
      add = function(opts)
        if not opts.path or opts.path == "/bad" then
          return nil, "no such file: " .. tostring(opts.path)
        end
        local note = { id = #notes.added + 1, path = opts.path, line = opts.line, author = opts.author }
        table.insert(notes.added, { opts = opts, note = note })
        return note
      end,
      list = function(filter)
        notes.filter = filter
        return { { id = 1, author = "user", path = "/a.lua", line = 3, body = "hm" } }
      end,
      goto_location = function(path, line)
        if path == "/bad" then
          return false, "no such file: /bad"
        end
        notes.went = { path = path, line = line }
        return true
      end,
      remove = function(id)
        notes.removed = id
        return id == 1
      end,
      clear = function(opts)
        notes.cleared = opts
        return 2
      end,
    }

    package.loaded["claudecode.notes"] = notes
    package.loaded["claudecode.notes.cli"] = nil
    cli = require("claudecode.notes.cli")
  end)

  after_each(function()
    package.loaded["claudecode.notes"] = nil
    package.loaded["claudecode.notes.cli"] = nil
  end)

  local function run(request)
    return cli._dispatch(request)
  end

  describe("add", function()
    it("adds a batch and defaults to the agent", function()
      local response = run({
        action = "add",
        notes = { { path = "/a.lua", line = 3, body = "one" }, { path = "/b.lua", line = 9, body = "two" } },
      })

      assert.is_true(response.ok)
      assert.are.equal(2, #response.data.added)
      assert.are.equal("agent", notes.added[1].opts.author)
    end)

    it("accepts a single note without wrapping it in an array", function()
      local response = run({ action = "add", path = "/a.lua", line = 3, body = "solo" })

      assert.is_true(response.ok)
      assert.are.equal(1, #response.data.added)
    end)

    it("reports the ones that could not be placed", function()
      local response = run({
        action = "add",
        notes = { { path = "/a.lua", line = 1, body = "fine" }, { path = "/bad", line = 1, body = "nope" } },
      })

      assert.is_true(response.ok)
      assert.are.equal(1, #response.data.added)
      assert.are.equal(1, #response.data.rejected)
    end)

    it("fails when nothing could be placed", function()
      local response = run({ action = "add", notes = { { path = "/bad", line = 1, body = "nope" } } })

      assert.is_false(response.ok)
      assert.is_not_nil(response.error:find("no such file"))
    end)

    it("rejects an empty request", function()
      assert.is_false(run({ action = "add" }).ok)
      assert.is_false(run({ action = "add", notes = {} }).ok)
    end)
  end)

  describe("list", function()
    it("passes the filters through", function()
      local response = run({ action = "list", author = "user", since = 4, path = "/a.lua" })

      assert.is_true(response.ok)
      assert.are.equal(1, #response.data.notes)
      assert.are.equal("user", notes.filter.author)
      assert.are.equal(4, notes.filter.since)
      assert.are.equal("/a.lua", notes.filter.path)
    end)
  end)

  describe("goto, remove and clear", function()
    it("goes to a location", function()
      local response = run({ action = "goto", path = "/a.lua", line = 12 })

      assert.is_true(response.ok)
      assert.are.equal(12, notes.went.line)
    end)

    it("surfaces a goto failure", function()
      local response = run({ action = "goto", path = "/bad" })

      assert.is_false(response.ok)
    end)

    it("removes by id", function()
      local response = run({ action = "remove", id = 1 })

      assert.is_true(response.ok)
      assert.is_true(response.data.removed)
    end)

    it("needs an id to remove", function()
      assert.is_false(run({ action = "remove" }).ok)
    end)

    it("reports how many it cleared", function()
      local response = run({ action = "clear", path = "/a.lua" })

      assert.is_true(response.ok)
      assert.are.equal(2, response.data.removed)
      assert.are.equal("/a.lua", notes.cleared.path)
    end)
  end)

  it("rejects an unknown action", function()
    local response = run({ action = "explode" })

    assert.is_false(response.ok)
    assert.is_not_nil(response.error:find("unknown action"))
  end)
end)
