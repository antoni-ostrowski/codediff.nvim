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

  describe("parse_header", function()
    it("round-trips a worktree header", function()
      local h = review.parse_header("dotfiles@7775634:.config/nvim/init.lua:13-16 (+worktree): keep this")
      assert.same({
        repo = "dotfiles",
        base = "7775634",
        file = ".config/nvim/init.lua",
        start_line = 13,
        end_line = 16,
        worktree = true,
        body = "keep this",
      }, h)
    end)

    it("round-trips a frozen header", function()
      local h = review.parse_header("repo@a3f9c21:src/foo.lua:7: was load-bearing")
      assert.equals("repo", h.repo)
      assert.equals("a3f9c21", h.base)
      assert.equals("src/foo.lua", h.file)
      assert.equals(7, h.start_line)
      assert.equals(7, h.end_line)
      assert.is_false(h.worktree)
      assert.equals("was load-bearing", h.body)
    end)

    it("keeps colons inside the body", function()
      local h = review.parse_header("repo@abc:src/f.lua:1: fix: stuff")
      assert.equals("src/f.lua", h.file)
      assert.equals("fix: stuff", h.body)
    end)

    it("parses the bare file:lines form used outside a repo", function()
      local h = review.parse_header("/tmp/x.lua:1-2 (+worktree): note")
      assert.equals("", h.repo)
      assert.equals("/tmp/x.lua", h.file)
      assert.equals(1, h.start_line)
      assert.equals(2, h.end_line)
      assert.is_true(h.worktree)
    end)

    it("rejects non-headers", function()
      assert.is_nil(review.parse_header("  13 | x = 1"))
      assert.is_nil(review.parse_header("just some text"))
      assert.is_nil(review.parse_header(""))
      assert.is_nil(review.parse_header(nil))
    end)
  end)

  describe("parse_block", function()
    it("rebuilds a record, keeping hidden fields from the fallback", function()
      local c = review.parse_block(
        {
          "dotfiles@7775634:.config/nvim/init.lua:13-16 (+worktree): edited body",
          "  13 | x = 1",
          "  14 | y = 2",
        },
        {
          absolute = "/home/u/dotfiles/.config/nvim/init.lua",
          git_root = "/home/u/dotfiles",
          side = "new",
          side_revision = "WORKING",
          other_revision = "7775634abc1234",
        }
      )
      assert.equals(".config/nvim/init.lua", c.file)
      assert.equals("/home/u/dotfiles/.config/nvim/init.lua", c.absolute)
      assert.equals("/home/u/dotfiles", c.git_root)
      assert.equals("WORKING", c.side_revision)
      assert.equals("7775634abc1234", c.other_revision)
      assert.equals(13, c.start_line)
      assert.equals(16, c.end_line)
      assert.same({ "x = 1", "y = 2" }, c.snippet)
      assert.equals("edited body", c.body)
    end)

    it("returns nil when the header does not parse", function()
      assert.is_nil(review.parse_block({ "  13 | x = 1" }, {}))
      assert.is_nil(review.parse_block({}, {}))
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

  describe("write_back", function()
    local session_mod
    local fake_tp = 987654
    local buf = nil

    local function seed()
      return {
        {
          id = 1,
          file = "a.lua",
          absolute = "/repo/a.lua",
          git_root = "/repo",
          side = "new",
          side_revision = "WORKING",
          other_revision = "abc1234",
          start_line = 10,
          end_line = 11,
          snippet = { "one", "two" },
          body = "first",
        },
        {
          id = 2,
          file = "b.lua",
          absolute = "/repo/b.lua",
          git_root = "/repo",
          side = "old",
          side_revision = "abc1234",
          other_revision = "WORKING",
          start_line = 3,
          end_line = 3,
          snippet = {},
          body = "second",
        },
      }
    end

    before_each(function()
      session_mod = require("codediff.ui.lifecycle.session")
      session_mod.get_active_diffs()[fake_tp] = { review_comments = seed() }
      buf = vim.api.nvim_create_buf(false, true)
      review.render_list(buf, fake_tp)
    end)

    after_each(function()
      if buf and vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
      session_mod.get_active_diffs()[fake_tp] = nil
    end)

    it("renders the export text into the buffer", function()
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      assert.is_true(lines[1]:find("repo@abc1234:a.lua:10-11 (+worktree): first", 1, true) == 1)
    end)

    it("drops a deleted block and keeps hidden fields on survivors", function()
      -- Simulate realistic edits: retitle line 1 in place, then delete the
      -- second block's lines as a range (extmarks track real deletions).
      vim.api.nvim_buf_set_lines(buf, 0, 1, false, {
        "repo@abc1234:a.lua:10-11 (+worktree): first edited",
      })
      local total = vim.api.nvim_buf_line_count(buf)
      vim.api.nvim_buf_set_lines(buf, total - 1, total, false, {})
      local res = review.write_back(fake_tp, buf)
      assert.same({ saved = 1, removed = 1, ignored = 0 }, res)
      local comments = session_mod.get_active_diffs()[fake_tp].review_comments
      assert.equals(1, #comments)
      assert.equals("first edited", comments[1].body)
      assert.equals("/repo/a.lua", comments[1].absolute)
      assert.equals("WORKING", comments[1].side_revision)
      assert.equals("abc1234", comments[1].other_revision)
      assert.same({ "one", "two" }, comments[1].snippet)
    end)

    it("refuses to wipe memory when text is present but nothing parses", function()
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "oops, clumsy header edit" })
      local res = review.write_back(fake_tp, buf)
      assert.is_nil(res)
      assert.equals(2, #session_mod.get_active_diffs()[fake_tp].review_comments)
    end)

    it("clears memory when the buffer is wiped blank", function()
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
      local res = review.write_back(fake_tp, buf)
      assert.same({ saved = 0, removed = 2, ignored = 0 }, res)
      assert.same({}, session_mod.get_active_diffs()[fake_tp].review_comments)
    end)

    it("keeps hidden fields attached to their content across reorders", function()
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      -- Move the second block above the first (block2 is the last line).
      local head = {}
      for i = 1, #lines - 1 do
        table.insert(head, lines[i])
      end
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { lines[#lines], "", unpack(head) })
      local res = review.write_back(fake_tp, buf)
      assert.equals(2, res.saved)
      local comments = session_mod.get_active_diffs()[fake_tp].review_comments
      assert.equals("b.lua", comments[1].file)
      assert.equals("/repo/b.lua", comments[1].absolute)
      assert.equals("a.lua", comments[2].file)
      assert.equals("/repo/a.lua", comments[2].absolute)
    end)

    it("deletes the entry under the cursor", function()
      vim.api.nvim_set_current_buf(buf)
      vim.api.nvim_win_set_cursor(0, { 5, 0 })
      review.delete_at_cursor(buf, fake_tp)
      local comments = session_mod.get_active_diffs()[fake_tp].review_comments
      assert.equals(1, #comments)
      assert.equals("a.lua", comments[1].file)
    end)
  end)

  describe("keymap configurability", function()
    local config, resolve, saved

    before_each(function()
      config = require("codediff.config")
      resolve = require("codediff.keymap.resolve")
      saved = vim.deepcopy(config.options)
    end)

    after_each(function()
      config.options = saved
      resolve.forget_warnings()
    end)

    it("ships review defaults", function()
      local k = resolve.keymaps_for("view")
      assert.same({ "<leader>cc" }, k.add_comment)
      assert.same({ "<leader>ce" }, k.export_comments)
      assert.same({ "<leader>cd" }, k.clear_comments)
      assert.same({ "<leader>cl" }, k.list_comments)
    end)

    it("honours user-chosen review keys", function()
      require("codediff").setup({
        keymaps = {
          view = {
            add_comment = "<leader>xx",
            export_comments = "<leader>xe",
            clear_comments = "<leader>xd",
            list_comments = "<leader>xl",
          },
        },
      })
      local k = resolve.keymaps_for("view")
      assert.same({ "<leader>xx" }, k.add_comment)
      assert.same({ "<leader>xe" }, k.export_comments)
      assert.same({ "<leader>xd" }, k.clear_comments)
      assert.same({ "<leader>xl" }, k.list_comments)
    end)

    it("lets users disable review keys", function()
      require("codediff").setup({ keymaps = { view = { list_comments = false } } })
      assert.equals(false, resolve.keymaps_for("view").list_comments)
    end)
  end)

  describe("session-backed ops without a session", function()
    it("reads empty and exports nil", function()
      assert.same({}, review.get_comments(-1))
      assert.is_nil(review.export_comments(-1))
    end)
  end)
end)
