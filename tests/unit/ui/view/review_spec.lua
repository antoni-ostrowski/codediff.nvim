-- Tests for in-memory review comments (ui/view/actions/review.lua)
local helpers = require("tests.support")

describe("view.actions.review", function()
  local review

  before_each(function()
    helpers.ensure_plugin_loaded()
    review = require("codediff.ui.view.actions.review")
  end)

  describe("base_label", function()
    it("maps worktree to empty and spells out staged/conflict stages", function()
      assert.equals("", review.base_label(nil))
      assert.equals("", review.base_label("WORKING"))
      assert.equals("staged", review.base_label(":0"))
      assert.equals("base", review.base_label(":1"))
      assert.equals("ours", review.base_label(":2"))
      assert.equals("theirs", review.base_label(":3"))
    end)

    it("shortens hashes git-style and passes names through", function()
      assert.equals("a3f9c21", review.base_label("a3f9c21e5b4d78c0a1b2c3d4e5f60718293a4b5c6"))
      assert.equals("HEAD", review.base_label("HEAD"))
    end)
  end)

  describe("repo_name", function()
    it("uses the basename of the git root", function()
      assert.equals("dotfiles", review.repo_name("/home/u/dotfiles"))
    end)

    it("is empty outside a repo", function()
      assert.equals("", review.repo_name(nil))
      assert.equals("", review.repo_name(""))
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
    it("renders worktree comments as repo@base:path:lines (+worktree)", function()
      local text = review.format_comment({
        file = ".config/nvim/init.lua",
        absolute = "/home/u/dotfiles/.config/nvim/init.lua",
        git_root = "/home/u/dotfiles",
        side = "new",
        side_revision = "WORKING",
        other_revision = "7775634abc1234",
        start_line = 13,
        end_line = 16,
        snippet = { "x = 1" },
        body = "keep this",
      })
      local first = text:match("^[^\n]+")
      assert.equals("dotfiles@7775634:.config/nvim/init.lua:13-16 (+worktree): keep this", first)
      assert.is_true(text:find("13 | x = 1", 1, true) ~= nil)
    end)

    it("renders frozen-side comments as repo@base:path:lines with no marker", function()
      local text = review.format_comment({
        file = "src/foo.lua",
        absolute = "",
        git_root = "/repo",
        side = "old",
        side_revision = "a3f9c21e5b4",
        other_revision = nil,
        start_line = 7,
        end_line = 7,
        snippet = {},
        body = "was load-bearing",
      })
      assert.equals("repo@a3f9c21:src/foo.lua:7: was load-bearing", text)
    end)

    it("labels a staged-side comment with its stage", function()
      local text = review.format_comment({
        file = "src/foo.lua",
        absolute = "",
        git_root = "/repo",
        side = "new",
        side_revision = ":0",
        other_revision = "HEAD",
        start_line = 5,
        end_line = 6,
        snippet = {},
        body = "staged note",
      })
      assert.is_true(text:find("repo@staged:src/foo.lua:5-6: staged note", 1, true) == 1)
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
          other_revision = nil,
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

  describe("session-backed ops without a session", function()
    it("reads empty, exports nil, pops nil", function()
      assert.same({}, review.get_comments(-1))
      assert.is_nil(review.export_comments(-1))
      assert.is_nil(review.pop_comment(-1))
    end)
  end)
end)
