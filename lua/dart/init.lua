local Dart = {}
local M = {}

-- table of {filename = string, mark = string}
M.state = {}

Dart.setup = function(config)
  if M._setup then
    return
  end
  _G.Dart = Dart

  config = M.setup_config(config or {})
  M.apply_config(config)
  M.create_autocommands()
  M.create_default_hl()
  M.draw_tabline()

  if #M.config.buflist > 0 then
    local initial_bufs = {}
    -- get buffers
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      local filename = vim.api.nvim_buf_get_name(bufnr)
      if M.should_show(filename) and not M.state_from_filename(filename) then
        table.insert(initial_bufs, filename)
      end
    end
    -- add...
    for i = #initial_bufs, 1, -1 do
      M.shift_buflist(initial_bufs[i])
    end
  end

  M._setup = true
end

M.config = {
  -- List of characters to use to mark 'pinned' buffers
  -- The characters will be chosen for new pins in order
  marklist = { 'a', 's', 'd', 'f', 'q', 'w', 'e', 'r' },

  -- List of characters to use to mark recent buffers, which are displayed first (left) in the tabline
  -- Buffers that are 'marked' are not included in this list
  -- The length of this list determines how many recent buffers are tracked
  -- Set to {} to disable recent buffers in the tabline
  buflist = { 'z', 'x', 'c' },

  tabline = {
    -- Force the tabline to always be shown, even if no files are currently marked
    always_show = true,

    -- If true, Dart.next and Dart.prev will wrap around the tabline
    cycle_wraps_around = true,

    -- Override the default label foreground highlight
    -- You can also use the DartVisibleLabel/DartCurrentLabel/etc. highlights
    -- to override the label highlights entirely.
    label_fg = 'orange',

    -- Display icons in the tabline
    -- Supported icon providers are mini.icons and nvim-web-devicons
    icons = true,

    -- Function to determine the order mark/buflist items will be shown on the tabline
    -- Should return a table with keys being the mark and values being integers,
    -- e.g. { "a": 1, "b", 2 } would sort the "a" mark to the left of "b" on your tabline
    order = function(config)
      local order = {}
      for i, key in ipairs(vim.list_extend(vim.deepcopy(config.buflist), config.marklist)) do
        order[key] = i
      end
      return order
    end,

    -- Function to format a tabline item after the path is built
    format_item = function(item)
      local icon = item.icon ~= nil and string.format('%s  ', item.icon) or ''
      return string.format(
        '%%#%s#%s %s%%#%s#%s%%#%s#%s %%X',
        item.hl,
        item.click,
        icon,
        item.hl_label,
        item.label,
        item.hl,
        item.content
      )
    end,
  },

  picker = {
    -- argument to pass to vim.fn.fnamemodify `mods`, before displaying the file path in the picker
    -- e.g. ":t" for the filename, ":p:." for relative path to cwd
    path_format = ':t',
    -- border style for the picker window
    -- See `:h winborder` for options
    border = 'rounded',
  },

  -- State persistence. Use Dart.read_session and Dart.write_session manually
  persist = {
    -- Path to persist session data in
    path = vim.fs.joinpath(vim.fn.stdpath('data'), 'dart'),
  },

  -- Default mappings
  -- Set an individual mapping to an empty string to disable,
  mappings = {
    mark = ';;', -- Mark current buffer
    jump = ';', -- Jump to buffer marked by next character i.e `;a`
    pick = ';p', -- Open Dart.pick
    next = '<S-l>', -- Cycle right through the tabline
    prev = '<S-h>', -- Cycle left through the tabline
    unmark_all = ';u', -- Close all marked and recent buffers
  },
}

M.setup_config = function(config)
  M.config = vim.tbl_deep_extend('force', M.config, config or {})
  Dart.config = M.config
  return M.config
end

