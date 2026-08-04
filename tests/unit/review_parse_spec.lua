-- luacheck: globals expect
require("tests.busted_setup")

describe("review.parse", function()
  local parse = require("claudecode.review.parse")

  describe("parse", function()
    it("parses a single-hunk modification with correct line numbers", function()
      local diff = table.concat({
        "diff --git a/lua/foo.lua b/lua/foo.lua",
        "index 1111111..2222222 100644",
        "--- a/lua/foo.lua",
        "+++ b/lua/foo.lua",
        "@@ -10,4 +10,5 @@ function M.run()",
        " local a = 1",
        "-local b = 2",
        "+local b = 3",
        "+local c = 4",
        " return a",
      }, "\n")

      local files, err = parse.parse(diff)

      assert.is_nil(err)
      assert.are.equal(1, #files)

      local file = files[1]
      assert.are.equal("lua/foo.lua", file.path)
      assert.are.equal("modified", file.status)
      assert.are.equal(2, file.additions)
      assert.are.equal(1, file.deletions)
      assert.are.equal(1, #file.hunks)

      local hunk = file.hunks[1]
      assert.are.equal("function M.run()", hunk.context)
      assert.are.equal(10, hunk.old_start)
      assert.are.equal(10, hunk.new_start)

      local lines = hunk.lines
      assert.are.equal(5, #lines)

      assert.are.equal("context", lines[1].kind)
      assert.are.equal(10, lines[1].old_line)
      assert.are.equal(10, lines[1].new_line)

      assert.are.equal("delete", lines[2].kind)
      assert.are.equal(11, lines[2].old_line)
      assert.is_nil(lines[2].new_line)

      assert.are.equal("add", lines[3].kind)
      assert.is_nil(lines[3].old_line)
      assert.are.equal(11, lines[3].new_line)

      assert.are.equal("add", lines[4].kind)
      assert.are.equal(12, lines[4].new_line)

      assert.are.equal("context", lines[5].kind)
      assert.are.equal(12, lines[5].old_line)
      assert.are.equal(13, lines[5].new_line)
    end)

    it("parses multiple files and hunks", function()
      local diff = table.concat({
        "diff --git a/a.txt b/a.txt",
        "--- a/a.txt",
        "+++ b/a.txt",
        "@@ -1,1 +1,1 @@",
        "-one",
        "+ONE",
        "@@ -10,1 +10,2 @@",
        " ten",
        "+eleven",
        "diff --git a/b.txt b/b.txt",
        "--- a/b.txt",
        "+++ b/b.txt",
        "@@ -1,1 +1,1 @@",
        "-x",
        "+y",
      }, "\n")

      local files = parse.parse(diff)

      assert.are.equal(2, #files)
      assert.are.equal("a.txt", files[1].path)
      assert.are.equal(2, #files[1].hunks)
      assert.are.equal(11, files[1].hunks[2].lines[2].new_line)
      assert.are.equal("b.txt", files[2].path)
      assert.are.equal(1, #files[2].hunks)
    end)

    it("recognises added and deleted files", function()
      local diff = table.concat({
        "diff --git a/new.txt b/new.txt",
        "new file mode 100644",
        "--- /dev/null",
        "+++ b/new.txt",
        "@@ -0,0 +1,2 @@",
        "+first",
        "+second",
        "diff --git a/gone.txt b/gone.txt",
        "deleted file mode 100644",
        "--- a/gone.txt",
        "+++ /dev/null",
        "@@ -1,1 +0,0 @@",
        "-bye",
      }, "\n")

      local files = parse.parse(diff)

      assert.are.equal(2, #files)
      assert.are.equal("added", files[1].status)
      assert.are.equal("new.txt", files[1].path)
      assert.are.equal(1, files[1].hunks[1].lines[1].new_line)
      assert.are.equal(2, files[1].hunks[1].lines[2].new_line)

      assert.are.equal("deleted", files[2].status)
      assert.are.equal("gone.txt", files[2].path)
      assert.are.equal(1, files[2].hunks[1].lines[1].old_line)
    end)

    it("handles omitted hunk counts", function()
      local diff = table.concat({
        "--- a/x.txt",
        "+++ b/x.txt",
        "@@ -5 +5 @@",
        "-old",
        "+new",
      }, "\n")

      local files = parse.parse(diff)

      assert.are.equal(1, #files)
      assert.are.equal(5, files[1].hunks[1].lines[1].old_line)
      assert.are.equal(5, files[1].hunks[1].lines[2].new_line)
    end)

    it("treats the no-newline marker as an annotation, not a content line", function()
      local diff = table.concat({
        "--- a/x.txt",
        "+++ b/x.txt",
        "@@ -1,1 +1,1 @@",
        "-old",
        "\\ No newline at end of file",
        "+new",
      }, "\n")

      local files = parse.parse(diff)
      local lines = files[1].hunks[1].lines

      assert.are.equal(3, #lines)
      assert.are.equal("message", lines[2].kind)
      assert.are.equal("add", lines[3].kind)
      assert.are.equal(1, lines[3].new_line)
    end)

    it("does not mistake diff-looking content inside a hunk for headers", function()
      local diff = table.concat({
        "--- a/x.md",
        "+++ b/x.md",
        "@@ -1,3 +1,3 @@",
        " intro",
        "--- a/not-a-header",
        "+++ b/not-a-header",
      }, "\n")

      local files = parse.parse(diff)

      assert.are.equal(1, #files)
      assert.are.equal("x.md", files[1].path)
      local lines = files[1].hunks[1].lines
      assert.are.equal(3, #lines)
      assert.are.equal("delete", lines[2].kind)
      assert.are.equal("-- a/not-a-header", lines[2].text)
      assert.are.equal("add", lines[3].kind)
    end)

    it("marks binary files", function()
      local diff = table.concat({
        "diff --git a/img.png b/img.png",
        "index 1111111..2222222 100644",
        "Binary files a/img.png and b/img.png differ",
      }, "\n")

      local files = parse.parse(diff)

      assert.are.equal(1, #files)
      assert.are.equal("binary", files[1].status)
      assert.are.equal(0, #files[1].hunks)
    end)

    it("records renames", function()
      local diff = table.concat({
        "diff --git a/old/name.lua b/new/name.lua",
        "similarity index 95%",
        "rename from old/name.lua",
        "rename to new/name.lua",
        "--- a/old/name.lua",
        "+++ b/new/name.lua",
        "@@ -1,1 +1,1 @@",
        "-a",
        "+b",
      }, "\n")

      local files = parse.parse(diff)

      assert.are.equal("new/name.lua", files[1].path)
      assert.are.equal("old/name.lua", files[1].old_path)
      assert.are.equal("renamed", files[1].status)
    end)

    it("returns an error for text that is not a diff", function()
      local files, err = parse.parse("just some prose\nwith no diff in it")

      assert.are.equal(0, #files)
      assert.is_not_nil(err)
    end)

    it("returns no error for empty input", function()
      local files, err = parse.parse("")

      assert.are.equal(0, #files)
      assert.is_nil(err)
    end)

    it("rejects non-string input", function()
      local files, err = parse.parse(nil)

      assert.are.equal(0, #files)
      assert.is_not_nil(err)
    end)
  end)

  describe("whole_file", function()
    it("renders every line as addressable context", function()
      local file = parse.whole_file("plan.md", "step one\nstep two\nstep three")

      assert.are.equal("plan.md", file.path)
      assert.are.equal("view", file.status)
      assert.are.equal(1, #file.hunks)

      local lines = file.hunks[1].lines
      assert.are.equal(3, #lines)
      for index, line in ipairs(lines) do
        assert.are.equal("context", line.kind)
        assert.are.equal(index, line.new_line)
        assert.are.equal(index, line.old_line)
      end
      assert.are.equal("step two", lines[2].text)
    end)
  end)

  describe("path handling", function()
    it("unquotes git-quoted paths", function()
      assert.are.equal("a b.txt", parse._unquote('"a b.txt"'))
      assert.are.equal("tab\there.txt", parse._unquote('"tab\\there.txt"'))
      assert.are.equal("plain.txt", parse._unquote("plain.txt"))
    end)

    it("strips the a/ and b/ prefixes", function()
      local diff = table.concat({
        "--- a/deep/nested/file.lua",
        "+++ b/deep/nested/file.lua",
        "@@ -1,1 +1,1 @@",
        "-a",
        "+b",
      }, "\n")

      local files = parse.parse(diff)
      assert.are.equal("deep/nested/file.lua", files[1].path)
    end)
  end)
end)
