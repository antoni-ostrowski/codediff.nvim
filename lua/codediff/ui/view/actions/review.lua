-- In-memory review comments for the diff view.
--
-- Lets the user select lines in either pane, type a note, and keep it in the
-- session. Export renders every comment as plain text starting with a
-- compiler-style `file:lines` location so editors can jump to it and an agent
-- can resolve the exact revision with `git show`.
--
-- Storage lives on the session table (`session.review_comments`), so it dies
-- with the tab and needs no separate lifecycle.

local M = {}

local lifecycle = require("codediff.ui.lifecycle")

--- Human label for a stored revision. Keeps the raw value for hashes so the
--- export stays resolvable, but spells out the symbolic ones.
--- @param rev string|nil
--- @return string
function M.rev_label(rev)
  if rev == nil or rev == "WORKING" then
    return "WORKING"
  elseif rev == ":0" then
    return ":0-staged"
  elseif rev == ":1" then
    return ":1-base"
  elseif rev == ":2" then
    return ":2-ours"
  elseif rev == ":3" then
    return ":3-theirs"
  end
  return rev
end

--- Compiler-style location prefix: `file:start-end` or `file:start`.
--- @param comment table
--- @return string
function M.location(comment)
  local file = comment.file ~= "" and comment.file or comment.absolute
  if comment.start_line == comment.end_line then
    return string.format("%s:%d", file, comment.start_line)
  end
  return string.format("%s:%d-%d", file, comment.start_line, comment.end_line)
end

--- Render one comment as text. First line carries the location plus enough
--- revision context to find the file again; following lines quote the code.
--- @param comment table
--- @return string
function M.format_comment(comment)
  local header = string.format(
    "%s [side=%s rev=%s other=%s%s]: %s",
    M.location(comment),
    comment.side,
    M.rev_label(comment.side_revision),
    M.rev_label(comment.other_revision),
    comment.git_root ~= "" and (" repo=" .. comment.git_root) or "",
    comment.body
  )
  if not comment.snippet or #comment.snippet == 0 then
    return header
  end
  local parts = { header }
  for i, line in ipairs(comment.snippet) do
    table.insert(parts, string.format("  %d | %s", comment.start_line + i - 1, line))
  end
  return table.concat(parts, "\n")
end

--- Render all comments, blocks separated by a blank line.
--- @param comments table[]
--- @return string
function M.format_all(comments)
  local blocks = {}
  for _, c in ipairs(comments) do
    table.insert(blocks, M.format_comment(c))
  end
  return table.concat(blocks, "\n\n")
end

--- Read-only access for export/tests.
--- @param tabpage number
--- @return table[]
function M.get_comments(tabpage)
  local session = lifecycle.get_session(tabpage)
  if not session then
    return {}
  end
  return session.review_comments or {}
end

--- Clear all comments for a session.
--- @param ctx_or_tab any CodeDiffActionContext or tabpage number
function M.clear_comments(ctx_or_tab)
  local tabpage = type(ctx_or_tab) == "number" and ctx_or_tab or ctx_or_tab.tabpage
  local session = lifecycle.get_session(tabpage)
  if not session then
    return
  end
  session.review_comments = {}
  vim.notify("Cleared review comments", vim.log.levels.INFO)
end

-- Resolve which side the cursor/selection is on.
-- Returns side ("old"/"new") plus whether it is the original pane,
-- or nil + error message when invoked outside the diff panes.
local function resolve_side(ctx, buf)
  if ctx.is_inline then
    -- Single visible pane always shows the new state.
    if buf ~= ctx.modified_bufnr and buf ~= ctx.original_bufnr then
      return nil, "Add comments from a diff pane"
    end
    return "new", false
  end
  if buf == ctx.original_bufnr then
    return "old", true
  elseif buf == ctx.modified_bufnr then
    return "new", false
  end
  return nil, "Add comments from a diff pane (not the explorer)"
end

