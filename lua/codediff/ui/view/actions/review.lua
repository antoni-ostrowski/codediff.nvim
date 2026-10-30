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

--- Short label for the frozen revision a comment is pinned to. Worktree (nil
--- or "WORKING") maps to "" -- callers render that as a (+worktree) marker
--- against the base instead. Hashes shorten to 7 chars, git-style.
--- @param rev string|nil
--- @return string
function M.base_label(rev)
  if rev == nil or rev == "WORKING" then
    return ""
  elseif rev == ":0" then
    return "staged"
  elseif rev == ":1" then
    return "base"
  elseif rev == ":2" then
    return "ours"
  elseif rev == ":3" then
    return "theirs"
  elseif type(rev) == "string" and rev:match("^%x+$") and #rev > 7 then
    return rev:sub(1, 7)
  end
  return rev
end

--- Repo display name: basename of the git root, "" when not in a repo.
--- @param git_root string
--- @return string
function M.repo_name(git_root)
  if git_root == nil or git_root == "" then
    return ""
  end
  return vim.fn.fnamemodify(git_root, ":t")
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

--- Render one comment as text: `repo@base:path:lines (+worktree): body`.
--- The base always pins a frozen revision (full context for `git show
--- <base> -- <path>`); a (+worktree) marker means the lines were read from
--- the dirty worktree on top of that base. Frozen-side comments carry no
--- marker -- `repo@base:path:lines` alone is exact. Snippet lines follow,
--- quoted with their line numbers.
--- @param comment table
--- @return string
function M.format_comment(comment)
  local loc = M.location(comment)
  local repo = M.repo_name(comment.git_root)
  local is_worktree = comment.side_revision == nil or comment.side_revision == "WORKING"
  local head
  if is_worktree then
    local base = M.base_label(comment.other_revision)
    if repo ~= "" and base ~= "" then
      head = string.format("%s@%s:%s (+worktree): %s", repo, base, loc, comment.body)
    elseif repo ~= "" then
      head = string.format("%s:%s (+worktree): %s", repo, loc, comment.body)
    else
      head = string.format("%s (+worktree): %s", loc, comment.body)
    end
  else
    local base = M.base_label(comment.side_revision)
    if repo ~= "" then
      head = string.format("%s@%s:%s: %s", repo, base, loc, comment.body)
    else
      head = string.format("%s@%s: %s", loc, base, comment.body)
    end
  end
  if not comment.snippet or #comment.snippet == 0 then
    return head
  end
  local parts = { head }
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

--- Parse an export header line back into fields.
--- Accepts `repo@base:file:lines (+worktree): body` and the bare
--- `file:lines (+worktree): body` form used outside a repo.
--- NOTE: Lua patterns cannot quantify a group, so the marked/unmarked
--- shapes are separate patterns rather than one with an optional group.
--- @param line string
--- @return table|nil { repo, base, file, start_line, end_line, worktree, body }
function M.parse_header(line)
  if type(line) ~= "string" then
    return nil
  end
  local REPO_MARKED = "^(.-)@([^:]-):(.-):(%d+)(%-?%d*)%s*%(%+[^)]*%)%s*:%s*(.*)$"
  local REPO_PLAIN = "^(.-)@([^:]-):(.-):(%d+)(%-?%d*)%s*:%s*(.*)$"
  local BARE_MARKED = "^(.-):(%d+)(%-?%d*)%s*%(%+[^)]*%)%s*:%s*(.*)$"
  local BARE_PLAIN = "^(.-):(%d+)(%-?%d*)%s*:%s*(.*)$"
  local function finish(repo, base, file, s, e, worktree, body)
    -- The leading dash of `e` is a range separator (`13-16`), not a sign.
    if type(e) == "string" then
      e = e:gsub("^-", "")
    end
    s, e = tonumber(s), tonumber(e)
    e = e or s
    if not s or file == "" then
      return nil
    end
    return {
      repo = repo or "",
      base = base or "",
      file = file,
      start_line = math.min(s, e),
      end_line = math.max(s, e),
      worktree = worktree,
      body = body or "",
    }
  end
  -- Repo form first, marked before plain, so a `@` inside a bare path
  -- cannot misparse (the repo attempt fails, the bare one wins).
  local repo, base, file, s, e, body = line:match(REPO_MARKED)
  if repo then
    return finish(repo, base, file, s, e, true, body)
  end
  repo, base, file, s, e, body = line:match(REPO_PLAIN)
  if repo then
    return finish(repo, base, file, s, e, false, body)
  end
  file, s, e, body = line:match(BARE_MARKED)
  if file then
    return finish("", "", file, s, e, true, body)
  end
  file, s, e, body = line:match(BARE_PLAIN)
  if file then
    return finish("", "", file, s, e, false, body)
  end
  return nil
end

