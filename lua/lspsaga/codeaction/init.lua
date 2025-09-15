local api, lsp = vim.api, vim.lsp
local config = require('lspsaga').config
local win = require('lspsaga.window')
local preview = require('lspsaga.codeaction.preview')
local ns = api.nvim_create_namespace('saga_action')
local util = require('lspsaga.util')

local act = {}
local ctx = {}

act.__index = act
function act.__newindex(t, k, v)
  rawset(t, k, v)
end

local function clean_ctx()
  for k, _ in pairs(ctx) do
    ctx[k] = nil
  end
end

---@param str string
function act:concealed_markdown_len(str)
  local count = 0
  -- Link text: [text](url)
  for text, url in str:gmatch('%[([^%]]-)%]%((.-)%)') do
    count = count + 4 + api.nvim_strwidth(url)
    local escaped_text = util.to_litteral_string(text)
    local escaped_url = util.to_litteral_string(url)
    str = str:gsub('%[' .. escaped_text .. '%]%(' .. escaped_url .. '%)', '')
  end
  -- Bold text: **text**
  for matched in str:gmatch('%*%*.-%*%*') do
    count = count + 4
    str = str:gsub('%*%*' .. util.to_litteral_string(matched) .. '%*%*', '')
  end
  -- Italic text: *text*
  for matched in str:gmatch('%*.-%*') do
    count = count + 2
    str = str:gsub('%*' .. util.to_litteral_string(matched) .. '%*', '')
  end
  -- Strikethrough text: ~~text~~
  for matched in str:gmatch('~~.-~~') do
    count = count + 4
    str = str:gsub('~~' .. util.to_litteral_string(matched) .. '~~', '')
  end
  -- Fenced code inline: `code`
  for matched in str:gmatch('`.-`') do
    count = count + 2
    str = str:gsub('`' .. util.to_litteral_string(matched) .. '`', '')
  end
  -- Fenced code blocks: ```code```
  for matched in str:gmatch('```.-```') do
    count = count + 6
    str = str:gsub('```' .. util.to_litteral_string(matched) .. '```', '')
  end
  return count
end

--- Get lsp server priority
---@param client string|number
function act:get_lsp_priority(client)
  local priorities = config.code_action.server_priority
  if not client then
    return priorities.default or 1000
  end
  if type(client) == 'number' then
    local _c = lsp.get_client_by_id(client)
    if not _c then
      return priorities.default or 1000
    end
    client = _c.name
  end
  return priorities[client] or priorities.default or 1000
end

