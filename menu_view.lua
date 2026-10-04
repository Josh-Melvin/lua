-- MENU BOARD viewer part (loaded by menu.lua). Returns "edit" or "quit".
-- Also holds the starting menu, used only when no data file exists yet.
local M, what = ...

-- default menu (matches the photographed board), used only on first run -----
local function I(num, name, price, cal, mprice, mcal, desc, badge)
  return {k = "item", num = num, name = name, price = price, cal = cal,
          mprice = mprice, mcal = mcal, desc = desc, badge = badge}
end
local function Hd(text, style, align) return {k = "head", text = text, style = style or "line", align = align} end
local function P(text, style, align) return {k = "para", text = text, style = style or "fine", align = align} end
local function S(title, color, items, style) return {title = title, color = color, style = style, items = items} end

local function defaults()
  return {
    title = "McDonald's", sub = "Menu", cur = "", secs = "12", cols = "auto",
    dots = "yes", res = "max", pin = "",
    footer = "2,000 calories a day is used for general nutrition advice, but calorie needs vary. Additional nutrition information is available upon request.",
    sections = {
      S("Combo Meals", "red", {
        P("Meals include medium fries or side salad and medium soft drink. Pick a different drink or side for an additional charge. Promotion pricing may be lower than meal pricing."),
        I("1", "Big Mac", "5.39", "540", "9.29", "560-1140"),
        I("2", "Quarter Pounder with Cheese", "5.69", "510", "9.59", "530-1110"),
        I("", "Quarter Pounder with Cheese Bacon", "6.79", "610", "10.59", "630-1210"),
        I("", "Quarter Pounder Deluxe", "6.49", "620", "10.19", "640-1220"),
        I("3", "Double Quarter Pounder with Cheese", "6.89", "720", "10.69", "740-1320"),
        I("4", "Buttermilk Crispy Chicken", "5.59", "600", "9.49", "620-1200"),
        I("5", "Artisan Grilled Chicken", "5.69", "440", "9.59", "460-1040"),
        I("6", "10 pc. Chicken McNuggets", "5.79", "420", "9.19", "440-1020"),
        I("7", "Filet-O-Fish", "4.99", "380", "8.59", "400-980"),
        I("8", "4 pc. Buttermilk Crispy Tenders", "4.79", "480", "8.09", "500-1080"),
        I("9", "2 Cheeseburgers", "2.98", "600", "6.69", "620-1200"),
      }),
      S("Fries, Sides & More", "blue", {
        I("", "McDouble", "1.99", "380"),
        I("", "Soft Drinks", "1.00", "0-280"),
        I("", "Fries", "2.99", "320"),
        I("", "20 pc. McNuggets", "7.99", "830", nil, nil, "Serves 2. Calories per serving."),
        I("", "Hash Browns", "2.29", "150"),
        I("", "Sweet Tea", "1.00", "200"),
      }),
      S("Sweets & Treats", "purple", {
        I("", "Shakes", nil, nil, nil, nil, nil, "BACK SOON"),
        I("", "OREO McFlurry", nil, nil, nil, nil, nil, "BACK SOON"),
        I("", "Snickerdoodle McFlurry", nil, nil, nil, nil, nil, "BACK SOON"),
        I("", "Hot Fudge Sundae", nil, nil, nil, nil, nil, "BACK SOON"),
      }),
      S("All Day Breakfast", "yellow", {
        I("", "Egg McMuffin", "4.49", "300"),
        I("", "Sausage McMuffin with Egg", "4.49", "480"),
        I("", "Sausage McMuffin", "1.99", "400"),
      }),
      S("Featured Burger", "orange", {
        I("", "Bacon BBQ Burger", "6.09", "710", "9.89", "730-1310"),
        I("", "Double Bacon BBQ Burger", "7.29", "920", "11.09", "940-1520"),
      }),
      S("McCafé", "brown", {
        I("", "Premium Roast Coffee", "1.99", "0"),
        I("", "Iced Caramel Macchiato*", "3.39", "250"),
        I("", "Frappé", "3.99", "510", nil, nil, "Mocha or Caramel"),
        I("", "Smoothie", "3.49", "240", nil, nil, "Strawberry Banana"),
        I("", "Mocha*", "3.29", "380"),
        I("", "Pies", "1.19", "250", nil, nil, "Apple"),
        P("*With whole milk. Nonfat milk subtract 30-150 Cal."),
      }),
      S("Happy Meal", "red", {
        Hd("Choose a meal (with kids fries)"),
        I("", "4 pc. Chicken McNuggets", "4.49", "295-425", nil, nil, "Sauces add 30-110 Cal. ea."),
        I("", "6 pc. Chicken McNuggets", "", "375-505", nil, nil, "Sauces add 30-110 Cal. ea."),
        I("", "Hamburger", "3.99", "375-505"),
        Hd("Choose a side"),
        I("", "Apple Slices"), I("", "Go-GURT"),
        Hd("Choose a drink"),
        I("", "Honest Kids Organic Apple Juice Drink"), I("", "White Milk"), I("", "DASANI Water"),
        P("Additional charges may apply."),
      }),
      S("$1 $2 $3 Dollar Menu", "green", {
        Hd("$1", "bar"),
        I("", "Any Size Soft Drink", "", "0-220/0-280/0-350"),
        I("", "Any Size Sweet Tea", "", "170/200/280"),
        Hd("$2", "bar"),
        I("", "6 pc. McNuggets", "", "250"),
        Hd("$3", "bar"),
        I("", "2 McDouble Burgers", "", "760"),
      }),
      S("Food Allergy?", "gray", {
        P("Ask a crew member before ordering", "alert", "center"),
        P("Any of our products may contain or come in contact with egg, fish, milk, peanuts, shellfish, soy, tree nuts and wheat.", "body"),
      }, "line"),
    },
  }