M.apply_config = function(config)
  if vim.fn.isdirectory(M.config.persist.path) == 0 then
    vim.fn.mkdir(M.config.persist.path, 'p')
  end

  -- setup keymaps
  local function map(mode, lhs, rhs, opts)
    if lhs == '' then
      return
    end
    opts = vim.tbl_deep_extend('force', { silent = true }, opts or {})
    vim.keymap.set(mode, lhs, rhs, opts)
  end

  vim.opt.tabline = '%!v:lua.Dart.gen_tabline()'

  M.get_icon = M.get_icon_provider()

  map('n', config.mappings.mark, Dart.mark, { desc = 'Dart: mark current buffer' })
  map('n', config.mappings.jump, function()
    Dart.jump(vim.fn.getcharstr())
  end, { desc = 'Dart: jump to buffer' })
  map('n', config.mappings.pick, Dart.pick, { desc = 'Dart: pick buffer' })
  map('n', config.mappings.next, Dart.next, { desc = 'Dart: next buffer' })
  map('n', config.mappings.prev, Dart.prev, { desc = 'Dart: prev buffer' })
  map('n', config.mappings.unmark_all, function()
    Dart.unmark { type = 'all' }
  end, { desc = 'Dart: unmark all buffers' })
end

M.draw_tabline = function()
  -- save and restore window view if tabline gets shown/hidden
  local tabline = vim.opt.showtabline

  if tabline ~= 2 and #M.state > 0 or M.config.tabline.always_show then
    -- save and restore window view if tabline gets shown/hidden
    local view = vim.fn.winsaveview()
    vim.opt.showtabline = 2
    vim.fn.winrestview(view)
  elseif tabline ~= 1 then
    local view = vim.fn.winsaveview()
    vim.opt.showtabline = 1 -- still display if tabpage exists
    vim.fn.winrestview(view)
  end
  vim.cmd.redrawtabline()
end

M.create_autocommands = function()
  local group = vim.api.nvim_create_augroup('Dart', {})

  -- cleanup deleted buffers
  vim.api.nvim_create_autocmd('BufDelete', {
    group = group,
    callback = function(args)
      M.del_by_filename(vim.api.nvim_buf_get_name(args.buf))
    end,
  })

  vim.api.nvim_create_autocmd('User', {
    group = group,
    pattern = 'DartChanged',
    callback = M.draw_tabline,
  })

  -- track last n opened buffers, unless the buffer list has been explicitly made empty by the user
  if #M.config.buflist > 0 then
    vim.api.nvim_create_autocmd({ 'BufWinEnter', 'BufAdd' }, {
      group = group,
      callback = function(args)
        M.shift_buflist(vim.api.nvim_buf_get_name(args.buf))
      end,
    })
  end

  -- Clickable tabs
  vim.api.nvim_exec2(
    [[function! SwitchBuffer(buf_id, clicks, button, mod)
        execute 'buffer' a:buf_id
      endfunction]],
    {}
  )
end

-- Use Mini Tabline for default highlights, since it's well supported by many colorschemes
-- Override the foreground for labels to be more visible
-- If mini is not present, fallback on TabLine highlight groups
M.create_default_hl = function()
  local set_default_hl = function(name, opts)
    opts.default = true
    vim.api.nvim_set_hl(0, name, opts)
  end

  local mk_fallback_hl = function(group, fallback)
    local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = group })
    if ok and (hl.fg or hl.bg or hl.link) then
      return group
    end
    return fallback
  end

  local override_label = function(hl, link)
    local prev = vim.api.nvim_get_hl(0, { name = link })
    vim.api.nvim_set_hl(0, hl, {
      bg = prev.bg or '',
      fg = M.config.tabline.label_fg,
      bold = true,
      default = true,
    })
  end

  local current = mk_fallback_hl('MiniTablineCurrent', 'TabLineSel')
  local current_modified = mk_fallback_hl('MiniTablineModifiedCurrent', 'StatusLine')
  local visible = mk_fallback_hl('MiniTablineVisible', 'TabLine')
  local visible_modified = mk_fallback_hl('MiniTablineModifiedVisible', 'StatusLine')
  local fill = mk_fallback_hl('MiniTablineFill', 'Normal')

  -- Current selection
  set_default_hl('DartCurrent', { link = current })
  override_label('DartCurrentLabel', current)

  -- Current selection if modified
  set_default_hl('DartCurrentModified', { link = current_modified })
  override_label('DartCurrentLabelModified', current_modified)

  -- Visible but not selected
  set_default_hl('DartVisible', { link = visible })
  override_label('DartVisibleLabel', visible)

  -- Visible and modified but not selected
  set_default_hl('DartVisibleModified', { link = visible_modified })
  override_label('DartVisibleLabelModified', visible_modified)

  -- Fill
  set_default_hl('DartFill', { link = fill })

  -- Pick
  override_label('DartPickLabel', 'Normal')
