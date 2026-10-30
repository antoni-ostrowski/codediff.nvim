-- Tests for in-memory review comments (ui/view/actions/review.lua)
local helpers = require("tests.support")

describe("view.actions.review", function()
  local review

  before_each(function()
    helpers.ensure_plugin_loaded()
    review = require("codediff.ui.view.actions.review")
  end)

  describe("rev_label", function()
    it("spells out symbolic revisions and passes hashes through", function()
      assert.equals("WORKING", review.rev_label(nil))
      assert.equals("WORKING", review.rev_label("WORKING"))
      assert.equals(":0-staged", review.rev_label(":0"))
      assert.equals(":1-base", review.rev_label(":1"))
      assert.equals(":2-ours", review.rev_label(":2"))
      assert.equals(":3-theirs", review.rev_label(":3"))
      assert.equals("a3f9c21", review.rev_label("a3f9c21"))
      assert.equals("HEAD", review.rev_label("HEAD"))
    end)
  end)

  describe("location", function()
    it("uses file:start for a single line (compiler convention)", function()
      local loc = review.location({ file = "src/foo.lua", absolute = "", start_line = 42, end_line = 42 })
      assert.equals("src/foo.lua:42", loc)
    end)

    it("uses file:start-end for a range", function()
      local loc = review.location({ file = "src/foo.lua", absolute = "", start_line = 42, end_line = 47 })
      assert.equals("src/foo.lua:42-47", loc)
    end)

    it("falls back to the absolute path when relative is empty", function()
      local loc =
        review.location({ file = "", absolute = "/tmp/x.lua", start_line = 1, end_line = 2 })
      assert.equals("/tmp/x.lua:1-2", loc)
    end)
  end)

  describe("format_comment", function()
    it("starts with the compiler location and carries revision context", function()
      local text = review.format_comment({
        file = "src/api/foo.lua",
        absolute = "/repo/src/api/foo.lua",
        git_root = "/repo",
        side = "new",
        side_revision = "WORKING",
        other_revision = "a3f9c21",
        start_line = 42,
        end_line = 43,
        snippet = { "foo()", "bar()" },
        body = "why removed?",
      })
      local first = text:match("^[^\n]+")
      assert.is_true(first:find("src/api/foo.lua:42-43", 1, true) == 1)
      assert.is_true(first:find("side=new", 1, true) ~= nil)
      assert.is_true(first:find("rev=WORKING", 1, true) ~= nil)
      assert.is_true(first:find("why removed?", 1, true) ~= nil)
      -- Snippet lines are quoted with their line numbers.
      assert.is_true(text:find("42 | foo()", 1, true) ~= nil)
      assert.is_true(text:find("43 | bar()", 1, true) ~= nil)
    end)

    it("labels the old side with its own revision", function()
      local text = review.format_comment({
        file = "src/foo.lua",
        absolute = "",
        git_root = "/repo",
        side = "old",
        side_revision = "HEAD",
        other_revision = nil,
        start_line = 7,
        end_line = 7,
        snippet = {},
        body = "was load-bearing",
      })
      assert.is_true(text:find("src/foo.lua:7", 1, true) == 1)
      assert.is_true(text:find("side=old", 1, true) ~= nil)
      assert.is_true(text:find("rev=HEAD", 1, true) ~= nil)
    end)
  end)

  describe("format_all", function()
    it("joins blocks with a blank line", function()
      local function comment(body)
        return {
          file = "a.lua",
          absolute = "",
          git_root = "",
          side = "new",
          side_revision = nil,
          other_revision = "HEAD",
          start_line = 1,
          end_line = 1,
          snippet = {},
          body = body,
        }
      end
      local text = review.format_all({ comment("one"), comment("two") })
      assert.is_true(text:find("one", 1, true) ~= nil)
      assert.is_true(text:find("two", 1, true) ~= nil)
      assert.is_true(text:find("\n\n", 1, true) ~= nil)
    end)

    it("returns an empty string for no comments", function()
      assert.equals("", review.format_all({}))
    end)
  end)
end)
