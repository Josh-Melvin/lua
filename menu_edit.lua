-- MENU BOARD editor part (loaded by menu.lua only while editing).
local M = ...

local event = require("event")
local put, fill, wrap, yes, ulen, usub = M.put, M.fill, M.wrap, M.yes, M.ulen, M.usub
local CMAP, K, menu = M.CMAP, M.K, M.menu
local floor, max, min = math.floor, math.max, math.min
local BG, PANEL, WHITE, LIGHT, GRAY, YELLOW, RED = 0, 1, 2, 3, 4, 5, 6
local BLUE, GREEN, ORANGE, CYAN, FIELD, FOCUS = 8, 9, 10, 12, 14, 15
local CNAMES = {"red", "yellow", "orange", "green", "blue", "purple", "cyan", "brown", "gray", "darkred"}
local W, H

local YN = {"yes", "no"}
local FIELDS = {
  settings = {{"title", "Title"}, {"sub", "Subtitle"}, {"footer", "Footer"}, {"cur", "Currency"},
    {"secs", "Page secs", "num"}, {"cols", "Columns", {"auto", "1", "2", "3", "4"}},
    {"dots", "Dot leader", YN}, {"res", "Resolution"}, {"pin", "Edit PIN"}},
  section = {{"title", "Title"}, {"color", "Colour", CNAMES}, {"style", "Style", {"bar", "line"}},
    {"show", "Visible", YN}},
  item = {{"num", "Number"}, {"name", "Name"}, {"price", "Price"}, {"cal", "Calories"},
    {"mprice", "Meal price"}, {"mcal", "Meal cal."}, {"desc", "Details"}, {"badge", "Badge"},
    {"show", "Visible", YN}},
  head = {{"text", "Text"}, {"style", "Style", {"line", "text", "bar"}},
    {"align", "Align", {"left", "center"}}, {"show", "Visible", YN}},
  para = {{"text", "Text"}, {"style", "Style", {"body", "fine", "accent", "alert"}},
    {"align", "Align", {"left", "center"}}, {"show", "Visible", YN}},
}
local KNAME = {settings = "MENU SETTINGS", section = "SECTION", item = "MENU ITEM",
  head = "HEADER", para = "PARAGRAPH"}
local HELP = {
  num = "Combo number shown before the name. Optional.",
  price = "Shown on the right. Blank = no price.",
  cal = "Numbers get ' Cal.' added automatically.",
  mprice = "Meal / combo price. Blank = no meal line.",
  desc = "Small line under the name (flavours, notes).",
  badge = "e.g. NEW or BACK SOON. Replaces a blank price.",
  cur = "Put in front of numeric prices, e.g. $",
  secs = "Seconds per page when the menu needs several pages.",
  res = "max, or a size like 120x40 (bigger text).",
  pin = "Needed for E (edit) and Q (quit). Blank = none.",
  footer = "Fine print along the bottom of the board.",
}
local BTN = {{"+Item", "item"}, {"+Header", "head"}, {"+Text", "para"}, {"+Section", "sec"},
  {"Delete", "del"}, {"Up", "up"}, {"Down", "down"}, {"Save", "save"}, {"Done", "done"}}

local rows, sel, focus, cur, off, lscroll = {}, 1, 0, 0, 0, 0
local msg, armed, wasArmed, redraw = "", false, false, false
local EW, EH, LW, FX, BX, BW, STEP = 80, 25, 32, 35, 47, 33, 2