end

M.write_json = function(path, tbl)
  local ok, _ = pcall(function()
    local fd = assert(vim.uv.fs_open(path, 'w', 438)) -- 438 = 0666
    assert(vim.uv.fs_write(fd, vim.json.encode(tbl)))
    assert(vim.uv.fs_close(fd))
  end)
  return ok
end

M.read_json = function(path)
  local ok, content = pcall(function()
    local fd = assert(vim.uv.fs_open(path, 'r', 438)) -- 438 = 0666
    local stat = assert(vim.uv.fs_fstat(fd))
    local data = assert(vim.uv.fs_read(fd, stat.size, 0))
    assert(vim.uv.fs_close(fd))
    return data
  end)
  return ok and vim.json.decode(content) or nil
end

M.read_session = function(session)
  local filename = session .. '.json'
  local path = vim.fs.joinpath(M.config.persist.path, filename)
  local content = M.read_json(path)
  if content ~= nil and #content > 0 then
    M.state = content
    M.emit_change()
  end
end

M.write_session = function(session)
  local path = vim.fs.joinpath(M.config.persist.path, session .. '.json')
  M.write_json(path, M.state)
end

M.get_state_by_field = function(field, value)
  for _, m in ipairs(M.state) do
    if m[field] == value then
      return m
    end
  end
end

M.state_from_mark = function(mark)
  return M.get_state_by_field('mark', mark)
end

M.state_from_filename = function(mark)
  return M.get_state_by_field('filename', mark)
end

M.del_by_filename = function(filename)
  for i, m in ipairs(M.state) do
    if m.filename == filename then
      table.remove(M.state, i)
      return
    end
  end
end

M.get_bufnr = function(filename)
  if filename == nil then
    return -1
  end
  return vim.fn.bufnr(filename)
end

M.should_show = function(filename)
  local bufnr = M.get_bufnr(filename)
  return vim.api.nvim_buf_is_valid(bufnr) -- buffer exists and is loaded
    and vim.bo[bufnr].buflisted -- don't show hidden buffers
    and vim.bo[bufnr].buftype == '' -- don't show pickers, prompts, etc.
    and vim.api.nvim_buf_get_name(bufnr) ~= '' -- don't show unnamed files
end

M.next_unused_mark = function()
  for _, m in ipairs(M.config.marklist) do
    if not M.state_from_mark(m) then
      return m
    end
  end
  return '+'
end