--- Parse one list-view block (header + quoted snippet lines) back into a
--- comment record. Hidden fields (absolute path, git root, exact revisions)
--- are carried over from `fallback`, so free-text edits to the visible block
--- never lose the data the agent needs.
--- @param block string[] block lines, header first
--- @param fallback table|nil original comment record
--- @return table|nil comment record, nil when the header does not parse
function M.parse_block(block, fallback)
  fallback = fallback or {}
  local first = nil
  for _, l in ipairs(block) do
    if not l:match("^%s*$") then
      first = l
      break
    end
  end
  local h = first and M.parse_header(first) or nil
  if not h then
    return nil
  end
  local snippet, extra = {}, {}
  local seen_header = false
  for _, l in ipairs(block) do
    if not seen_header then
      if l == first then
        seen_header = true
      end
    elseif l:match("^%s*$") then
      -- skip blank padding inside the block
    else
      local code = l:match("^%s*%d+%s*|%s?(.*)$")
      if code ~= nil then
        table.insert(snippet, code)
      else
        table.insert(extra, l)
      end
    end
  end
  local body = h.body
  if #extra > 0 then
    body = body .. "\n" .. table.concat(extra, "\n")
  end
  return {
    file = h.file,
    absolute = fallback.absolute or "",
    git_root = fallback.git_root or "",
    side = fallback.side or (h.worktree and "new" or "old"),
    side_revision = fallback.side_revision,
    other_revision = fallback.other_revision,
    start_line = h.start_line,
    end_line = h.end_line,
    snippet = snippet,
    body = body,
  }
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

-- ---------------------------------------------------------------------------
-- Editable list view: one float showing every saved comment.
-- `dd` on a block deletes that entry immediately; `:w` parses the buffer
-- text back into memory (so free-text deletions and body edits stick);
-- `q` closes without saving.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Editable list view: one float showing every saved comment, blocks split
-- on blank lines. `dd` on a block deletes that entry; `:w` matches the
-- buffer's blocks back to memory by (file, lines) so free-text deletions,
-- body edits and even reorders stick while hidden fields (absolute path,
-- exact revisions) survive; `q` closes without saving.
-- ---------------------------------------------------------------------------

local LIST_GROUP = "codediff-review-list"

--- Split buffer lines into non-blank blocks with 1-based row spans.
--- @param all string[]
--- @return table[] { lines, srow, erow }
function M.split_blocks(all)
  local blocks, cur = {}, nil
  for i, l in ipairs(all) do
    if l:match("^%s*$") then
      cur = nil
    else
      if not cur then
        cur = { lines = {}, srow = i }
        table.insert(blocks, cur)
      end
      table.insert(cur.lines, l)
      cur.erow = i
    end
  end
  return blocks
end

local function set_buf_lines(buf, lines)
  local ok = pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, lines)
  if not ok then
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  end
  vim.bo[buf].modified = false
end

--- Render the session's comments into an open list buffer.
--- @param buf number
--- @param tabpage number
function M.render_list(buf, tabpage)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local comments = M.get_comments(tabpage)
  local lines = {}
  for i, c in ipairs(comments) do
    if i > 1 then
      table.insert(lines, "")
    end
    for _, l in ipairs(vim.split(M.format_comment(c), "\n", { plain = true })) do
      table.insert(lines, l)
    end
  end
  if #lines == 0 then
    lines = { "" }
  end
  set_buf_lines(buf, lines)
end

