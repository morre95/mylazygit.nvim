-- One marker grammar serves loaded previews and the write/stage boundary.
local M = {}
function M.parse(content, marker_size)
  if content:find("\0", 1, true) then
    return nil, "Binary conflict is unsupported; resolve externally and stage explicitly. File remains unresolved"
  end

  local lines = vim.split(content, "\n", { plain = true })
  lines[1] = lines[1]:gsub("^\239\187\191", "")
  local conflicts, chunks = {}, {}
  local current, section, marker_width
  local function marker(line)
    local text = line:gsub("\r$", "")
    local kind = text:sub(1, 1)
    if kind ~= "<" and kind ~= "|" and kind ~= "=" and kind ~= ">" then return end
    local run, label = text:match("^(" .. kind .. "+)(.*)$")
    -- Shortened marker runs must not become selectable side content. Preserve
    -- ordinary one/two-character source operators when markers are wider.
    local minimum = math.min(3, math.max(1, marker_size - 1))
    if not run or #run < minimum then return end
    return kind, #run, vim.trim(label), label == "" or label:match("^%s") ~= nil
  end
  local function malformed(i)
    return nil, "Malformed conflict markers at line " .. i .. "; file remains unresolved"
  end
  for i, line in ipairs(lines) do
    local kind, width, label, valid_label = marker(line)
    if kind then
      if not valid_label then return malformed(i) end
      if not current then
        if kind ~= "<" or width ~= marker_size then return malformed(i) end
        current = { ours = {}, ancestor = {}, theirs = {}, raw = {}, resolved = false, ours_label = label }
        marker_width, section = width, "ours"
      else
        if width ~= marker_width then return malformed(i) end
        if kind == "|" and section == "ours" then
          section = "ancestor"
          current.ancestor_label = label
        elseif kind == "=" and (section == "ours" or section == "ancestor") and label == "" then
          section = "theirs"
        elseif kind == ">" and section == "theirs" then
          current.theirs_label = label
          table.insert(current.raw, line)
          table.insert(conflicts, current)
          table.insert(chunks, { type = "conflict", index = #conflicts })
          current, section = nil, nil
        else
          return malformed(i)
        end
      end
      if current then table.insert(current.raw, line) end
    elseif current then
      table.insert(current[section], line)
      table.insert(current.raw, line)
    elseif #chunks > 0 and chunks[#chunks].type == "text" then
      table.insert(chunks[#chunks].lines, line)
    else
      table.insert(chunks, { type = "text", lines = { line } })
    end
  end
  if current then return malformed(#lines) end

  return conflicts, chunks
end
return M