M.shift_buflist = function(filename)
  local buflist = M.config.buflist

  if #buflist == 0 or M.state_from_filename(filename) or not M.should_show(filename) then
    return
  end

  -- get buflist state items and sort
  local items = {}
  for _, mark in ipairs(buflist) do
    local item = M.state_from_mark(mark)
    if item then
      table.insert(items, item)
    end
  end

  -- if buflist is empty, add first file
  local bufnr = M.get_bufnr(filename)
  if #items == 0 then
    return M.mark(bufnr, buflist[1])
  end

  -- if not empty, iterate from the end and shift right
  for i = #items, 1, -1 do
    local path = items[i].filename
    if not (i + 1 > #buflist) then
      M.state_from_filename(path).mark = buflist[i + 1]
    else
      M.del_by_filename(path)
    end
  end

  -- finally, update the leftmost item file
  M.mark(bufnr, buflist[1])
  M.emit_change()
end

-- param direction -1 for prev, 1 for next
M.cycle_tabline = function(direction)
  local cur = vim.api.nvim_get_current_buf()
  for i, m in ipairs(M.state) do
    if cur == M.get_bufnr(m.filename) then
      local next = ((i + direction - 1) % #M.state) + 1 -- wrap around list
      if not M.config.tabline.cycle_wraps_around and (i + direction < 1 or i + direction > #M.state) then
        return
      end
      if M.state[next] then
        vim.api.nvim_set_current_buf(M.get_bufnr(M.state[next].filename))
        return
      end
    end
  end
end

M.emit_change = function()
  vim.api.nvim_exec_autocmds('User', { pattern = 'DartChanged' })
end

M.gen_tabpage = function()
  local n_tabpages = vim.fn.tabpagenr('$')
  if n_tabpages == 1 then
    return ''
  end
  return string.format('%%= Tab %d/%d ', vim.fn.tabpagenr(), n_tabpages)
end

M.gen_tabline_item = function(item, cur, bufnr)
  local is_current = bufnr == cur

  local filename = vim.fn.fnamemodify(item.filename, ':t')
  local modified = vim.bo[bufnr].modified and 'Modified' or ''

  local click = string.format('%%%s@SwitchBuffer@', bufnr)
  local hl_label = is_current and 'DartCurrentLabel' or 'DartVisibleLabel'
  local label = item.mark ~= '' and item.mark .. ' ' or ''
  local hl = is_current and 'DartCurrent' or 'DartVisible'
  local content = filename ~= '' and filename or '*'

  local icon = M.get_icon(filename)

  return {
    bufnr = bufnr,
    hl_label = hl_label .. modified,
    label = label,
    hl = hl .. modified,
    content = content,
    icon = icon,
    click = click,
  }
end

M.get_icon_provider = function()
  local ok_devicons, devicons = pcall(require, 'nvim-web-devicons')
  if not M.config.tabline.icons then
    return function(_)
      return nil
    end
  elseif _G.MiniIcons ~= nil then
    return function(n)
      return _G.MiniIcons.get('file', n)
    end
  elseif ok_devicons then
    return function(n)
      return devicons.get_icon(n, nil, { default = true })
    end
  else
    return function(_)
      return nil
    end
  end
end

M.get_duplicate_paths = function(items)
  local exists = {}
  local result = {}
  for _, item in ipairs(items) do
    exists[item.content] = (exists[item.content] or 0) + 1
    if exists[item.content] > 1 then
      result[item.content] = true
    end
  end
  return result
end

M.expand_paths = function(items)
  local dupes = M.get_duplicate_paths(items)
  local recurse = false

  for _, item in ipairs(items) do
    if dupes[item.content] then
      item.content = M.add_parent_path(item)
      recurse = true
    end
  end
  if recurse then
    return M.expand_paths(items)
  else
    -- escape % in tabline items
    for _, item in ipairs(items) do
      item.content = item.content:gsub('%%', '%%%%')
    end
    return items
  end
end

M.add_parent_path = function(item)
  local full = vim.api.nvim_buf_get_name(item.bufnr)
  local sep = package.config:sub(1, 1)

  local regex = string.format('[^%s]+%s%s$', sep, sep, vim.pesc(item.content))
  return full:match(regex) or item.content
end

M.truncate_tabline = function(items, center, columns)
  local result = { items[center] }
  local left = center - 1
  local right = center + 1
  local trunc_left = false
  local trunc_right = false

  local function width(tabline)
    return vim.api.nvim_strwidth(table.concat(
      vim.tbl_map(function(m)
        return string.format(' %s %s ', m.label, m.content)
      end, tabline),
      ''
    )) + 3 -- save room for trunc
  end

  while left >= 1 or right <= #items do
    local added = false

    if left >= 1 then
      table.insert(result, 1, items[left])
      if width(result) >= columns then
        table.remove(result, 1)
        trunc_left = true
      else
        left = left - 1
        added = true
      end
    end
    if right <= #items then
      table.insert(result, items[right])
      if width(result) >= columns then
        table.remove(result)
        trunc_right = true
      else
        right = right + 1
        added = true
      end
    end
    if not added then
      break
    end
  end

  return (trunc_left and '%#DartVisibleLabel# < ' or '')
    .. table.concat(
      vim.tbl_map(function(n)
        return M.config.tabline.format_item(n)
      end, result),
      ''
    )
    .. (trunc_right and '%#DartVisibleLabel# > ' or '')
end

M.mark = function(bufnr, mark)
  if not bufnr then
    bufnr = vim.api.nvim_get_current_buf()
  end
  if not mark then
    mark = M.next_unused_mark()
    if not mark then
      return M.mark(bufnr, '+')
    end
  end

  local filename = vim.api.nvim_buf_get_name(bufnr)
  if not M.should_show(filename) then
    return
  end

  -- If mark already exists, update it to new file
  local mark_exists = M.state_from_mark(mark)
  if mark_exists then
    mark_exists.filename = filename
    return
  end

  local file_exists = M.state_from_filename(filename)
  if not file_exists then
    table.insert(M.state, {
      mark = mark,
      filename = vim.fn.fnamemodify(filename, ':p'),
    })
  elseif vim.tbl_contains(M.config.buflist, file_exists.mark) then
    file_exists.mark = mark -- allow for re-marking buffers in the buflist
  else
    -- if a marked buffer is marked again, instead un-mark it and move it to the buflist
    M.del_by_filename(filename)
    M.shift_buflist(filename)
  end

  local order = M.config.tabline.order(M.config)
  table.sort(M.state, function(a, b)
    return (order[a.mark] or 999) < (order[b.mark] or 999)
  end)

  M.emit_change()
end

M.unmark = function(opts)
  local marks = ({
    marks = opts.marks,
    marklist = M.config.marklist,
    buflist = M.config.buflist,
    all = vim.tbl_map(function(m)
      return m.mark
    end, M.state),
  })[opts.type]

  if not marks then
    return
  end

  vim.tbl_map(function(m)
    M.del_by_filename(M.state_from_mark(m).filename)
  end, marks)

  -- ensure current buffer is shown, if it was wiped out
  local cur = vim.api.nvim_buf_get_name(0)
  if not M.state_from_filename(cur) then
    M.shift_buflist(cur)
  end

  M.emit_change()
end

Dart.state = function()
  return M.state
end

Dart.mark = M.mark
Dart.unmark = M.unmark
Dart.read_session = M.read_session
Dart.write_session = M.write_session
Dart.state_from_mark = M.state_from_mark
Dart.state_from_filename = M.state_from_filename
Dart.should_show = M.should_show

Dart.jump = function(mark)
  local m = M.state_from_mark(mark)
  if m and m.filename then
    vim.api.nvim_set_current_buf(M.get_bufnr(m.filename))
  end
end

Dart.pick = function()
  local buf = vim.api.nvim_create_buf(false, true)
  local ns = vim.api.nvim_create_namespace('dart_pick')
  local prompt = { 'Jump to buffer:' }
  local row_len = #prompt[1]

  -- close window on esc and pick mapping
  for _, map in ipairs { '<Esc>', M.config.mappings.pick } do
    vim.keymap.set('n', map, function()
      vim.api.nvim_win_close(0, true)
    end, { buffer = buf, nowait = true, silent = true })
  end

  for _, mark in ipairs(M.state) do
    -- map each mark to jump
    vim.keymap.set('n', mark.mark, function()
      vim.api.nvim_win_close(0, true)
      Dart.jump(mark.mark)
    end, { buffer = buf, nowait = true, silent = true })

    local path = vim.fn.fnamemodify(mark.filename, M.config.picker.path_format)
    local entry = string.format('  %s → %s', mark.mark, path)
    if #entry > row_len then
      row_len = #entry
    end
    table.insert(prompt, entry)
  end

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, prompt)
  for i = 1, #prompt do
    vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, {
      end_col = math.min(5, #prompt[i]),
      hl_group = 'DartPickLabel',
    })
  end
  vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, {
    end_line = 1,
    hl_group = 'DartPickLabel',
  })

  vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = row_len + 2,
    height = #M.state + 2,
    row = math.floor((vim.o.lines - (#M.state + 2)) / 2),
    col = math.floor((vim.o.columns - (row_len + 2)) / 2),
    anchor = 'NW',
    style = 'minimal',
    border = M.config.picker.border,
    focusable = true,
  })
end

Dart.next = function()
  M.cycle_tabline(1)
end

Dart.prev = function()
  M.cycle_tabline(-1)
end

Dart.gen_tabline = function()
  local items = {}
  local center = 1
  local cur = vim.api.nvim_get_current_buf()

  for i, m in ipairs(M.state) do
    if M.should_show(m.filename) then
      local bufnr = M.get_bufnr(m.filename)
      if bufnr == cur then
        center = i
      end
      table.insert(items, M.gen_tabline_item(m, cur, bufnr))
    else
      M.del_by_filename(m.filename)
    end
  end

  items = M.expand_paths(items)

  local truncated = M.truncate_tabline(items, center, vim.o.columns)
  return truncated .. '%X%#DartFill#' .. M.gen_tabpage()
end

return Dart