--- Parse the list buffer back into the session, replacing its comments.
--- Blocks are matched to existing entries by (file, lines), so hidden
--- fields (absolute path, exact revisions) survive body edits and reorders;
--- unmatched blocks inherit leftovers positionally. Blocks whose header no
--- longer parses are ignored -- this is how free-text deletions stick.
--- Refuses to wipe a non-empty memory when the buffer holds text but zero
--- parseable blocks -- that smells like a typo, not an intentional clear.
--- @param tabpage number
--- @param buf number
--- @param opts? table { quiet = true } skips the saved notify (for dd)
--- @return table|nil { saved, removed, ignored }
function M.write_back(tabpage, buf, opts)
  local session = lifecycle.get_session(tabpage)
  if not session then
    vim.notify("[codediff] Diff session is gone; nothing saved", vim.log.levels.WARN)
    return nil
  end
  local originals = session.review_comments or {}
  local all = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local blocks = M.split_blocks(all)
  local used = {}
  local fresh, pending, ignored = {}, {}, 0
  for _, b in ipairs(blocks) do
    local h = M.parse_header(b.lines[1])
    if not h then
      ignored = ignored + 1
    else
      local match = nil
      for i, o in ipairs(originals) do
        if not used[i] and o.file == h.file and o.start_line == h.start_line and o.end_line == h.end_line then
          match = o
          used[i] = true
          break
        end
      end
      if match then
        table.insert(fresh, M.parse_block(b.lines, match))
      else
        table.insert(pending, b)
      end
    end
  end
  for _, b in ipairs(pending) do
    local fallback = {}
    for i, o in ipairs(originals) do
      if not used[i] then
        fallback = o
        used[i] = true
        break
      end
    end
    table.insert(fresh, M.parse_block(b.lines, fallback))
  end
  if #fresh == 0 and #originals > 0 then
    local has_text = false
    for _, l in ipairs(all) do
      if not l:match("^%s*$") then
        has_text = true
        break
      end
    end
    if has_text then
      vim.notify("[codediff] No parseable comment blocks; nothing saved", vim.log.levels.WARN)
      return nil
    end
  end
  for i, c in ipairs(fresh) do
    c.id = i
  end
  session.review_comments = fresh
  local removed = #originals - #fresh
  if removed < 0 then
    removed = 0
  end
  M.render_list(buf, tabpage)
  if not (opts and opts.quiet) then
    if removed > 0 or ignored > 0 then
      vim.notify(
        string.format("Saved %d review comment(s), %d removed%s", #fresh, removed, ignored > 0 and (", " .. ignored .. " ignored") or ""),
        vim.log.levels.INFO
      )
    else
      vim.notify(string.format("Saved %d review comment(s)", #fresh), vim.log.levels.INFO)
    end
  end
  return { saved = #fresh, removed = removed, ignored = ignored }
end

--- Delete the entry whose block holds the cursor.
--- @param buf number
--- @param tabpage number
function M.delete_at_cursor(buf, tabpage)
  local session = lifecycle.get_session(tabpage)
  if not session or not session.review_comments or #session.review_comments == 0 then
    vim.notify("[codediff] No comment under cursor", vim.log.levels.INFO)
    return
  end
  -- Sync first so buffer order == memory order (covers unsaved reorders).
  if not M.write_back(tabpage, buf, { quiet = true }) then
    return
  end
  session = lifecycle.get_session(tabpage)
  if not session then
    return
  end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local all = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local idx = nil
  for i, b in ipairs(M.split_blocks(all)) do
    if row >= b.srow and row <= b.erow then
      idx = i
      break
    end
  end
  if not idx or not session.review_comments[idx] then
    vim.notify("[codediff] No comment under cursor", vim.log.levels.INFO)
    return
  end
  local removed = table.remove(session.review_comments, idx)
  for i, c in ipairs(session.review_comments) do
    c.id = i
  end
  M.render_list(buf, tabpage)
  vim.notify(string.format("Removed comment (%s)", M.location(removed)), vim.log.levels.INFO)
end

--- Open the editable list float for a session.
--- @param tabpage number
function M.open_list(tabpage)
  local session = lifecycle.get_session(tabpage)
  if not session then
    vim.notify("[codediff] No active diff session", vim.log.levels.WARN)
    return
  end
  local buf = vim.api.nvim_create_buf(false, true)
  -- acwrite, not nofile: Neovim only routes :w to BufWriteCmd for buffers
  -- it considers writable, and nofile ones fail with E382 instead.
  vim.bo[buf].buftype = "acwrite"
  -- A name is required too: unnamed acwrite buffers fail :w with E32.
  M._list_seq = (M._list_seq or 0) + 1
  pcall(vim.api.nvim_buf_set_name, buf, string.format("codediff-review://%d", M._list_seq))
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "codediff-review"
  vim.bo[buf].modifiable = true
  M.render_list(buf, tabpage)

  local all = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local width = 0
  for _, l in ipairs(all) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  width = math.min(math.max(width + 4, 60), vim.o.columns - 4)
  local height = math.min(math.max(#all + 2, 8), vim.o.lines - 6)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " Review comments ",
    title_pos = "center",
  })
  vim.wo[win].wrap = false

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  vim.keymap.set("n", "q", close, { buffer = buf, nowait = true, desc = "Close review list" })
  vim.keymap.set("n", "<Esc>", close, { buffer = buf, nowait = true, desc = "Close review list" })
  vim.keymap.set("n", "dd", function()
    M.delete_at_cursor(buf, tabpage)
  end, { buffer = buf, nowait = true, desc = "Delete review comment under cursor" })

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = vim.api.nvim_create_augroup(LIST_GROUP, { clear = false }),
    buffer = buf,
    callback = function()
      M.write_back(tabpage, buf)
    end,
    desc = "Save review-list edits back to memory",
  })

  vim.notify("dd deletes entry under cursor, :w saves text edits, q closes", vim.log.levels.INFO)
end

--- Open the list for whichever session owns the current buffer (or tab).
function M.open_list_current()
  local cur = vim.api.nvim_get_current_buf()
  local tabpage = lifecycle.find_tabpage_by_buffer(cur) or vim.api.nvim_get_current_tabpage()
  if not lifecycle.get_session(tabpage) then
    vim.notify("[codediff] No active diff session here", vim.log.levels.WARN)
    return
  end
  M.open_list(tabpage)
end

return M