end

if what == "defaults" then return defaults() end

local event, computer = require("event"), require("computer")
local put, fill, wrap, alignX, yes = M.put, M.fill, M.wrap, M.alignX, M.yes
local ulen, usub, CMAP, K, menu = M.ulen, M.usub, M.CMAP, M.K, M.menu
local floor, max, min, rep = math.floor, math.max, math.min, string.rep
local BG, PANEL, WHITE, LIGHT, GRAY, YELLOW, RED = 0, 1, 2, 3, 4, 5, 6
local ORANGE, CYAN, FIELD = 10, 12, 14
local W, H = M.W, M.H

local function ink(c) return (c == YELLOW or c == ORANGE or c == CYAN) and BG or WHITE end
local function money(p)
  p = p or ""
  if p ~= "" and p:match("^[%d%.,]+$") then return (menu.cur or "") .. p end
  return p
end
local function cals(c)
  c = c or ""
  if c == "" or c:find("%a") then return c end
  return c .. " Cal."
end

-- element renderers (in measure mode they only count rows) ----------------
local PSTY = {body = {LIGHT}, fine = {GRAY}, accent = {YELLOW}, alert = {WHITE, RED}}

local function drawItem(e, x, y, w, ind)
  local price, badge = money(e.price), e.badge or ""
  local right, rf, rb = price, YELLOW, BG
  if price == "" and badge ~= "" then right, rf, rb, badge = " " .. badge .. " ", WHITE, RED, "" end
  local rw, nx = ulen(right), x + ind
  local nw = w - ind - (rw > 0 and rw + 1 or 0)
  if nw < 6 then nw = w - ind end
  local rows = wrap(e.name, nw, function(s, i)
    local yy = y + i - 1
    if i == 1 then
      if (e.num or "") ~= "" then put(x, yy, e.num, YELLOW) end
      put(nx, yy, s, WHITE)
      if rw > 0 then
        local rx = x + w - rw
        local gap = rx - nx - ulen(s)
        if gap >= 3 and yes(menu.dots) then put(nx + ulen(s), yy, " " .. rep(".", gap - 2) .. " ", GRAY) end
        put(rx, yy, right, rf, rb)
      end
    else
      put(nx, yy, s, WHITE)
    end
  end)
  local yy = y + rows
  if (e.desc or "") ~= "" then
    yy = yy + wrap(e.desc, w - ind, function(s, i) put(nx, yy + i - 1, s, LIGHT) end)
  end
  local c, mp = cals(e.cal), money(e.mprice)
  if badge ~= "" or c ~= "" or mp ~= "" then
    local cx = nx
    if badge ~= "" then put(cx, yy, " " .. badge .. " ", WHITE, RED) cx = cx + ulen(badge) + 3 end
    if c ~= "" then put(cx, yy, c, GRAY) cx = cx + ulen(c) + 2 end
    if mp ~= "" then
      local mc = cals(e.mcal)
      local tail = mc ~= "" and (" | " .. mc) or ""
      local mx = x + w - (5 + ulen(mp) + ulen(tail))
      if mx < cx then
        if cx > nx then yy = yy + 1 end
        mx = nx
      end
      put(mx, yy, "Meal ", GRAY)
      put(mx + 5, yy, mp, YELLOW)
      put(mx + 5 + ulen(mp), yy, tail, GRAY)
    end
    yy = yy + 1
  end
  return yy - y
