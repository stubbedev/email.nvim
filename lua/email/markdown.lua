local M = {}

local CHAR = "[%z\1-\127\194-\244][\128-\191]*"

local function width_of(s)
  return vim.fn.strdisplaywidth(s)
end

local function builder()
  return { parts = {}, len = 0, spans = {}, links = {}, images = {} }
end

local function push(b, text, group)
  if text == "" then
    return
  end
  local start = b.len
  b.parts[#b.parts + 1] = text
  b.len = b.len + #text
  if group then
    b.spans[#b.spans + 1] = { start, b.len, group }
  end
end

local function finish(b)
  return { text = table.concat(b.parts), spans = b.spans, links = b.links, images = b.images }
end

local function merge(b, sub, group, url)
  local offset = b.len
  push(b, sub.text)
  for _, span in ipairs(sub.spans) do
    b.spans[#b.spans + 1] = { span[1] + offset, span[2] + offset, span[3] }
  end
  for _, link in ipairs(sub.links) do
    b.links[#b.links + 1] = { link[1] + offset, link[2] + offset, link[3] }
  end
  for _, image in ipairs(sub.images) do
    b.images[#b.images + 1] = { col = image.col + offset, alt = image.alt, source = image.source }
  end
  if group then
    b.spans[#b.spans + 1] = { offset, b.len, group }
  end
  if url then
    b.links[#b.links + 1] = { offset, b.len, url }
  end
end

local function closing_bracket(s, i)
  local depth, j = 0, i
  while j <= #s do
    local c = s:sub(j, j)
    if c == "\\" then
      j = j + 2
    else
      if c == "[" then
        depth = depth + 1
      elseif c == "]" then
        depth = depth - 1
        if depth == 0 then
          return j
        end
      end
      j = j + 1
    end
  end
  return nil
end

local function destination(s, i)
  if s:sub(i + 1, i + 1) == "<" then
    local close = s:find(">", i + 2, true)
    if close and s:sub(close + 1, close + 1) == ")" then
      return s:sub(i + 2, close - 1), close + 2
    end
    return nil
  end
  local depth, j = 0, i
  while j <= #s do
    local c = s:sub(j, j)
    if c == "(" then
      depth = depth + 1
    elseif c == ")" then
      depth = depth - 1
      if depth == 0 then
        local target = vim.trim(s:sub(i + 1, j - 1)):match("^(%S+)")
        return target, j + 1
      end
    end
    j = j + 1
  end
  return nil
end

local function find_unescaped(s, needle, from)
  local j = from
  while j <= #s - #needle + 1 do
    local c = s:sub(j, j)
    if c == "\\" then
      j = j + 2
    elseif s:sub(j, j + #needle - 1) == needle then
      return j
    else
      j = j + 1
    end
  end
  return nil
end

function M.inline(s, opts)
  local b = builder()
  local plain = {}
  local function flush()
    if #plain > 0 then
      push(b, table.concat(plain))
      plain = {}
    end
  end
  local i, n = 1, #s
  while i <= n do
    local c = s:sub(i, i)
    local consumed = false
    if c == "\\" and i < n and s:sub(i + 1, i + 1):match("%p") then
      plain[#plain + 1] = s:sub(i + 1, i + 1)
      i, consumed = i + 2, true
    elseif c == "`" then
      local run = s:match("^`+", i)
      local close = s:find(run, i + #run, true)
      if close then
        flush()
        push(b, s:sub(i + #run, close - 1), "EmailCode")
        i, consumed = close + #run, true
      end
    elseif c == "!" and s:sub(i + 1, i + 1) == "[" then
      local close = closing_bracket(s, i + 1)
      if close and s:sub(close + 1, close + 1) == "(" then
        local source, after = destination(s, close + 1)
        if source and after then
          flush()
          local alt = M.inline(s:sub(i + 2, close - 1), opts).text
          b.images[#b.images + 1] = { col = b.len, alt = alt, source = source }
          push(b, opts.image .. alt, "EmailImage")
          i, consumed = after, true
        end
      end
    elseif c == "[" then
      local close = closing_bracket(s, i)
      if close and s:sub(close + 1, close + 1) == "(" then
        local url, after = destination(s, close + 1)
        if url and after then
          flush()
          local label = M.inline(s:sub(i + 1, close - 1), opts)
          if opts.inline_urls then
            if label.text ~= url then
              label.text = label.text .. " <" .. url .. ">"
            end
            merge(b, label)
          else
            local icon = url:match("^mailto:") and opts.email or opts.link
            local start = b.len
            push(b, icon)
            merge(b, label)
            b.spans[#b.spans + 1] = { start, b.len, "EmailLink" }
            b.links[#b.links + 1] = { start, b.len, url }
          end
          i, consumed = after, true
        end
      end
    elseif c == "<" then
      local url = s:match("^<(https?://[^>%s]+)>", i)
      if url then
        flush()
        local start = b.len
        push(b, url, "EmailLink")
        b.links[#b.links + 1] = { start, b.len, url }
        i, consumed = i + #url + 2, true
      end
    elseif c == "*" or c == "_" then
      local delim = s:sub(i, i + 1) == c .. c and c .. c or c
      local close = find_unescaped(s, delim, i + #delim)
      if close and close > i + #delim then
        flush()
        merge(b, M.inline(s:sub(i + #delim, close - 1), opts), #delim == 2 and "EmailStrong" or "EmailEmph")
        i, consumed = close + #delim, true
      end
    end
    if not consumed then
      plain[#plain + 1] = c
      i = i + 1
    end
  end
  flush()
  return finish(b)
end

local function emit(out, text, spans, links, images, line_group)
  out.lines[#out.lines + 1] = text
  local row = #out.lines
  if line_group then
    out.line_highlights[#out.line_highlights + 1] = { row, line_group }
  end
  for _, span in ipairs(spans or {}) do
    out.highlights[#out.highlights + 1] = { row, span[1], span[2], span[3] }
  end
  for _, link in ipairs(links or {}) do
    out.links[#out.links + 1] = { row = row, start_col = link[1], end_col = link[2], url = link[3] }
  end
  for index, image in ipairs(images or {}) do
    if index > 1 then
      out.lines[#out.lines + 1] = ""
    end
    out.images[#out.images + 1] = { row = #out.lines, alt = image.alt, source = image.source }
  end
end

local function shifted(list, offset)
  local out = {}
  for i, item in ipairs(list) do
    out[i] = { item[1] + offset, item[2] + offset, item[3] }
  end
  return out
end

local function emit_inline(out, prefix, prefix_group, rendered, extra_group, line_group)
  local spans = shifted(rendered.spans, #prefix)
  if prefix_group and prefix ~= "" then
    table.insert(spans, 1, { 0, #prefix, prefix_group })
  end
  if extra_group then
    table.insert(spans, 1, { #prefix, #prefix + #rendered.text, extra_group })
  end
  local images = {}
  for i, image in ipairs(rendered.images) do
    images[i] = image
  end
  emit(out, prefix .. rendered.text, spans, shifted(rendered.links, #prefix), images, line_group)
end

local function split_row(line)
  local s = vim.trim(line)
  if s:sub(1, 1) == "|" then
    s = s:sub(2)
  end
  if s:sub(-1) == "|" and s:sub(-2, -2) ~= "\\" then
    s = s:sub(1, -2)
  end
  local cells, start, j = {}, 1, 1
  while j <= #s do
    local c = s:sub(j, j)
    if c == "\\" then
      j = j + 2
    elseif c == "|" then
      cells[#cells + 1] = vim.trim(s:sub(start, j - 1))
      start = j + 1
      j = j + 1
    else
      j = j + 1
    end
  end
  cells[#cells + 1] = vim.trim(s:sub(start))
  return cells
end

local function separator_alignments(line)
  if not line or not line:match("^%s*|") then
    return nil
  end
  local aligns = {}
  for i, cell in ipairs(split_row(line)) do
    if not cell:match("^:?%-+:?$") then
      return nil
    end
    local left, right = cell:sub(1, 1) == ":", cell:sub(-1) == ":"
    aligns[i] = (left and right) and "center" or right and "right" or "left"
  end
  return aligns
end

local function wrap(text, width)
  if width_of(text) <= width then
    return { { 1, #text } }
  end
  local chars = {}
  for start, char in text:gmatch("()(" .. CHAR .. ")") do
    chars[#chars + 1] = { start = start, stop = start + #char - 1, space = char == " ", width = width_of(char) }
  end
  local segments = {}
  local function close(first, last)
    while last >= first and chars[last].space do
      last = last - 1
    end
    if last >= first then
      segments[#segments + 1] = { chars[first].start, chars[last].stop }
    end
  end
  local i = 1
  while i <= #chars do
    while i <= #chars and chars[i].space do
      i = i + 1
    end
    local first, used, last_space = i, 0, nil
    while i <= #chars and (used == 0 or used + chars[i].width <= width) do
      if chars[i].space then
        last_space = i
      end
      used = used + chars[i].width
      i = i + 1
    end
    if i <= #chars and last_space and not chars[i].space then
      close(first, last_space - 1)
      i = last_space + 1
    elseif first <= #chars then
      close(first, i - 1)
    end
  end
  return segments
end

local function column_widths(natural, available)
  local total = 0
  for _, w in ipairs(natural) do
    total = total + w
  end
  if total <= available or available < #natural then
    return natural
  end
  local widths, open, left = {}, {}, available
  for c = 1, #natural do
    open[c] = true
  end
  local changed = true
  while changed do
    changed = false
    local count = vim.tbl_count(open)
    local share = math.floor(left / count)
    for c in pairs(open) do
      if natural[c] <= share then
        widths[c], left, open[c], changed = natural[c], left - natural[c], nil, true
      end
    end
  end
  local rest = {}
  for c in pairs(open) do
    rest[#rest + 1] = c
  end
  table.sort(rest)
  local share, extra = math.floor(left / #rest), left % #rest
  for i, c in ipairs(rest) do
    widths[c] = math.max(1, share + (i <= extra and 1 or 0))
  end
  return widths
end

local function clip(list, from, to, offset)
  local out = {}
  for _, item in ipairs(list) do
    local s, e = math.max(item[1], from), math.min(item[2], to)
    if s < e then
      out[#out + 1] = { s - from + offset, e - from + offset, item[3] }
    end
  end
  return out
end

local function render_table(out, header, aligns, rows, width, opts)
  local all = { header }
  vim.list_extend(all, rows)
  local columns = 0
  for _, row in ipairs(all) do
    columns = math.max(columns, #row)
  end
  local cells, natural = {}, {}
  for c = 1, columns do
    natural[c] = 1
  end
  for r, row in ipairs(all) do
    cells[r] = {}
    for c = 1, columns do
      local rendered = M.inline(row[c] or "", opts)
      rendered.images = {}
      cells[r][c] = rendered
      natural[c] = math.max(natural[c], width_of(rendered.text))
    end
  end
  local widths = column_widths(natural, width - (3 * columns + 1))
  local function border(left, mid, right)
    local pieces = {}
    for c = 1, columns do
      pieces[c] = string.rep("─", widths[c] + 2)
    end
    local line = left .. table.concat(pieces, mid) .. right
    emit(out, line, { { 0, #line, "EmailTableBorder" } })
  end
  border("┌", "┬", "┐")
  for r, row in ipairs(cells) do
    local wrapped, height = {}, 1
    for c = 1, columns do
      wrapped[c] = wrap(row[c].text, widths[c])
      height = math.max(height, #wrapped[c])
    end
    for k = 1, height do
      local parts, spans, links = { "│ " }, { { 0, #"│ ", "EmailTableBorder" } }, {}
      local offset = #"│ "
      for c = 1, columns do
        local cell, segment = row[c], wrapped[c][k]
        local piece = segment and cell.text:sub(segment[1], segment[2]) or ""
        local pad = widths[c] - width_of(piece)
        local align = aligns[c] or "left"
        local before = align == "right" and pad or align == "center" and math.floor(pad / 2) or 0
        parts[#parts + 1] = string.rep(" ", before)
        offset = offset + before
        if segment then
          vim.list_extend(spans, clip(cell.spans, segment[1] - 1, segment[2], offset))
          vim.list_extend(links, clip(cell.links, segment[1] - 1, segment[2], offset))
          if r == 1 then
            spans[#spans + 1] = { offset, offset + #piece, "EmailTableHeader" }
          end
        end
        parts[#parts + 1] = piece
        offset = offset + #piece
        local after = pad - before
        local sep = c < columns and " │ " or " │"
        parts[#parts + 1] = string.rep(" ", after) .. sep
        spans[#spans + 1] = { offset + after, offset + after + #sep, "EmailTableBorder" }
        offset = offset + after + #sep
      end
      emit(out, table.concat(parts), spans, links)
    end
    if r == 1 then
      border("├", "┼", "┤")
    end
  end
  border("└", "┴", "┘")
end

local function render_markdown(lines, width, opts, out)
  local i = 1
  while i <= #lines do
    local line = lines[i]
    local aligns = line:match("^%s*|") and separator_alignments(lines[i + 1])
    if line:match("^%s*```") then
      i = i + 1
      while i <= #lines and not lines[i]:match("^%s*```") do
        emit(out, lines[i], { { 0, #lines[i], "EmailCode" } }, nil, nil, "EmailCodeBlock")
        i = i + 1
      end
      i = i + 1
    elseif aligns then
      local header, rows = split_row(line), {}
      i = i + 2
      while i <= #lines and lines[i]:match("^%s*|") do
        rows[#rows + 1] = split_row(lines[i])
        i = i + 1
      end
      render_table(out, header, aligns, rows, width, opts)
    else
      local hashes, heading = line:match("^(#+)%s+(.*)$")
      local quote = line:match("^(>[>%s]*)")
      local indent, bullet, item = line:match("^(%s*)([-*+])%s+(.*)$")
      local num_indent, number, numbered = line:match("^(%s*)(%d+)%.%s+(.*)$")
      if hashes and #hashes <= 6 then
        local level = #hashes
        local group = "EmailH" .. level
        emit_inline(
          out,
          opts.headings[(level - 1) % #opts.headings + 1],
          group,
          M.inline(heading, opts),
          group,
          group .. "Bg"
        )
      elseif line:match("^%s*%-%-%-+%s*$") or line:match("^%s*%*%*%*+%s*$") then
        local rule = string.rep("─", width)
        emit(out, rule, { { 0, #rule, "EmailRule" } })
      elseif quote then
        local depth = select(2, quote:gsub(">", ""))
        emit_inline(out, string.rep(opts.quote .. " ", depth), "EmailQuote", M.inline(line:sub(#quote + 1), opts))
      elseif bullet then
        local level = math.floor(#indent / 2) % #opts.bullets + 1
        emit_inline(out, indent .. opts.bullets[level] .. " ", "EmailBullet", M.inline(item, opts))
      elseif number then
        emit_inline(out, num_indent .. number .. ". ", "EmailBullet", M.inline(numbered, opts))
      else
        emit_inline(out, "", nil, M.inline(line, opts))
      end
      i = i + 1
    end
  end
end

function M.render(segments, width, opts)
  local out = { lines = {}, highlights = {}, line_highlights = {}, links = {}, images = {} }
  for _, segment in ipairs(segments) do
    if #out.lines > 0 then
      out.lines[#out.lines + 1] = ""
    end
    if segment.markdown then
      render_markdown(segment.lines, width, opts, out)
    else
      vim.list_extend(out.lines, segment.lines)
    end
  end
  return out
end

return M