function act:action_callback(tuples, enriched_ctx)
  if #tuples == 0 then
    vim.notify('No code actions available', vim.log.levels.INFO)
    return
  end

  -- sort by server priority from high to low
  table.sort(tuples, function(a, b)
    local prio_a = self:get_lsp_priority(a[1])
    local prio_b = self:get_lsp_priority(b[1])
    if prio_a == prio_b then
      return a[3] < b[3] -- preserve action order if the same client
    end
    return prio_a > prio_b
  end)

  local content = {}

  local align = util.align
  local section_padding = '  '
  local max_index, name_max_len, group_max_len = util.num_len(#tuples), 0, 0
  for _, client_with_actions in ipairs(tuples) do
    if client_with_actions[2].name then
      local name_len = api.nvim_strwidth(client_with_actions[2].name .. section_padding)
      name_max_len = math.max(name_len, name_max_len)
    elseif client_with_actions[2].title then
      local title_len = api.nvim_strwidth(client_with_actions[2].title .. section_padding)
      name_max_len = math.max(title_len, name_max_len)
    end
    if client_with_actions[2].group then
      local group_len =
        api.nvim_strwidth((client_with_actions[2].group .. section_padding) or section_padding)
      group_max_len = math.max(group_len, group_max_len)
    end
  end
  for index, client_with_actions in ipairs(tuples) do
    local action_title = ''
    if #client_with_actions < 2 then
      vim.notify('[lspsaga] failed indexing client actions')
      return
    end

    if client_with_actions[2].name or client_with_actions[2].title then
      action_title = align(' **' .. tostring(index) .. '**' .. section_padding, max_index + 7) -- 7 is ` **` + `**` + section_padding
        .. align(
          (client_with_actions[2].name or client_with_actions[2].title or '') .. section_padding,
          name_max_len
            + act:concealed_markdown_len(
              (client_with_actions[2].name or client_with_actions[2].title or '')
            )
        )
        .. align((client_with_actions[2].group or '') .. ' ', group_max_len)
    end
    if config.code_action.show_server_name == true then
      action_title = action_title
        .. (
          type(client_with_actions[1]) == 'string' and client_with_actions[1]
          or lsp.get_client_by_id(client_with_actions[1]).name
        )
    end
    content[#content + 1] = action_title
  end

  local max_height = math.floor(api.nvim_win_get_height(0) * config.code_action.max_height)

  local float_opt = {
    height = math.min(#content, max_height),
    width = util.get_max_content_length(content),
  }

  if config.ui.title then
    float_opt.title = {
      { config.ui.button[1], 'SagaButton' },
      { config.ui.code_action .. 'Actions: ', 'SagaActionTitle' },
      { tostring(#content), 'SagaActionTitle' },
      { config.ui.button[2], 'SagaButton' },
    }
  end

  content = vim.tbl_map(function(item)
    item = item:gsub('\r\n', '\\r\\n')
    return item:gsub('\n', '\\n')
  end, content)

  self.action_bufnr, self.action_winid = win
    :new_float(float_opt, true)
    :setlines(content)
    :bufopt({
      ['buftype'] = 'nofile',
      ['bufhidden'] = 'wipe',
      ['modifiable'] = false,
      ['filetype'] = 'markdown',
    })
    :winopt({
      ['conceallevel'] = 3,
      ['concealcursor'] = 'niv',
    })
    :winhl('SagaNormal', 'SagaBorder')
    :wininfo()
  -- initial position in code action window
  api.nvim_win_set_cursor(self.action_winid, { 1, 1 })
  api.nvim_win_set_hl_ns(self.action_winid, ns)
  api.nvim_create_autocmd('CursorMoved', {
    buffer = self.action_bufnr,
    callback = function()
      self:set_cursor(tuples)
    end,
  })
  for i = 1, #content, 1 do
    vim.hl.range(self.action_bufnr, ns, 'CodeActionText', { i - 1, 0 }, { i - 1, -1 })
  end

  self:apply_action_keys(tuples, enriched_ctx)
  if config.code_action.num_shortcut then
    self:num_shortcut(self.action_bufnr, tuples, enriched_ctx)
  end
end

local function map_keys(mode, keys, action, options)
  if type(keys) == 'string' then
    keys = { keys }
  end
  for _, key in ipairs(keys) do
    vim.keymap.set(mode, key, action, options)
  end
end

---@private
---@param bufnr integer
---@param mode "v"|"V"
---@return table {start={row, col}, end={row, col}} using (1, 0) indexing
local function range_from_selection(bufnr, mode)
  -- TODO: Use `vim.region()` instead https://github.com/neovim/neovim/pull/13896
  -- [bufnum, lnum, col, off]; both row and column 1-indexed
  local start = vim.fn.getpos('v')
  local end_ = vim.fn.getpos('.')
  local start_row = start[2]
  local start_col = start[3]
  local end_row = end_[2]
  local end_col = end_[3]

  -- A user can start visual selection at the end and move backwards
  -- Normalize the range to start < end
  if start_row == end_row and end_col < start_col then
    end_col, start_col = start_col, end_col
  elseif end_row < start_row then
    start_row, end_row = end_row, start_row
    start_col, end_col = end_col, start_col
  end
  if mode == 'V' then
    start_col = 1
    local lines = api.nvim_buf_get_lines(bufnr, end_row - 1, end_row, true)
    end_col = #lines[1]
  end
  return {
    ['start'] = { start_row, start_col - 1 },
    ['end'] = { end_row, end_col - 1 },
  }
end

function act:send_request(main_buf, options, callback)
  self.bufnr = main_buf
  options = options or {}
  if options.diagnostics or options.only then
    options = { options = options }
  end
  local context = options.context or {}
  if not context.triggerKind then
    context.triggerKind = vim.lsp.protocol.CodeActionTriggerKind.Invoked
  end
  if not context.diagnostics then
    local bufnr = api.nvim_get_current_buf()
    context.diagnostics = lsp.diagnostic.get_line_diagnostics(bufnr)
  end
  ---@type lsp.CodeActionParams
  local params
  local mode = api.nvim_get_mode().mode
  local offset_encoding = util.get_offset_encoding({ bufnr = main_buf })
  if options.range then
    assert(type(options.range) == 'table', 'code_action range must be a table')
    local start = assert(options.range.start, 'range must have a `start` property')
    local end_ = assert(options.range['end'], 'range must have a `end` property')
    params = lsp.util.make_given_range_params(start, end_, nil, offset_encoding)
  elseif mode == 'v' or mode == 'V' then
    local range = range_from_selection(0, mode)
    params = lsp.util.make_given_range_params(range.start, range['end'], nil, offset_encoding)
  else
    params = lsp.util.make_range_params(0, offset_encoding)
  end

  ---@cast params lsp.CodeActionParams
  params.context = context
  local enriched_ctx = { bufnr = main_buf, method = 'textDocument/codeAction', params = params }

  lsp.buf_request_all(main_buf, 'textDocument/codeAction', params, function(results)
    self.pending_request = false
    local action_tuples = {}

    local origin_order = 0
    for client_id, item in pairs(results) do
      for _, action in ipairs(item.result or {}) do
        origin_order = origin_order + 1
        action_tuples[#action_tuples + 1] = { client_id, action, origin_order }
      end
    end

    if config.code_action.extend_gitsigns and not options.gitsign then
      local res = self:extend_gitsign(params)
      if res then
        for _, action in ipairs(res) do
          origin_order = origin_order + 1
          action_tuples[#action_tuples + 1] = { 'gitsigns', action, origin_order }
        end
      end
    end

    if callback then
      callback(action_tuples, enriched_ctx)
    end
  end)
end

function act:set_cursor(action_tuples)
  api.nvim_buf_clear_namespace(self.action_bufnr, ns, 0, -1)
  local col = 1
  local current_line = api.nvim_win_get_cursor(self.action_winid)[1]
  if current_line == #action_tuples + 1 then
    api.nvim_win_set_cursor(self.action_winid, { 1, col })
  else
    api.nvim_win_set_cursor(self.action_winid, { current_line, col })
  end
  vim.hl.range(
    self.action_bufnr,
    ns,
    'SagaSelect',
    { current_line - 1, 0 },
    { current_line - 1, -1 }
  )
  local num = util.get_bold_num()
  if not num or not action_tuples[num] then
    return
  end
  local tuple = action_tuples[num]
  preview.action_preview(self.action_winid, self.bufnr, tuple)
end

local function apply_action(action, client, enriched_ctx)
  if action.edit then
    lsp.util.apply_workspace_edit(action.edit, client.offset_encoding)
  end
  if action.command then
    local command = type(action.command) == 'table' and action.command or action
    local func = client.commands[command.command] or lsp.commands[command.command]
    if func then
      enriched_ctx.client_id = client.id
      func(command, enriched_ctx)
    else
      local params = {
        command = command.command,
        arguments = command.arguments,
        workDoneToken = command.workDoneToken,
      }
      client:request('workspace/executeCommand', params, nil, enriched_ctx.bufnr)
    end
  end
  clean_ctx()
end

function act:support_resolve(client)
  local reg = client.dynamic_capabilities:get('textDocument/codeAction', { bufnr = ctx.bufnr })
  return vim.tbl_get(reg or {}, 'registerOptions', 'resolveProvider')
    or client:supports_method('codeAction/resolve')
end

function act:get_resolve_action(client, action, bufnr)
  if not self:support_resolve(client) then
    return
  end
  return client:request_sync('codeAction/resolve', action, 1500, bufnr).result
end

function act:do_code_action(action, client, enriched_ctx)
  if not action.edit and client and self:support_resolve(client) then
    client:request('codeAction/resolve', action, function(err, resolved_action)
      if err then
        vim.notify(err.code .. ': ' .. err.message, vim.log.levels.ERROR)
        return
      end
      apply_action(resolved_action, client, enriched_ctx)
    end)
  elseif action.action and type(action.action) == 'function' then
    action.action()
  else
    apply_action(action, client, enriched_ctx)
  end
end

function act:apply_action_keys(action_tuples, enriched_ctx)
  map_keys('n', config.code_action.keys.exec, function()
    local num = util.get_bold_num()
    if not num then
      return
    end
    local action = action_tuples[num][2]
    local client = lsp.get_client_by_id(action_tuples[num][1])
    self:close_action_window()
    self:do_code_action(action, client, enriched_ctx)
  end, { buffer = self.action_bufnr })

  map_keys('n', config.code_action.keys.quit, function()
    self:close_action_window()
    clean_ctx()
  end, { buffer = self.action_bufnr })
end

function act:num_shortcut(bufnr, action_tuples, enriched_ctx)
  for num in ipairs(action_tuples or {}) do
    util.map_keys(bufnr, tostring(num), function()
      if not action_tuples or not action_tuples[num] then
        return
      end
      local action = action_tuples[num][2]
      local client = lsp.get_client_by_id(action_tuples[num][1])
      self:close_action_window()
      self:do_code_action(action, client, enriched_ctx)
    end)
  end
  self.number_count = #action_tuples
end

function act:code_action(options)
  if self.pending_request then
    vim.notify(
      '[lspsaga] a code action has already been requested, please wait.',
      vim.log.levels.WARN
    )
    return
  end

  self.pending_request = true
  options = options or {}
  if config.code_action.only_in_cursor and not options.context then
    options.context = {
      diagnostics = require('lspsaga.diagnostic'):get_cursor_diagnostic(),
    }
  end

  self:send_request(api.nvim_get_current_buf(), options, function(tuples, enriched_ctx)
    self.pending_request = false
    self:action_callback(tuples, enriched_ctx)
  end)
end

function act:close_action_window()
  if self.action_winid and api.nvim_win_is_valid(self.action_winid) then
    pcall(api.nvim_win_close, self.action_winid, true)
  end
  preview.preview_win_close()
end

function act:clean_context()
  if self.number_count then
    for i = 1, self.number_count do
      api.nvim_buf_del_keymap(self.bufnr, 'n', tostring(i))
    end
  end
  clean_ctx()
end

function act:extend_gitsign(params)
  local ok, gitsigns = pcall(require, 'gitsigns')
  if not ok then
    return
  end

  local gitsigns_actions = gitsigns.get_actions()
  if not gitsigns_actions or vim.tbl_isempty(gitsigns_actions) then
    return
  end

  local name_to_title = function(name)
    return name:sub(1, 1):upper() .. name:gsub('_', ' '):sub(2)
  end

  local actions = {}
  local range_actions = { ['reset_hunk'] = true, ['stage_hunk'] = true }
  local mode = vim.api.nvim_get_mode().mode
  for name, action in pairs(gitsigns_actions) do
    local title = name_to_title(name)
    local cb = action
    if (mode == 'v' or mode == 'V') and range_actions[name] then
      title = title:gsub('hunk', 'selection')
      cb = function()
        action({ params.range.start.line, params.range['end'].line })
      end
    end
    actions[#actions + 1] = {
      title = title,
      action = function()
        local bufnr = vim.uri_to_bufnr(params.textDocument.uri)
        vim.api.nvim_buf_call(bufnr, cb)
      end,
    }
  end
  return actions
end

return setmetatable(ctx, act)
