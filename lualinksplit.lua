local traverse, traverse_list, copy, node_new, free, rangedimensions = node.traverse, node.traverse_list, node.copy, node.new, node.free, node.rangedimensions

local hlist, vlist, whatsit = node.id'hlist', node.id'vlist', node.id'whatsit'

local pdf_start_link, pdf_end_link, pdf_link_state = node.subtype'pdf_start_link', node.subtype'pdf_end_link', node.subtype'pdf_link_state'

local whatsits = node.whatsits()
local properties = node.get_properties_table()
local call_callback = luatexbase.call_callback

local function start_level(linkstacks, linkstate, level, head)
  local stack = linkstacks[linkstate or linkstacks.linkstate]
  if not stack then return head end

  local new_head = head
  for i = 1, #stack do
    local link = stack[i]
    if link.level == level then
      local start_link = copy(link.node_template)
      new_head = node.insert_before(new_head, head, start_link)
      properties[start_link] = {linksplit__artificial = true}
      link.node, link.initial = start_link, false
    end
  end
  return new_head
end

local function end_level(linkstacks, linkstate, level, head, outer)
  local stack = linkstacks[linkstate or linkstacks.linkstate]
  if not stack then return end

  for i = 1, #stack do
    local link = stack[i]
    if link.level == level then
      local start_link = link.node
      if start_link then
        local end_link = node_new(whatsit, pdf_end_link)
        end_link.attr = start_link.attr
        -- We end the link directly after it's start.
        -- The real dimensions are given in the start node.
        node.insert_after(start_link, start_link, end_link)
        properties[end_link] = {linksplit__artificial = true}
        link.node = nil
        -- Now we need to determine the link width.
        -- We currently disregard bidi and instead just use the box width
        -- minus the width of existing content.
        local pre_link_width = rangedimensions(outer, head, start_link)
        start_link.width = outer.width - pre_link_width

        call_callback('linksplit', start_link, link.initial and 'initial' or 'middle')
      end
    end
  end
end

local function push_link(linkstacks, linkstate, level, node, direction)
  local stack = linkstacks[linkstate or linkstacks.linkstate]
  if not stack then
    stack = {}
    linkstacks[linkstate or linkstacks.linkstate] = stack
  end
  stack[#stack + 1] = {
    node = node,
    node_template = copy(node),
    level = level,
    initial = true,
  }
end

local function pop_link(linkstacks, linkstate, level, node)
  local stack = linkstacks[linkstate or linkstacks.linkstate]
  local link_count = stack and #stack
  if not link_count or link_count == 0 then
    -- tex.error("No link here to end")
    -- No link here. We could print an error, but the engine will do that anyway.
  else
    local top = stack[link_count]
    if top.level ~= level then
      tex.error(string.format("Link startet on level %i ended on level %i", top.level, level))
    end
    free(top.node_template)
    stack[link_count] = nil

    call_callback('linksplit', top.node, top.initial and 'isolated' or 'final')
  end
end

local process_vlist, process_hlist

function process_hlist(head, level, linkstacks, linkstate, outer)
  level = level + 1
  local real_head = head
  real_head = start_level(linkstacks, linkstate, level, head)
  for n, id, sub in traverse(head) do
    if id == vlist then
      process_vlist(n.list, level, linkstacks, linkstate)
    elseif id == hlist then
      n.list = process_hlist(n.list, level, linkstacks, linkstate, n)
    elseif id == whatsit then
      if sub == pdf_start_link then
        push_link(linkstacks, linkstate, level, n, 'TRT') -- FIXME: Direction
      elseif sub == pdf_end_link then
        pop_link(linkstacks, linkstate, level, n)
      elseif sub == pdf_link_state then
        texio.write_nl('WARNING: linkstate in hbox ignored')
      end
    end
  end
  end_level(linkstacks, linkstate, level, real_head, outer)
  return real_head
end

function process_vlist(head, level, linkstacks, linkstate)
  level = level + 1
  for n, id, sub in traverse(head) do
    if id == vlist then
      process_vlist(n.list, level, linkstacks, linkstate)
    elseif id == hlist then
      n.list = process_hlist(n.list, level, linkstacks, linkstate, n)
    elseif id == whatsit then
      if sub == pdf_link_state then
        local props = properties[n]
        local value = props and props.value
        if value == nil then
          texio.write_nl('WARNING: Manually created linkstate ignored')
        elseif value < 0 then
          linkstate = -value
        else
          linkstacks.linkstate, linkstate = value, nil
        end
      elseif sub == pdf_start_link then
        tex.error("'startlink' ended up in vlist")
      elseif sub == pdf_end_link then
        tex.error("'endlink' ended up in vlist")
      end
    end
  end
  return true
end

local linkstacks = {
  linkstate = 0,
}

luatexbase.create_callback('linksplit', 'simple')
luatexbase.add_to_callback('pre_shipout_filter', function(head)
  process_vlist(head, 0, linkstacks, nil)
  return true
end, 'linksplit')

local pdflinkstate_func = luatexbase.new_luafunction'pdflinkstate'
token.set_lua('pdflinkstate', pdflinkstate_func)
lua.get_functions_table()[pdflinkstate_func] = function()
  local value = token.scan_int()
  local n = node_new(whatsit, pdf_link_state)
  n.value = value
  local props = properties[n] or {}
  properties[n] = props
  props.value = value
  node.write(n)
end
