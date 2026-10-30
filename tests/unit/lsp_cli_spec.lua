-- luacheck: globals expect
require("tests.busted_setup")

describe("lsp CLI", function()
  local cli
  local saved = {}
  local lines

  before_each(function()
    lines = { "local helper_value = 1", "return helper_value + value(helper)" }
    saved.line_count = vim.api.nvim_buf_line_count
    saved.get_lines = vim.api.nvim_buf_get_lines
    vim.api.nvim_buf_line_count = function()
      return #lines
    end
    vim.api.nvim_buf_get_lines = function(_, start, end_line)
      return { unpack(lines, start + 1, end_line) }
    end
    package.loaded["claudecode.lsp.cli"] = nil
    cli = require("claudecode.lsp.cli")
  end)

  after_each(function()
    vim.api.nvim_buf_line_count = saved.line_count
    vim.api.nvim_buf_get_lines = saved.get_lines
    package.loaded["claudecode.lsp.cli"] = nil
  end)

  describe("dispatch", function()
    it("rejects an unknown action", function()
      local response = cli._dispatch({ action = "exec", path = "/a.lua" })

      assert.is_false(response.ok)
      assert.is_not_nil(response.error:find("unknown action"))
    end)

    it("refuses to stop everything without an explicit all", function()
      local response = cli._dispatch({ action = "stop" })

      assert.is_false(response.ok)
      assert.is_not_nil(response.error:find("all"))
    end)
  end)

  describe("resolve_column", function()
    it("takes an explicit column as is", function()
      assert.are.equal(7, cli._resolve_column(1, { line = 1, column = 7 }))
    end)

    it("finds the first whole-word match of a symbol", function()
      -- "helper" appears inside "helper_value" first; only the standalone one counts.
      assert.are.equal(29, cli._resolve_column(1, { line = 2, symbol = "helper" }))
      assert.are.equal(7, cli._resolve_column(1, { line = 1, symbol = "helper_value" }))
    end)

    it("reports a symbol that is not on the line", function()
      local column, err = cli._resolve_column(1, { line = 1, symbol = "nope" })

      assert.is_nil(column)
      assert.is_not_nil(err:find("not found on line 1"))
    end)

    it("rejects a line out of range", function()
      local column, err = cli._resolve_column(1, { line = 9, symbol = "x" })

      assert.is_nil(column)
      assert.is_not_nil(err:find("out of range"))
    end)

    it("needs a column or a symbol", function()
      local column = cli._resolve_column(1, { line = 1 })

      assert.is_nil(column)
    end)
  end)
end)