end

local function drawHead(e, x, y, w, sc)
  local st = e.style
  return wrap(e.text, w, function(s, i)
    local yy, L = y + i - 1, ulen(s)
    local sx = alignX(x, w, s, e.align)
    if st == "bar" then
      fill(x, yy, w, 1, sc)
      put(e.align == "center" and sx or x + 1, yy, s, ink(sc), sc)
    elseif st == "line" then
      if sx > x + 1 then put(x, yy, rep("─", sx - x - 1), sc) end
      put(sx, yy, s, YELLOW)
      if x + w - sx - L - 1 > 0 then put(sx + L + 1, yy, rep("─", x + w - sx - L - 1), sc) end
    else
      put(sx, yy, s, YELLOW)
    end
  end)
end

local function drawPara(e, x, y, w)
  local st = PSTY[e.style] or PSTY.body
  local box = st[2]
  local ix, iw = box and x + 1 or x, box and w - 2 or w
  return wrap(e.text, iw, function(s, i)
    if box then fill(x, y + i - 1, w, 1, box) end
    put(alignX(ix, iw, s, e.align), y + i - 1, s, st[1], box)
  end)
end

local function drawEl(e, x, y, w, ind, sc)
  if e.k == "head" then return drawHead(e, x, y, w, sc) end
  if e.k == "para" then return drawPara(e, x, y, w) end
  return drawItem(e, x, y, w, ind)
end

local function drawSec(sec, x, y, w, cont)
  local sc = CMAP[sec.color] or RED
  local t = usub((sec.title or "") .. (cont and " (cont.)" or ""), 1, w - 2)
  if sec.style == "line" then
    local L = ulen(t)
    put(x, y, t, sc == GRAY and LIGHT or sc)
    if w - L - 1 > 0 then put(x + L + 1, y, rep("━", w - L - 1), sc) end
  else
    fill(x, y, w, 1, sc)
    put(x + 1, y, t, ink(sc), sc)
  end
end

-- layout: plan is a flat number list, 6 numbers per placed block ----------
-- page, column, row, section, element (0 header, -1 "cont." header), indent
local plan, pages, page, colW, nCols = {}, 1, 1, 40, 2
local top, bottom, bannerH, footRows = 1, 25, 1, 0

local function numInd(sec)
  local m = 0
  for _, e in ipairs(sec.items) do
    if e.k == "item" and yes(e.show) then m = max(m, ulen(e.num or "")) end
  end
  return m > 0 and m + 1 or 0
end