local function buildRows()
  rows = {{0, 0}}
  for si, s in ipairs(menu.sections) do
    rows[#rows + 1] = {si, 0}
    for ei in ipairs(s.items) do rows[#rows + 1] = {si, ei} end
  end
  sel = max(1, min(sel, #rows))
end
local function node()
  local r = rows[sel]
  if r[1] == 0 then return menu, "settings" end
  local s = menu.sections[r[1]]
  if r[2] == 0 then return s, "section" end
  local e = s.items[r[2]]
  return e, e.k or "item"
end
local function fields() local o, k = node() return FIELDS[k], o, k end
local function findRow(si, ei)
  for i, r in ipairs(rows) do if r[1] == si and r[2] == ei then sel = i return end end
end
local function setFocus(i)
  local F, o = fields()
  if i < 0 or i > #F then i = 0 end
  focus, off = i, 0
  if i > 0 then cur = ulen(o[F[i][1]] or "") end
end
local function fieldY(i) return 4 + (i - 1) * STEP end

local function drawRow(i)
  local y = i - lscroll + 1
  if y < 2 or y > EH - 2 then return end
  local r, b = rows[i], PANEL
  if i == sel then b = focus == 0 and FOCUS or FIELD end
  fill(1, y, LW, 1, b)
  if not r then return end
  if r[1] == 0 then put(2, y, "* MENU SETTINGS", CYAN, b) return end
  local s = menu.sections[r[1]]
  if r[2] == 0 then
    put(2, y, " ", WHITE, CMAP[s.color] or RED)
    put(4, y, usub(s.title or "", 1, LW - 4), yes(s.show) and YELLOW or GRAY, b)
    return
  end
  local e, t = s.items[r[2]], ""
  if e.k == "head" then t = "> " .. (e.text or "")
  elseif e.k == "para" then t = "\194\182 " .. (e.text or "")
  else
    t = ((e.num or "") ~= "" and (e.num .. " ") or "") .. (e.name or "")
    if (e.price or "") ~= "" then t = t .. "  " .. e.price end
  end
  put(4, y, usub(t, 1, LW - 4), yes(e.show) and WHITE or GRAY, b)
end

local function drawList()
  local lh = EH - 3
  if sel - lscroll > lh then lscroll = sel - lh elseif sel <= lscroll then lscroll = sel - 1 end
  for i = lscroll + 1, lscroll + lh do drawRow(i) end
end

local function drawField(i)
  local F, o = fields()
  local f = F[i]
  if not f then return end
  local y, isF = fieldY(i), focus == i
  put(FX, y, usub(f[2], 1, BX - FX - 1), isF and YELLOW or LIGHT, BG)
  local b = isF and FOCUS or FIELD
  fill(BX, y, BW, 1, b)
  local v = o[f[1]] or ""
  if type(f[3]) == "table" then
    if v == "" then v = f[3][1] end
    put(BX + 1, y, "< " .. v .. " >", isF and YELLOW or WHITE, b)
  elseif isF then
    if cur < off then off = cur elseif cur - off > BW - 1 then off = cur - BW + 1 end
    put(BX, y, usub(v, off + 1, off + BW), WHITE, b)
    local ch = usub(v, cur + 1, cur + 1)
    put(BX + cur - off, y, ch == "" and " " or ch, BG, YELLOW)
  else
    put(BX, y, usub(v, 1, BW), LIGHT, b)
  end
end

local function drawForm()
  local F, o, k = fields()
  STEP = (#F * 2 + 2 <= EH - 4) and 2 or 1
  fill(LW + 1, 2, EW - LW, EH - 3, BG)
  local t = k == "item" and o.name or k == "section" and o.title or ""
  put(FX, 2, usub(KNAME[k] .. (t ~= "" and (": " .. t) or ""), 1, EW - FX), YELLOW)
  for i = 1, #F do drawField(i) end
  local y0 = fieldY(#F) + 2
  local f = F[focus]
  local help = focus == 0 and "Up/Down picks a row. Enter or click a field to edit it."
    or HELP[f[1]] or (type(f[3]) == "table" and "Left/Right or click to change."
    or "Type to edit. Enter = next field.")
  wrap(help, EW - FX, function(s, i)
    if y0 + i - 1 <= EH - 2 then put(FX, y0 + i - 1, s, GRAY) end
  end)
end

local function drawStatus()
  fill(1, EH, EW, 1, PANEL)
  local s = msg ~= "" and msg or "Tab/Enter next  Up/Down move  Ins add  F2 save  F5 done"
  put(2, EH, usub(s, 1, EW - 12), msg ~= "" and YELLOW or GRAY, PANEL)
  if M.dirty then put(EW - 8, EH, "UNSAVED", ORANGE, PANEL) end
end

local function drawEditor()
  M.reset()
  fill(1, 1, EW, 1, RED)
  put(2, 1, "MENU EDITOR", YELLOW, RED)
  put(max(14, EW - ulen(M.FILE) - 1), 1, M.FILE, WHITE, RED)
  drawList()
  drawForm()
  fill(1, EH - 1, EW, 1, PANEL)
  local x = 2
  for _, b in ipairs(BTN) do
    local t = " " .. b[1] .. " "
    local c = b[2] == "del" and RED or (b[2] == "save" or b[2] == "done") and GREEN or BLUE
    put(x, EH - 1, t, WHITE, c)
    b.x1, b.x2 = x, x + ulen(t) - 1
    x = x + ulen(t) + 1
  end
  drawStatus()
end

local function newEl(kind)
  if kind == "item" then return {k = "item", name = "New item", price = "0.00"} end
  if kind == "head" then return {k = "head", text = "New header", style = "line"} end
  return {k = "para", text = "New paragraph", style = "body"}
end

local function act(a)
  local secs = menu.sections
  local si, ei = rows[sel][1], rows[sel][2]
  redraw = true
  if a == "item" or a == "head" or a == "para" then
    if si == 0 then si, ei = 1, 0 end
    if not secs[si] then msg = "Add a section first." return end
    table.insert(secs[si].items, ei + 1, newEl(a))
    M.dirty = true buildRows() findRow(si, ei + 1) setFocus(a == "item" and 2 or 1)
  elseif a == "sec" then
    local at = si == 0 and #secs + 1 or si + 1
    table.insert(secs, at, {title = "New section", color = "red", items = {}})
    M.dirty = true buildRows() findRow(at, 0) setFocus(1)
  elseif a == "del" then
    if si == 0 then msg = "Menu settings can't be deleted." return end
    if not wasArmed then
      armed = true
      msg = ei == 0 and "Delete WHOLE section? Press Delete again." or "Press Delete again to confirm."
      return
    end
    if ei == 0 then table.remove(secs, si) else table.remove(secs[si].items, ei) end
    M.dirty = true buildRows() focus = 0 msg = "Deleted."
  elseif a == "up" or a == "down" then
    if si == 0 then return end
    local d = a == "up" and -1 or 1
    local list = ei == 0 and secs or secs[si].items
    local i = ei == 0 and si or ei
    if not list[i + d] then return end
    list[i], list[i + d] = list[i + d], list[i]
    M.dirty = true buildRows()
    if ei == 0 then findRow(si + d, 0) else findRow(si, ei + d) end
  elseif a == "save" then
    local ok, err = M.save()
    msg = ok and ("Saved to " .. M.FILE) or ("Save failed: " .. tostring(err))
  elseif a == "done" then
    return "done"
  end
end

local function insertText(s)
  local F, o = fields()
  local f = F[focus]
  if not f or type(f[3]) == "table" then return end
  s = s:gsub("[\r\n\t]", " ")
  if f[3] == "num" then s = s:gsub("%D", "") end
  local v = o[f[1]] or ""
  if ulen(v) + ulen(s) > 300 then msg = "Field is full." return end
  o[f[1]] = usub(v, 1, cur) .. s .. usub(v, cur + 1)
  cur = cur + ulen(s)
  M.dirty = true
end

local function editKey(ch, code)
  if code == K.f2 then return act("save") end
  if code == K.f5 then return act("done") end
  local F, o = fields()
  if focus == 0 then
    local d = (code == K.up and -1) or (code == K.down and 1) or (code == K.pgup and -10)
      or (code == K.pgdn and 10)
    if d then sel = max(1, min(#rows, sel + d))
    elseif code == K.enter or code == K.nenter or code == K.tab or code == K.right then setFocus(1)
    elseif code == K.del then return act("del")
    elseif code == K.ins then return act("item") end
    return
  end
  local f = F[focus]
  local key = f[1]
  local v = o[key] or ""
  if code == K.tab or code == K.enter or code == K.nenter or code == K.down then return setFocus(focus + 1) end
  if code == K.up then return setFocus(focus - 1) end
  if type(f[3]) == "table" then
    local opts, idx = f[3], 1
    for i, s in ipairs(opts) do if s == v then idx = i end end
    if code == K.left then idx = idx - 1
    elseif code == K.right or ch == 32 then idx = idx + 1
    else return end
    o[key] = opts[(idx - 1) % #opts + 1]
    M.dirty = true
    if key == "color" or key == "show" then drawRow(sel) end
    return
  end
  if code == K.left then cur = max(0, cur - 1)
  elseif code == K.right then cur = min(ulen(v), cur + 1)
  elseif code == K.home then cur = 0
  elseif code == K["end"] then cur = ulen(v)
  elseif code == K.back then
    if cur > 0 then o[key] = usub(v, 1, cur - 1) .. usub(v, cur + 1) cur = cur - 1 M.dirty = true end
  elseif code == K.del then
    o[key] = usub(v, 1, cur) .. usub(v, cur + 2) M.dirty = true
  elseif ch >= 32 and ch ~= 127 then
    insertText(M.uchar(ch))
  end
end

local function editTouch(x, y, button)
  if y == EH - 1 then
    for _, b in ipairs(BTN) do
      if b.x1 and x >= b.x1 and x <= b.x2 then return act(b[2]) end
    end
  elseif y >= 2 and y <= EH - 2 then
    if x <= LW then
      local i = y - 1 + lscroll
      if rows[i] then sel, focus = i, 0 end
    elseif x >= BX then
      local F, o = fields()
      local i = floor((y - 4) / STEP) + 1
      if y >= 4 and (y - 4) % STEP == 0 and F[i] then
        if focus ~= i then setFocus(i) end
        if type(F[i][3]) == "table" then editKey(0, button == 1 and K.left or K.right)
        else cur = min(ulen(o[F[i][1]] or ""), off + x - BX) end
      end
    end
  end
end

local function runEditor()
  M.applyRes(true)
  W, H = M.W, M.H
  EW, EH = W, H
  LW = min(34, floor(EW * 0.4))
  FX = LW + 3
  BX = FX + 12
  BW = EW - BX
  sel, focus, msg, armed, lscroll = 1, 0, "", false, 0
  buildRows()
  drawEditor()
  while true do
    local id, _, a, b, c = event.pull()
    if id == "key_down" or id == "touch" or id == "scroll" or id == "clipboard" or id == "interrupted" then
      local psel, pfoc, res = sel, focus, nil
      wasArmed, armed, msg = armed, false, ""
      if id == "key_down" then res = editKey(a, b)
      elseif id == "touch" then res = editTouch(a, b, c)
      elseif id == "scroll" then if a <= LW then sel, focus = max(1, min(#rows, sel - c)), 0 end
      elseif id == "clipboard" then insertText(a)
      else res = "done" end
      if res == "done" then break end
      if redraw then redraw = false drawEditor()
      else
        if psel ~= sel or pfoc ~= focus then drawList() drawForm()
        else
          if focus > 0 then drawField(focus) end
          drawRow(sel)
        end
        drawStatus()
      end
    end
  end
  redraw = false
end

runEditor()