--- Capture the current selection (or cursor line) and prompt for a note.
--- @param ctx CodeDiffActionContext
--- @param from_visual boolean true when invoked from visual mode
function M.add_comment(ctx, from_visual)
  local session = lifecycle.get_session(ctx.tabpage)
  if not session then
    vim.notify("[codediff] No active diff session", vim.log.levels.WARN)
    return
  end

  local buf = vim.api.nvim_get_current_buf()
  local side, is_original_or_err = resolve_side(ctx, buf)
  if not side then
    vim.notify("[codediff] " .. (is_original_or_err or "Add comments from a diff pane"), vim.log.levels.WARN)
    return
  end
  local is_original = is_original_or_err

  local start_line, end_line
  if from_visual then
    local a = vim.api.nvim_buf_get_mark(buf, "<")
    local b = vim.api.nvim_buf_get_mark(buf, ">")
    start_line, end_line = a[1], b[1]
    if start_line == 0 or end_line == 0 then
      start_line = vim.api.nvim_win_get_cursor(0)[1]
      end_line = start_line
    end
  else
    start_line = vim.api.nvim_win_get_cursor(0)[1]
    end_line = start_line
  end
  if start_line > end_line then
    start_line, end_line = end_line, start_line
  end
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local line_count = vim.api.nvim_buf_line_count(buf)
  start_line = math.max(1, math.min(start_line, line_count))
  end_line = math.max(1, math.min(end_line, line_count))

  local ref = is_original and session.original or session.modified
  local relative = (ref and ref.relative) or ""
  local absolute = (ref and ref.absolute) or ""
  if relative == "" then
    relative = (session.original.relative ~= "" and session.original.relative) or session.modified.relative or ""
  end
  if relative == "" and absolute == "" then
    vim.notify("[codediff] No file on this side (added/deleted file has only one pane)", vim.log.levels.WARN)
    return
  end

  local side_revision = is_original and session.original_revision or session.modified_revision
  local other_revision = is_original and session.modified_revision or session.original_revision
  local git_root = session.git_root or ""
  local snippet = {}
  local ok, lines = pcall(vim.api.nvim_buf_get_lines, buf, start_line - 1, end_line, false)
  if ok and lines then
    snippet = lines
  end

  -- Snapshot everything before vim.ui.input yields: the user may switch
  -- buffers while typing.
  local pending = {
    file = relative,
    absolute = absolute,
    git_root = git_root,
    side = side,
    side_revision = side_revision,
    other_revision = other_revision,
    start_line = start_line,
    end_line = end_line,
    snippet = snippet,
  }

  vim.ui.input({ prompt = "Comment: " }, function(input)
    if input == nil or input == "" then
      vim.notify("Comment cancelled", vim.log.levels.INFO)
      return
    end
    local live = lifecycle.get_session(ctx.tabpage)
    if not live then
      vim.notify("[codediff] Diff session closed before the comment was saved", vim.log.levels.WARN)
      return
    end
    live.review_comments = live.review_comments or {}
    pending.body = input
    pending.id = #live.review_comments + 1
    table.insert(live.review_comments, pending)
    vim.notify(
      string.format("Comment %d saved at %s", pending.id, M.location(pending)),
      vim.log.levels.INFO
    )
  end)
end

--- Format all comments and copy them to the clipboard (+/* registers).
--- @param ctx_or_tab any CodeDiffActionContext or tabpage number
--- @return string|nil exported text
function M.export_comments(ctx_or_tab)
  local tabpage = type(ctx_or_tab) == "number" and ctx_or_tab or ctx_or_tab.tabpage
  local comments = M.get_comments(tabpage)
  if #comments == 0 then
    vim.notify("[codediff] No review comments to export", vim.log.levels.INFO)
    return nil
  end
  local text = M.format_all(comments)
  pcall(vim.fn.setreg, "+", text)
  pcall(vim.fn.setreg, "*", text)
  pcall(vim.fn.setreg, '"', text)
  vim.notify(string.format("Copied %d review comment(s) to clipboard", #comments), vim.log.levels.INFO)
  return text
end

return M