local function flow()
  colW = floor((W - 2 - (nCols - 1) * 2) / nCols)
  plan, pages = {}, 1
  M.mode(false)
  local col, y, n = 1, top, 0
  local function add(si, ei, ind)
    plan[n + 1], plan[n + 2], plan[n + 3], plan[n + 4], plan[n + 5], plan[n + 6] = pages, col, y, si, ei, ind
    n = n + 6
  end
  local function newCol()
    col = col + 1
    if col > nCols then col, pages = 1, pages + 1 end
    y = top
  end
  for si, sec in ipairs(menu.sections) do
    if yes(sec.show) then
      local ind, vis = numInd(sec), {}
      for ei, e in ipairs(sec.items) do if yes(e.show) then vis[#vis + 1] = ei end end
      local fh = vis[1] and drawEl(sec.items[vis[1]], 1, 1, colW, ind, RED) or 0
      if y > top and y + fh > bottom then newCol() end
      add(si, 0, ind)
      y = y + 1
      for k, ei in ipairs(vis) do
        local e = sec.items[ei]
        local h = drawEl(e, 1, 1, colW, ind, RED)
        local need = h -- keep a header together with the line after it
        if e.k == "head" and vis[k + 1] then need = h + drawEl(sec.items[vis[k + 1]], 1, 1, colW, ind, RED) end
        if k > 1 and y + need - 1 > bottom then
          newCol()
          add(si, -1, ind)
          y = y + 1
        end
        add(si, ei, ind)
        y = y + h
      end
      y = y + 1
    end
  end
  M.mode(true)
end

local function layout() -- "auto" = fewest columns that still need the fewest pages
  bannerH = ((menu.title or "") .. (menu.sub or "")) ~= "" and (H >= 40 and 3 or 1) or 0
  footRows = (menu.footer or "") ~= "" and min(2, wrap(menu.footer, W - 2)) or 0
  top = bannerH > 0 and bannerH + 2 or 1
  bottom = H - (footRows > 0 and footRows + 1 or 0)
  local fixed = tonumber(menu.cols)
  if fixed then nCols = max(1, min(6, fixed)) flow()
  else
    nCols = max(1, min(4, floor((W + 2) / 40)))
    flow()
    local best = pages
    while nCols > 1 do
      nCols = nCols - 1
      flow()
      if pages > best then nCols = nCols + 1 flow() break end
    end
  end
  if page > pages then page = 1 end
end

local function render()
  M.reset()
  fill(1, 1, W, H, BG)
  if bannerH > 0 then
    fill(1, 1, W, bannerH, RED)
    local t, s = menu.title or "", menu.sub or ""
    local full = t .. (s ~= "" and ("  " .. s) or "")
    local tx, ty = max(1, floor((W - ulen(full)) / 2) + 1), floor((bannerH + 1) / 2)
    put(tx, ty, t, YELLOW, RED)
    if s ~= "" then put(tx + ulen(t) + 2, ty, s, WHITE, RED) end
    if pages > 1 then
      local p = page .. "/" .. pages
      put(W - ulen(p), ty, p, WHITE, RED)
    end
  end
  M.mode(true, bottom)
  for i = 1, #plan, 6 do
    if plan[i] == page then
      local sec, ei = menu.sections[plan[i + 3]], plan[i + 4]
      local x = 2 + (plan[i + 1] - 1) * (colW + 2)
      if ei <= 0 then drawSec(sec, x, plan[i + 2], colW, ei < 0)
      else drawEl(sec.items[ei], x, plan[i + 2], colW, plan[i + 5], CMAP[sec.color] or RED) end
    end
  end
  M.mode(true)
  if footRows > 0 then
    wrap(menu.footer, W - 2, function(s, i)
      if i <= footRows then put(alignX(2, W - 2, s, "center"), H - footRows + i, s, GRAY) end
    end)
  end
end

local function askPin()
  if (menu.pin or "") == "" then return true end
  local bw = min(W - 2, 30)
  local x, y = floor((W - bw) / 2) + 1, floor(H / 2) - 1
  fill(x, y, bw, 4, PANEL)
  put(x + 2, y + 1, "Staff PIN, then Enter:", YELLOW, PANEL)
  local s = ""
  while true do
    fill(x + 2, y + 2, bw - 4, 1, FIELD)
    put(x + 2, y + 2, rep("*", #s), WHITE, FIELD)
    local id, _, ch, code = event.pull(20, "key_down")
    if not id or code == K.enter or code == K.nenter then break end
    if code == K.back then s = s:sub(1, -2)
    elseif ch >= 32 and ch < 127 then s = s .. string.char(ch) end
  end
  return s == menu.pin
end

M.applyRes(false)
W, H = M.W, M.H
layout()
render()
local secs = max(3, tonumber(menu.secs) or 12)
local deadline = computer.uptime() + secs
while true do
  local id, _, a, b = event.pull(pages > 1 and max(0, deadline - computer.uptime()) or nil)
  local turn
  if id == nil then turn = 1
  elseif id == "touch" then turn = (a > W / 2) and 1 or -1
  elseif id == "key_down" then
    if b == K.right or b == K.pgdn then turn = 1
    elseif b == K.left or b == K.pgup then turn = -1
    elseif a == 101 or a == 69 then if askPin() then return "edit" end render()
    elseif a == 113 or a == 81 then if askPin() then return "quit" end render() end
  elseif id == "screen_resized" and (a ~= W or b ~= H) then
    W, H = a, b M.W, M.H = a, b layout() render()
  elseif id == "interrupted" then return "quit" end
  if turn then
    if pages > 1 then page = (page - 1 + turn) % pages + 1 render() end
    deadline = computer.uptime() + secs
  end
end
