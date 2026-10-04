--[[
  MENUBOARD - editable fast-food menu board for OpenComputers (OpenOS)
  ======================================================================
  * Full-screen menu: big block-letter title banner, Heading 1/2/3,
    paragraphs, note boxes, priced menu items with badges, dividers,
    multi-column layout and automatic page rotation.
  * Built-in editor with form fields for every block, a style editor
    (colors, alignment, decorations, spacing) and live previews.
  * Data is saved to /home/menu.dat and survives reboots.

  Needs: OpenOS, GPU + screen (Tier 3 recommended), keyboard on screen.

  Usage:
    menuboard              show the menu
    menuboard -e           start in the editor
    menuboard <file>       use another data file (e.g. /home/drinks.dat)

  On the display:  E = edit   Q = quit   arrows / click = change page
]]

local component     = require("component")
local computer      = require("computer")
local event         = require("event")
local filesystem    = require("filesystem")
local keyboard      = require("keyboard")
local serialization = require("serialization")
local shell         = require("shell")
local term          = require("term")
local unicode       = require("unicode")

if not (component.isAvailable("gpu") and component.isAvailable("screen")) then
  io.stderr:write("menuboard: a graphics card and a screen are required\n")
  return
end

local gpu = component.gpu
local K = keyboard.keys
local ulen, usub = unicode.len, unicode.sub

local cliArgs, cliOpts = shell.parse(...)
local DATA_FILE = shell.resolve(cliArgs[1] or "/home/menu.dat")

---------------------------------------------------------------------------
-- Colors (stored by name in the data file)
---------------------------------------------------------------------------
local COLOR_LIST = {
  { "Black", 0x000000 }, { "White", 0xFFFFFF }, { "Light Gray", 0xC3C3C3 },
  { "Gray", 0x878787 }, { "Dark Gray", 0x3C3C3C }, { "Red", 0xFF3333 },
  { "Dark Red", 0x990000 }, { "Maroon", 0x4D0000 }, { "Orange", 0xFF8C1A },
  { "Yellow", 0xFFDB00 }, { "Gold", 0xCC9900 }, { "Cream", 0xFFF2CC },
  { "Brown", 0x804D1A }, { "Lime", 0x99FF33 }, { "Green", 0x2DA02D },
  { "Dark Green", 0x0F4D0F }, { "Cyan", 0x33CCFF }, { "Blue", 0x3366FF },
  { "Navy", 0x0A1A4D }, { "Purple", 0x9933FF }, { "Magenta", 0xFF33CC },
  { "Pink", 0xFF99B4 },
}
local COLOR_NAMES, COLOR_MAP = {}, {}
for _, c in ipairs(COLOR_LIST) do
  COLOR_NAMES[#COLOR_NAMES + 1] = c[1]
  COLOR_MAP[c[1]] = c[2]
end
local BG_NAMES = { "None" }
for _, name in ipairs(COLOR_NAMES) do BG_NAMES[#BG_NAMES + 1] = name end

-- Resolve a color name ("Yellow"), "#RRGGBB" or number. "None" -> fallback.
local function col(name, fallback)
  if name == nil or name == "None" then return fallback end
  if type(name) == "number" then return name end
  if COLOR_MAP[name] then return COLOR_MAP[name] end
  local hex = tostring(name):match("^#?(%x%x%x%x%x%x)$")
  return hex and tonumber(hex, 16) or fallback
end

---------------------------------------------------------------------------
-- Text helpers
---------------------------------------------------------------------------
local function deepcopy(t)
  if type(t) ~= "table" then return t end
  local r = {}
  for k, v in pairs(t) do r[k] = deepcopy(v) end
  return r
end

local function trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function clip(s, w)
  s = tostring(s or "")
  if w <= 0 then return "" end
  if ulen(s) <= w then return s end
  if w == 1 then return usub(s, 1, 1) end
  return usub(s, 1, w - 1) .. "…"
end

local function alignOffset(len, width, align)
  if align == "center" then return math.max(0, math.floor((width - len) / 2)) end
  if align == "right" then return math.max(0, width - len) end
  return 0
end

-- Word wrap. A typed "\n" (backslash + n) forces a new line.
local function wrap(text, width)
  width = math.max(1, width)
  text = tostring(text or ""):gsub("\\n", "\n")
  local out = {}
  for para in (text .. "\n"):gmatch("(.-)\n") do
    para = para:gsub("%s+$", "")
    if ulen(para) <= width then
      out[#out + 1] = para -- fits: keep the spacing exactly as typed
    else
      local line = ""
      for word in para:gmatch("%S+") do
        while ulen(word) > width do
          if line ~= "" then out[#out + 1] = line; line = "" end
          out[#out + 1] = usub(word, 1, width)
          word = usub(word, width + 1)
        end
        if line == "" then
          line = word
        elseif ulen(line) + 1 + ulen(word) <= width then
          line = line .. " " .. word
        else
          out[#out + 1] = line
          line = word
        end
      end
      out[#out + 1] = line
    end
  end
  return out
end

-- "4.99" -> "$4.99"; anything that is not a plain number is shown as typed.
local function formatPrice(p, settings)
  p = trim(p)
  if p == "" then return "" end
  local n = tonumber(p)
  if n then
    if p:find("%.") then p = string.format("%.2f", n) end
    local cur = settings.currency or ""
    if settings.currencyPos == "after" then return p .. cur end
    return cur .. p
  end
  return p
end

---------------------------------------------------------------------------
-- Block types
---------------------------------------------------------------------------
local TYPES = {
  item      = { label = "Menu item",    short = "ITEM",  color = 0xFFFFFF, desc = "name, price, description, badge" },
  h1        = { label = "Heading 1",    short = "H1",    color = 0xFFDB00, desc = "big headline in block letters" },
  h2        = { label = "Heading 2",    short = "H2",    color = 0xFFDB00, desc = "section header, e.g. BURGERS" },
  h3        = { label = "Heading 3",    short = "H3",    color = 0xFF8C1A, desc = "small sub-header" },
  paragraph = { label = "Paragraph",    short = "TEXT",  color = 0xC3C3C3, desc = "wrapped body text" },
  note      = { label = "Note box",     short = "NOTE",  color = 0x33CCFF, desc = "highlighted callout text" },
  divider   = { label = "Divider",      short = "LINE",  color = 0x878787, desc = "horizontal line" },
  spacer    = { label = "Spacer",       short = "GAP",   color = 0x878787, desc = "one empty line" },
  colbreak  = { label = "Column break", short = "BREAK", color = 0xFF99B4, desc = "continue in the next column/page" },
}
local UNKNOWN_TYPE = { label = "Unknown", short = "?", color = 0xFF3333, desc = "" }
local TYPE_ORDER = { "item", "h2", "h3", "h1", "paragraph", "note", "divider", "spacer", "colbreak" }
local TEXT_TYPES = { "h1", "h2", "h3", "paragraph", "note" }
local TEXT_SET, TYPE_LABELS = {}, {}
for _, t in ipairs(TEXT_TYPES) do TEXT_SET[t] = true end
for k, v in pairs(TYPES) do TYPE_LABELS[k] = v.label end

local function typeInfo(t) return TYPES[t] or UNKNOWN_TYPE end
local function isHeading(t) return t == "h1" or t == "h2" or t == "h3" end

---------------------------------------------------------------------------
-- Default menu (used on first start and to fill in missing settings)
---------------------------------------------------------------------------
local DEFAULT_MENU = {
  settings = {
    title = "Burger Block",
    subtitle = "Fresh  *  Fast  *  Tasty",
    footer = "Open daily  *  Combos come with fries & a drink  *  Ask us about allergens",
    currency = "$", currencyPos = "before",
    columns = 2, colLines = true, background = "Black",
    width = 0, height = 0, pageSeconds = 10, pin = "",
  },
  styles = {
    banner    = { fg = "Yellow", bg = "Dark Red", subFg = "White", size = "auto", align = "center" },
    h1        = { fg = "Yellow", bg = "None", align = "center", decor = "plain", lineFg = "Orange", big = true, upper = true, space = 1 },
    h2        = { fg = "Black", bg = "Yellow", align = "left", decor = "bar", lineFg = "Yellow", big = false, upper = true, space = 1 },
    h3        = { fg = "Orange", bg = "None", align = "left", decor = "underline", lineFg = "Dark Gray", big = false, upper = false, space = 1 },
    paragraph = { fg = "Light Gray", bg = "None", align = "left", indent = 0, padding = false, space = 0 },
    note      = { fg = "Black", bg = "Cream", align = "center", indent = 1, padding = true, space = 1 },
    item      = { nameFg = "White", priceFg = "Yellow", descFg = "Gray", leader = ".", leaderFg = "Dark Gray",
                  tagFg = "Black", tagBg = "Lime", soldFg = "Red", upper = false, descIndent = 2, space = 0 },
    divider   = { fg = "Dark Gray", char = "─", space = 0 },
    footer    = { fg = "Black", bg = "Yellow", align = "center" },
  },
  blocks = {
    { type = "h2", text = "Burgers" },
    { type = "item", name = "Classic Burger", price = "4.99", desc = "Beef patty, lettuce, tomato, house sauce" },
    { type = "item", name = "Double Cheese", price = "6.49", desc = "Two patties, double cheddar, pickles", tag = "BEST" },
    { type = "item", name = "Creeper Crunch", price = "5.99", desc = "Crispy chicken, green pepper relish", tag = "NEW" },
    { type = "item", name = "Veggie Melt", price = "5.49", desc = "Grilled mushroom & beetroot patty" },
    { type = "h2", text = "Sides" },
    { type = "item", name = "Fries", price = "1.99", desc = "Large +0.80" },
    { type = "item", name = "Onion Rings", price = "2.49" },
    { type = "item", name = "Nuggets (6 pc)", price = "3.29", soldOut = true },
    { type = "h3", text = "Dipping sauces" },
    { type = "paragraph", text = "Ketchup, mustard, BBQ or spicy mayo. One free with every side!" },
    { type = "colbreak" },
    { type = "h2", text = "Drinks" },
    { type = "item", name = "Soda", price = "1.49", desc = "Cola, lemon-lime or orange" },
    { type = "item", name = "Iced Tea", price = "1.29" },
    { type = "item", name = "Milkshake", price = "3.49", desc = "Vanilla, chocolate or strawberry" },
    { type = "h2", text = "Combos" },
    { type = "item", name = "Burger Combo", price = "7.99", desc = "Any burger + fries + soda", tag = "DEAL" },
    { type = "item", name = "Family Box", price = "2 for $15", desc = "2 burgers, 2 fries, 2 drinks, nuggets" },
    { type = "divider" },
    { type = "note", text = "Upgrade any combo to a milkshake for $1.50" },
  },
}

local function mergeDefaults(t, d)
  for k, v in pairs(d) do
    if t[k] == nil then
      t[k] = deepcopy(v)
    elseif type(v) == "table" and type(t[k]) == "table" and k ~= "blocks" then
      mergeDefaults(t[k], v)
    end
  end
  return t
end

local function loadMenu()
  local f = io.open(DATA_FILE, "r")
  if f then
    local s = f:read("*a")
    f:close()
    local ok, t = pcall(serialization.unserialize, s)
    if ok and type(t) == "table" then return mergeDefaults(t, DEFAULT_MENU), true end
  end
  return deepcopy(DEFAULT_MENU), false
end

local function saveMenu(m)
  local dir = filesystem.path(DATA_FILE)
  if dir and dir ~= "" and not filesystem.exists(dir) then filesystem.makeDirectory(dir) end
  local f, err = io.open(DATA_FILE, "w")
  if not f then return false, err end
  f:write(serialization.serialize(m))
  f:close()
  return true
end

---------------------------------------------------------------------------
-- GPU drawing (with a color cache so we don't waste GPU calls)
---------------------------------------------------------------------------
local curFg, curBg
local function resetColors() curFg, curBg = nil, nil end
local function setFg(c) if c ~= curFg then gpu.setForeground(c); curFg = c end end
local function setBg(c) if c ~= curBg then gpu.setBackground(c); curBg = c end end

local function put(x, y, s, fg, bg)
  if s == nil or s == "" then return end
  setBg(bg); setFg(fg)
  gpu.set(x, y, s)
end

local function fill(x, y, w, h, bg, ch, fg)
  if w < 1 or h < 1 then return end
  setBg(bg)
  if fg then setFg(fg) end
  gpu.fill(x, y, w, h, ch or " ")
end

-- Draw off-screen into a video buffer when the GPU supports it (no flicker,
-- much faster), otherwise straight to the screen.
local function buffered(drawFn)
  local W, H = gpu.getResolution()
  if gpu.allocateBuffer then
    local ok, buf = pcall(gpu.allocateBuffer, W, H)
    if ok and buf then
      gpu.setActiveBuffer(buf)
      resetColors()
      local ok2, err = pcall(drawFn)
      gpu.setActiveBuffer(0)
      if ok2 then gpu.bitblt(0, 1, 1, W, H, buf, 1, 1) end
      gpu.freeBuffer(buf)
      resetColors()
      if not ok2 then error(err, 0) end
      return
    end
  end
  drawFn()
end

---------------------------------------------------------------------------
-- 3x5 block font for big titles (each digit = one row, bits 4/2/1 = columns)
---------------------------------------------------------------------------
local FONT = {
  A = "25755", B = "65656", C = "34443", D = "65556", E = "74647", F = "74644",
  G = "34553", H = "55755", I = "72227", J = "11152", K = "55655", L = "44447",
  M = "57755", N = "65555", O = "25552", P = "65644", Q = "25563", R = "65655",
  S = "34216", T = "72222", U = "55557", V = "55552", W = "55775", X = "55255",
  Y = "55222", Z = "71247",
  ["0"] = "75557", ["1"] = "26227", ["2"] = "61247", ["3"] = "61216", ["4"] = "55711",
  ["5"] = "74616", ["6"] = "34757", ["7"] = "71222", ["8"] = "75757", ["9"] = "75716",
  [" "] = "00000", ["!"] = "22202", ["."] = "00002", [","] = "00024", ["-"] = "00700",
  ["'"] = "22000", ["&"] = "25253", ["$"] = "36236", ["?"] = "61202", [":"] = "02020",
  ["/"] = "11244", ["+"] = "02720", ["*"] = "05250", ["%"] = "51245", ["("] = "12221",
  [")"] = "42224", ["="] = "07070",
}
local BITS = { 4, 2, 1 }

local function bigTextWidth(s, scale)
  local n = ulen(s)
  if n == 0 then return 0 end
  return (n * 4 - 1) * scale
end

-- Returns screen lines built from half-block characters (▀ ▄ █).
local function bigText(s, scale)
  scale = scale or 1
  s = s:upper()
  local n = ulen(s)
  local grid = {}
  for r = 1, 5 * scale do grid[r] = {} end
  for i = 1, n do
    local glyph = FONT[usub(s, i, i)] or FONT["?"]
    for r = 1, 5 do
      local v = tonumber(glyph:sub(r, r))
      for _, bit in ipairs(BITS) do
        local on = math.floor(v / bit) % 2 == 1
        for sy = 1, scale do
          local row = grid[(r - 1) * scale + sy]
          for _ = 1, scale do row[#row + 1] = on end
        end
      end
    end
    if i < n then
      for r = 1, 5 * scale do
        local row = grid[r]
        for _ = 1, scale do row[#row + 1] = false end
      end
    end
  end
  local lines = {}
  for r = 1, 5 * scale, 2 do
    local top, bot, buf = grid[r], grid[r + 1], {}
    for x = 1, #top do
      local t, b = top[x], bot and bot[x]
      buf[x] = (t and b) and "█" or t and "▀" or b and "▄" or " "
    end
    lines[#lines + 1] = table.concat(buf)
  end
  return lines
end

---------------------------------------------------------------------------
-- Layout: every block is turned into "lines" of colored segments
---------------------------------------------------------------------------
local function mkLine(fillColor, margin) return { segs = {}, fill = fillColor, margin = margin } end
local function seg(line, x, text, fg, bg) line.segs[#line.segs + 1] = { x = x, text = text, fg = fg, bg = bg } end
local function blankLines(lines, n) for _ = 1, tonumber(n) or 0 do lines[#lines + 1] = mkLine(nil, true) end end
local function blockAlign(b, st)
  if b.align and b.align ~= "style" then return b.align end
  return st.align or "left"
end

local function headingLines(b, st, w, pageBg)
  local lines = {}
  local text = trim(b.text)
  if text == "" then return lines end
  blankLines(lines, st.space)
  if st.upper then text = text:upper() end
  local fg = col(st.fg, 0xFFFFFF)
  local bgSet = st.bg ~= nil and st.bg ~= "None"
  local bg = col(st.bg, pageBg)
  local lineFg = col(st.lineFg, fg)
  local align = blockAlign(b, st)
  local decor = st.decor or "plain"
  if decor == "bar" and not bgSet then bg, bgSet = lineFg, true end
  local fillBg = bgSet and bg or nil

  if st.big and text ~= "" and bigTextWidth(text, 1) <= w then
    local bw = bigTextWidth(text, 1)
    local off = alignOffset(bw, w, align)
    for _, s in ipairs(bigText(text, 1)) do
      local ln = mkLine(fillBg)
      seg(ln, off + 1, s, fg, bg)
      lines[#lines + 1] = ln
    end
    if decor == "underline" or decor == "line" or decor == "box" then
      local ln = mkLine()
      seg(ln, off + 1, string.rep("─", bw), lineFg, pageBg)
      lines[#lines + 1] = ln
    end

  elseif decor == "box" then
    local inner = wrap(text, math.max(1, w - 4))
    local maxL = 0
    for _, s in ipairs(inner) do maxL = math.max(maxL, ulen(s)) end
    local bw = maxL + 4
    local off = alignOffset(bw, w, align)
    local topLn = mkLine()
    seg(topLn, off + 1, "┌" .. string.rep("─", bw - 2) .. "┐", lineFg, pageBg)
    lines[#lines + 1] = topLn
    for _, s in ipairs(inner) do
      local pad = maxL - ulen(s)
      local lp = math.floor(pad / 2)
      local ln = mkLine()
      seg(ln, off + 1, "│", lineFg, pageBg)
      seg(ln, off + 2, string.rep(" ", lp + 1) .. s .. string.rep(" ", pad - lp + 1), fg, bg)
      seg(ln, off + bw, "│", lineFg, pageBg)
      lines[#lines + 1] = ln
    end
    local botLn = mkLine()
    seg(botLn, off + 1, "└" .. string.rep("─", bw - 2) .. "┘", lineFg, pageBg)
    lines[#lines + 1] = botLn

  elseif decor == "line" then
    for _, s in ipairs(wrap(text, math.max(1, w - 6))) do
      local tw = ulen(s) + 2
      local off = alignOffset(tw, w, align)
      if align == "left" then off = math.min(2, math.max(0, w - tw)) end
      if align == "right" then off = math.max(0, w - tw - 2) end
      local ln = mkLine(fillBg)
      if off > 0 then seg(ln, 1, string.rep("─", off), lineFg, bg) end
      seg(ln, off + 1, " " .. s .. " ", fg, bg)
      local rest = w - off - tw
      if rest > 0 then seg(ln, off + tw + 1, string.rep("─", rest), lineFg, bg) end
      lines[#lines + 1] = ln
    end

  else -- plain, bar, underline
    local pad = decor == "bar" and 1 or 0
    local tw = w - pad * 2
    local maxL = 0
    for _, s in ipairs(wrap(text, tw)) do
      local ln = mkLine(fillBg)
      seg(ln, 1 + pad + alignOffset(ulen(s), tw, align), s, fg, bg)
      maxL = math.max(maxL, ulen(s))
      lines[#lines + 1] = ln
    end
    if decor == "underline" and maxL > 0 then
      local ln = mkLine()
      seg(ln, 1 + alignOffset(maxL, w, align), string.rep("─", maxL), lineFg, pageBg)
      lines[#lines + 1] = ln
    end
  end
  return lines
end

local function paragraphLines(b, st, w, pageBg)
  local lines = {}
  if trim(b.text) == "" then return lines end
  blankLines(lines, st.space)
  local fg = col(st.fg, 0xC3C3C3)
  local bgSet = st.bg ~= nil and st.bg ~= "None"
  local bg = col(st.bg, pageBg)
  local fillBg = bgSet and bg or nil
  local ind = tonumber(st.indent) or 0
  local tw = math.max(1, w - ind * 2)
  local align = blockAlign(b, st)
  if st.padding and bgSet then lines[#lines + 1] = mkLine(fillBg) end
  for _, s in ipairs(wrap(b.text, tw)) do
    local ln = mkLine(fillBg)
    seg(ln, 1 + ind + alignOffset(ulen(s), tw, align), s, fg, bg)
    lines[#lines + 1] = ln
  end
  if st.padding and bgSet then lines[#lines + 1] = mkLine(fillBg) end
  return lines
end

local function itemLines(b, m, w, pageBg)
  local st = m.styles.item
  local lines = {}
  blankLines(lines, st.space)
  local nameFg = col(st.nameFg, 0xFFFFFF)
  local priceFg = col(st.priceFg, 0xFFDB00)
  local descFg = col(st.descFg, 0x878787)
  local price = formatPrice(b.price, m.settings)
  if b.soldOut then
    price, priceFg, nameFg = "SOLD OUT", col(st.soldFg, 0xFF3333), descFg
  end
  if ulen(price) > w then price = usub(price, 1, w) end
  local name = trim(b.name)
  if st.upper then name = name:upper() end
  local tag = trim(b.tag)
  tag = tag ~= "" and (" " .. tag .. " ") or ""
  local pw, tw = ulen(price), ulen(tag)

  local nameW = w - (pw > 0 and pw + 2 or 0) - (tw > 0 and tw + 1 or 0)
  if nameW < 4 and tw > 0 then
    tag, tw = "", 0
    nameW = w - (pw > 0 and pw + 2 or 0)
  end
  local priceOwnLine = false
  if nameW < 4 then priceOwnLine, nameW = true, w end

  local nl = wrap(name, nameW)
  for i = 1, #nl - 1 do
    local ln = mkLine()
    seg(ln, 1, nl[i], nameFg, pageBg)
    lines[#lines + 1] = ln
  end
  local last = nl[#nl]
  local ln = mkLine()
  seg(ln, 1, last, nameFg, pageBg)
  local endX = ulen(last)
  if tw > 0 then
    local tx = endX + (endX > 0 and 2 or 1)
    seg(ln, tx, tag, col(st.tagFg, 0x000000), col(st.tagBg, 0x99FF33))
    endX = tx + tw - 1
  end
  if pw > 0 then
    if priceOwnLine then
      lines[#lines + 1] = ln
      ln, endX = mkLine(), 0
    end
    local px = w - pw + 1
    local from, to = endX + 2, px - 2
    local leader = st.leader or "."
    if leader ~= "" and leader ~= " " and to >= from then
      seg(ln, from, string.rep(leader, to - from + 1), col(st.leaderFg, descFg), pageBg)
    end
    seg(ln, px, price, priceFg, pageBg)
  end
  lines[#lines + 1] = ln

  local desc = trim(b.desc)
  if desc ~= "" then
    local ind = tonumber(st.descIndent) or 2
    for _, d in ipairs(wrap(desc, math.max(1, w - ind))) do
      local dl = mkLine()
      seg(dl, 1 + ind, d, descFg, pageBg)
      lines[#lines + 1] = dl
    end
  end
  return lines
end

local function dividerLines(b, m, w, pageBg)
  local st = m.styles.divider
  local lines = {}
  blankLines(lines, st.space)
  local ln = mkLine()
  seg(ln, 1, string.rep(st.char or "─", w), col(st.fg, 0x3C3C3C), pageBg)
  lines[#lines + 1] = ln
  for _ = 1, tonumber(st.space) or 0 do lines[#lines + 1] = mkLine() end
  return lines
end

local LAYOUT = {
  h1        = function(b, m, w, bg) return headingLines(b, m.styles.h1, w, bg) end,
  h2        = function(b, m, w, bg) return headingLines(b, m.styles.h2, w, bg) end,
  h3        = function(b, m, w, bg) return headingLines(b, m.styles.h3, w, bg) end,
  paragraph = function(b, m, w, bg) return paragraphLines(b, m.styles.paragraph, w, bg) end,
  note      = function(b, m, w, bg) return paragraphLines(b, m.styles.note, w, bg) end,
  item      = itemLines,
  divider   = dividerLines,
  spacer    = function() return { mkLine(nil, true) } end,
}

---------------------------------------------------------------------------
-- Page layout: banner, columns, footer, pages
---------------------------------------------------------------------------
local function headerLines(m, W, H, pageBg)
  local s, st = m.settings, m.styles.banner
  local lines = {}
  local title, sub = trim(s.title), trim(s.subtitle)
  if title == "" and sub == "" then return lines end
  local fg, bg, subFg = col(st.fg, 0xFFDB00), col(st.bg, pageBg), col(st.subFg, 0xFFFFFF)
  local align, inner = st.align or "center", W - 4
  local function fits(sc) return title ~= "" and bigTextWidth(title, sc) <= inner end
  local size, scale = st.size or "auto", nil
  if size == "auto" then
    if H >= 36 and fits(2) then scale = 2 elseif H >= 20 and fits(1) then scale = 1 end
  elseif size == "large" then
    scale = fits(2) and 2 or (fits(1) and 1 or nil)
  elseif size == "medium" then
    scale = fits(1) and 1 or nil
  end

  lines[1] = mkLine(bg)
  if title ~= "" then
    if scale then
      local off = 2 + alignOffset(bigTextWidth(title, scale), inner, align)
      for _, t in ipairs(bigText(title, scale)) do
        local ln = mkLine(bg)
        seg(ln, off + 1, t, fg, bg)
        lines[#lines + 1] = ln
      end
      if scale == 2 and sub ~= "" then lines[#lines + 1] = mkLine(bg) end
    else
      local t = title:upper()
      local chars = {}
      for i = 1, ulen(t) do chars[i] = usub(t, i, i) end
      local spaced = table.concat(chars, " ")
      if ulen(spaced) <= inner then t = spaced end
      t = clip(t, inner)
      local ln = mkLine(bg)
      seg(ln, 3 + alignOffset(ulen(t), inner, align), t, fg, bg)
      lines[#lines + 1] = ln
    end
  end
  if sub ~= "" then
    for _, t in ipairs(wrap(sub, inner)) do
      local ln = mkLine(bg)
      seg(ln, 3 + alignOffset(ulen(t), inner, align), t, subFg, bg)
      lines[#lines + 1] = ln
    end
  end
  lines[#lines + 1] = mkLine(bg)
  return lines
end

local function footerLine(m, W, pageText)
  local st = m.styles.footer
  local fg, bg = col(st.fg, 0x000000), col(st.bg, 0xFFDB00)
  local ln = mkLine(bg)
  local pw = pageText and ulen(pageText) or 0
  local avail = W - 2 - (pw > 0 and pw + 2 or 0)
  local text = clip(trim(m.settings.footer), avail)
  seg(ln, 2 + alignOffset(ulen(text), avail, st.align or "center"), text, fg, bg)
  if pw > 0 then seg(ln, W - pw, pageText, fg, bg) end
  return ln
end

local function columnSetup(m, W)
  local n = math.max(1, math.min(4, math.floor(tonumber(m.settings.columns) or 1)))
  local margin = W >= 80 and 2 or 1
  local gutter = W >= 80 and 4 or 3
  local colW = math.floor((W - 2 * margin - (n - 1) * gutter) / n)
  while n > 1 and colW < 24 do
    n = n - 1
    colW = math.floor((W - 2 * margin - (n - 1) * gutter) / n)
  end
  return n, colW, margin, gutter
end

local function displaySize(m)
  local mw, mh = gpu.maxResolution()
  local w, h = tonumber(m.settings.width) or 0, tonumber(m.settings.height) or 0
  if w <= 0 or w > mw then w = mw end
  if h <= 0 or h > mh then h = mh end
  return math.floor(math.max(20, w)), math.floor(math.max(8, h))
end

local function leadingMargins(lines)
  local c = 0
  for _, ln in ipairs(lines) do
    if ln.margin then c = c + 1 else break end
  end
  return c
end

local function buildLayout(m, W, H)
  local pageBg = col(m.settings.background, 0x000000)
  local header = headerLines(m, W, H, pageBg)
  local n, colW, margin, gutter = columnSetup(m, W)

  local order, rendered = {}, {}
  for _, b in ipairs(m.blocks) do
    if not b.hidden then
      order[#order + 1] = b
      local f = LAYOUT[b.type]
      rendered[#order] = f and f(b, m, colW, pageBg) or {}
    end
  end

  local function flow(footerH)
    local bodyH = math.max(1, H - #header - footerH)
    local pages, page, ci, y = {}, nil, 1, 0
    local function newPage()
      page = {}
      for c = 1, n do page[c] = {} end
      pages[#pages + 1] = page
      ci, y = 1, 0
    end
    local function nextCol()
      if ci < n then ci, y = ci + 1, 0 else newPage() end
    end
    newPage()
    for i, b in ipairs(order) do
      if b.type == "colbreak" then
        if y > 0 then nextCol() end
      else
        local lines = rendered[i]
        local body = #lines - leadingMargins(lines)
        local extra = 0 -- keep headings together with the start of the next block
        if isHeading(b.type) and rendered[i + 1] and order[i + 1].type ~= "colbreak" then
          local nx = rendered[i + 1]
          extra = math.min(3, #nx - leadingMargins(nx))
        end
        if y > 0 and y + #lines + extra > bodyH and body + extra <= bodyH then nextCol() end
        for _, ln in ipairs(lines) do
          if y >= bodyH then nextCol() end
          if not (ln.margin and y == 0) then
            local c = page[ci]
            c[#c + 1] = ln
            y = y + 1
          end
        end
      end
    end
    while #pages > 1 do
      local last, empty = pages[#pages], true
      for c = 1, n do if #last[c] > 0 then empty = false end end
      if not empty then break end
      pages[#pages] = nil
    end
    return pages, bodyH
  end

  local hasFooter = trim(m.settings.footer) ~= ""
  local pages, bodyH = flow(hasFooter and 1 or 0)
  if #pages > 1 and not hasFooter then
    hasFooter = true
    pages, bodyH = flow(1)
  end
  return {
    W = W, H = H, pageBg = pageBg, header = header, pages = pages, bodyH = bodyH,
    footer = hasFooter, n = n, colW = colW, margin = margin, gutter = gutter,
  }
end

local function drawLine(ln, x0, y, w)
  if ln.fill then fill(x0, y, w, 1, ln.fill) end
  for _, s in ipairs(ln.segs) do
    local avail = w - s.x + 1
    if avail > 0 and s.text ~= "" then
      local t = s.text
      if ulen(t) > avail then t = usub(t, 1, avail) end
      put(x0 + s.x - 1, y, t, s.fg, s.bg)
    end
  end
end

local function drawPage(L, p, m)
  local W, H = L.W, L.H
  fill(1, 1, W, H, L.pageBg)
  for i, ln in ipairs(L.header) do drawLine(ln, 1, i, W) end
  local top = #L.header + 1
  local page = L.pages[p] or {}
  for c = 1, L.n do
    local x0 = 1 + L.margin + (c - 1) * (L.colW + L.gutter)
    for i, ln in ipairs(page[c] or {}) do drawLine(ln, x0, top + i - 1, L.colW) end
    if m.settings.colLines and c < L.n then
      local sx = x0 + L.colW + math.floor(L.gutter / 2)
      fill(sx, top, 1, L.bodyH, L.pageBg, "│", col(m.styles.divider.fg, 0x3C3C3C))
    end
  end
  if L.footer then
    local pt = #L.pages > 1 and (p .. "/" .. #L.pages) or nil
    drawLine(footerLine(m, W, pt), 1, H, W)
  end
end

---------------------------------------------------------------------------
-- Editor UI theme and widgets
---------------------------------------------------------------------------
local UI = {}
local function initUI()
  if gpu.getDepth() <= 1 then
    UI = { bg = 0x000000, fg = 0xFFFFFF, dim = 0xFFFFFF, accent = 0xFFFFFF, bar = 0xFFFFFF, barFg = 0x000000,
           selBg = 0xFFFFFF, selFg = 0x000000, field = 0x000000, fieldFg = 0xFFFFFF, focus = 0xFFFFFF,
           focusFg = 0x000000, btn = 0x000000, btnFg = 0xFFFFFF, panel = 0x000000, ok = 0xFFFFFF,
           err = 0xFFFFFF, keyBg = 0xFFFFFF, keyFg = 0x000000 }
  else
    UI = { bg = 0x000000, fg = 0xE6E6E6, dim = 0x8C8C8C, accent = 0xFFCC33, bar = 0xB30000, barFg = 0xFFFFFF,
           selBg = 0xFFCC33, selFg = 0x000000, field = 0x333333, fieldFg = 0xFFFFFF, focus = 0xFFFFFF,
           focusFg = 0x000000, btn = 0x333333, btnFg = 0xFFFFFF, panel = 0x333333, ok = 0x33CC33,
           err = 0xFF3333, keyBg = 0xFFCC33, keyFg = 0x000000 }
  end
end

local function titleBar(left, right)
  local W = gpu.getResolution()
  left = left or ""
  fill(1, 1, W, 1, UI.bar)
  put(1, 1, clip(left, W), UI.barFg, UI.bar)
  if right and right ~= "" then
    local r = clip(right, math.max(0, W - ulen(left) - 2))
    put(W - ulen(r) + 1, 1, r, UI.barFg, UI.bar)
  end
end

local function isKey(code, ...)
  for _, k in ipairs({ ... }) do if code == k then return true end end
  return false
end

-- Centered message box. Returns the index of the chosen button.
local function dialog(title, message, buttons, default)
  local W, H = gpu.getResolution()
  local lines = wrap(message, math.min(W - 8, 56))
  local btnW = -1
  for _, b in ipairs(buttons) do btnW = btnW + ulen(b) + 5 end
  local w = math.max(ulen(title) + 4, btnW + 4)
  for _, l in ipairs(lines) do w = math.max(w, ulen(l) + 4) end
  w = math.min(w, W - 2)
  local h = #lines + 5
  local x, y = math.floor((W - w) / 2) + 1, math.floor((H - h) / 2) + 1
  local focus, hits = default or 1, {}
  local function draw()
    hits = {}
    fill(x, y, w, h, UI.panel)
    fill(x, y, w, 1, UI.bar)
    put(x + 1, y, clip(title, w - 2), UI.barFg, UI.bar)
    for i, l in ipairs(lines) do put(x + 2, y + 1 + i, clip(l, w - 4), UI.fg, UI.panel) end
    local bx, by = x + math.max(1, math.floor((w - btnW) / 2)), y + h - 2
    for i, b in ipairs(buttons) do
      local t, on = "[ " .. b .. " ]", i == focus
      put(bx, by, t, on and UI.selFg or UI.btnFg, on and UI.selBg or UI.btn)
      hits[i] = { x1 = bx, x2 = bx + ulen(t) - 1, y = by }
      bx = bx + ulen(t) + 1
    end
  end
  draw()
  while true do
    local ev = table.pack(event.pull())
    local redraw = true
    if ev[1] == "key_down" then
      local ch, code = ev[3], ev[4]
      if code == K.left or (code == K.tab and keyboard.isShiftDown()) then
        focus = (focus - 2) % #buttons + 1
      elseif code == K.right or code == K.tab then
        focus = focus % #buttons + 1
      elseif isKey(code, K.enter, K.numpadenter) then
        return focus
      elseif ch and ch > 32 then
        local c = unicode.lower(unicode.char(ch))
        for i, b in ipairs(buttons) do
          if unicode.lower(usub(b, 1, 1)) == c then return i end
        end
      end
    elseif ev[1] == "touch" then
      local tx, ty = math.floor(ev[3]), math.floor(ev[4])
      for i, hb in ipairs(hits) do
        if ty == hb.y and tx >= hb.x1 and tx <= hb.x2 then return i end
      end
      redraw = false
    else
      redraw = false
    end
    if redraw then draw() end
  end
end

-- Centered pick list. items = { {label=, desc=, color=}, ... }. Returns index or nil.
local function pickList(title, items, sel)
  local W, H = gpu.getResolution()
  local labelW = 0
  for _, it in ipairs(items) do labelW = math.max(labelW, ulen(it.label)) end
  local w = math.max(ulen(title) + 4, labelW + 6)
  for _, it in ipairs(items) do
    if it.desc then w = math.max(w, labelW + ulen(it.desc) + 8) end
  end
  w = math.min(w, W - 2)
  local visible = math.max(1, math.min(#items, H - 6))
  local h = visible + 4
  local x, y = math.floor((W - w) / 2) + 1, math.floor((H - h) / 2) + 1
  sel = math.max(1, math.min(#items, sel or 1))
  local top = 1
  local function draw()
    if sel < top then top = sel elseif sel > top + visible - 1 then top = sel - visible + 1 end
    fill(x, y, w, h, UI.panel)
    fill(x, y, w, 1, UI.bar)
    put(x + 1, y, clip(title, w - 2), UI.barFg, UI.bar)
    for r = 1, visible do
      local i = top + r - 1
      local it = items[i]
      if it then
        local ry, on = y + 1 + r, i == sel
        local bg = on and UI.selBg or UI.panel
        fill(x + 1, ry, w - 2, 1, bg)
        put(x + 2, ry, clip(it.label, w - 4), on and UI.selFg or (it.color or UI.fg), bg)
        if it.desc and labelW + 8 < w then
          put(x + 4 + labelW, ry, clip(it.desc, w - labelW - 6), on and UI.selFg or UI.dim, bg)
        end
      end
    end
    put(x + 2, y + h - 1, clip("Enter/click = choose   Backspace = back", w - 4), UI.dim, UI.panel)
  end
  draw()
  while true do
    local ev = table.pack(event.pull())
    local redraw = true
    if ev[1] == "key_down" then
      local code = ev[4]
      if code == K.up then sel = math.max(1, sel - 1)
      elseif code == K.down then sel = math.min(#items, sel + 1)
      elseif code == K.pageUp then sel = math.max(1, sel - visible)
      elseif code == K.pageDown then sel = math.min(#items, sel + visible)
      elseif code == K.home then sel = 1
      elseif code == K["end"] then sel = #items
      elseif isKey(code, K.enter, K.numpadenter) then return sel
      elseif code == K.back or (keyboard.isControlDown() and code == K.q) then return nil
      end
    elseif ev[1] == "touch" then
      local tx, ty = math.floor(ev[3]), math.floor(ev[4])
      if tx < x or tx >= x + w or ty < y or ty >= y + h then return nil end
      local i = top + (ty - y - 2)
      if ty >= y + 2 and ty <= y + 1 + visible and items[i] then return i end
      redraw = false
    elseif ev[1] == "scroll" then
      sel = math.max(1, math.min(#items, sel - (ev[5] > 0 and 1 or -1)))
    else
      redraw = false
    end
    if redraw then draw() end
  end
end

---------------------------------------------------------------------------
-- Form engine: editable text / number / password / choice / color / bool
-- fields, with keyboard + mouse support and an optional live preview.
---------------------------------------------------------------------------
local TEXTLIKE = { text = true, number = true, password = true }

local function runForm(spec)
  local fields, n = spec.fields, #spec.fields
  local vals = deepcopy(spec.values or {})
  local edit = {}
  for i, f in ipairs(fields) do
    if TEXTLIKE[f.kind] then
      local v = vals[f.key]
      v = v == nil and "" or tostring(v)
      edit[i] = { text = v, cur = ulen(v) + 1, scroll = 1 }
    elseif f.kind == "bool" then
      vals[f.key] = vals[f.key] and true or false
    end
  end

  local W, H = gpu.getResolution()
  local labelW = 4
  for _, f in ipairs(fields) do labelW = math.max(labelW, ulen(f.label)) end
  labelW = math.min(labelW, math.floor(W / 3))
  local fx = labelW + 6
  local fw = math.max(10, math.min(W - fx - 3, 72))

  local function plan(sp)
    local rows = math.max(1, math.min(n, math.floor((H - 4 - sp) / sp)))
    local helpY = 3 + rows * sp
    local buttonsY = helpY + sp
    return rows, helpY, buttonsY, H - 3 - buttonsY
  end
  local spacing = 2
  local rows, helpY, buttonsY, pvH = plan(2)
  if rows < n or (spec.preview and pvH < 4) then
    spacing = 1
    rows, helpY, buttonsY, pvH = plan(1)
  end
  local pv
  if spec.preview and pvH >= 2 then pv = { x = 3, y = buttonsY + 3, w = W - 4, h = pvH } end

  local focus, first, btnHits = 1, 1, {}
  for i, f in ipairs(fields) do
    if TEXTLIKE[f.kind] then focus = i; break end
  end
  if focus > rows then first = focus - rows + 1 end

  local function fieldY(i) return 3 + (i - first) * spacing end

  local function current()
    local v = deepcopy(vals)
    for i, f in ipairs(fields) do
      local e = edit[i]
      if e then
        if f.kind == "number" then
          local num = tonumber(e.text) or f.default or 0
          if f.min and num < f.min then num = f.min end
          if f.max and num > f.max then num = f.max end
          v[f.key] = math.floor(num)
        else
          v[f.key] = e.text
        end
      end
    end
    return v
  end

  local function optionsOf(f)
    if f.options then return f.options end
    if f.kind == "color" then return f.none and BG_NAMES or COLOR_NAMES end
    return {}
  end

  local function cycle(i, dir)
    local f = fields[i]
    if f.kind == "bool" then vals[f.key] = not vals[f.key]; return end
    local o = optionsOf(f)
    if #o == 0 then return end
    local idx = 1
    for k, opt in ipairs(o) do
      if tostring(opt) == tostring(vals[f.key]) then idx = k end
    end
    vals[f.key] = o[(idx - 1 + dir) % #o + 1]
  end

  local function insertText(s)
    local e, f = edit[focus], fields[focus]
    s = tostring(s):gsub("[\r\n\t]", " ")
    if f.kind == "number" then
      s = s:gsub("%D", "")
      if e.text == "0" and s ~= "" then e.text, e.cur = "", 1 end -- typing replaces a lone 0
    end
    if f.maxLen then s = usub(s, 1, math.max(0, f.maxLen - ulen(e.text))) end
    if s == "" then return end
    e.text = usub(e.text, 1, e.cur - 1) .. s .. usub(e.text, e.cur)
    e.cur = e.cur + ulen(s)
  end

  local function drawField(i)
    local f, y = fields[i], fieldY(i)
    local on = focus == i
    fill(1, y, W - 2, 1, UI.bg)
    if on then put(2, y, "►", UI.accent, UI.bg) end
    put(4, y, clip(f.label, labelW), on and UI.accent or UI.fg, UI.bg)
    local bg = on and UI.focus or UI.field
    local fg = on and UI.focusFg or UI.fieldFg
    fill(fx, y, fw, 1, bg)
    if TEXTLIKE[f.kind] then
      local e, vis = edit[i], fw - 2
      if e.cur < e.scroll then e.scroll = e.cur end
      if e.cur - e.scroll > vis - 1 then e.scroll = e.cur - vis + 1 end
      local shown = usub(e.text, e.scroll, e.scroll + vis - 1)
      if f.kind == "password" then shown = string.rep("*", ulen(shown)) end
      put(fx + 1, y, shown, fg, bg)
      if e.scroll > 1 then put(fx, y, "‹", on and fg or UI.accent, bg) end
      if ulen(e.text) - e.scroll + 1 > vis then put(fx + fw - 1, y, "›", on and fg or UI.accent, bg) end
      if on then
        local ch = usub(e.text, e.cur, e.cur)
        if ch == "" then ch = " " elseif f.kind == "password" then ch = "*" end
        put(fx + 1 + e.cur - e.scroll, y, ch, bg, fg) -- inverted = cursor
      end
    else
      local v, x, txt = vals[f.key], fx + 1, nil
      if f.kind == "bool" then
        txt = v and "[x] Yes" or "[ ] No"
      elseif f.kind == "color" then
        local c = col(v, nil)
        if c then put(x, y, "██", c, bg) else put(x, y, "··", fg, bg) end
        x = x + 3
        txt = (v == nil or v == "None") and "None (page background)" or tostring(v)
      else
        txt = f.labels and f.labels[v] or tostring(v)
      end
      put(x, y, clip(txt, fx + fw - x - 5), fg, bg)
      put(fx + fw - 4, y, "◄ ►", on and fg or UI.dim, bg)
    end
  end

  local function drawHelp()
    fill(1, helpY, W, 1, UI.bg)
    local text
    if focus <= n then
      text = fields[focus].help
    else
      text = focus == n + 1 and ("Press Enter to " .. (spec.okLabel or "save"):lower() .. ".")
        or "Press Enter to cancel without saving."
    end
    if text then put(fx, helpY, clip(text, W - fx - 1), UI.dim, UI.bg) end
  end

  local function drawButtons()
    fill(1, buttonsY, W, 1, UI.bg)
    local x = fx
    for k, label in ipairs({ spec.okLabel or "Save", "Cancel" }) do
      local t, on = "[ " .. label .. " ]", focus == n + k
      put(x, buttonsY, t, on and UI.selFg or UI.btnFg, on and UI.selBg or UI.btn)
      btnHits[k] = { x1 = x, x2 = x + ulen(t) - 1 }
      x = x + ulen(t) + 2
    end
  end

  local function drawPreview()
    if not pv then return end
    local ok, lines, bg, lw = pcall(spec.preview, current(), pv.w)
    if not ok then
      fill(pv.x, pv.y, pv.w, pv.h, UI.bg)
      put(pv.x, pv.y, clip("Preview error: " .. tostring(lines), pv.w), UI.err, UI.bg)
      return
    end
    fill(pv.x, pv.y, pv.w, pv.h, bg or 0x000000)
    for i = 1, math.min(#lines, pv.h) do drawLine(lines[i], pv.x, pv.y + i - 1, lw or pv.w) end
  end

  local function drawAll()
    fill(1, 1, W, H, UI.bg)
    titleBar(spec.title, spec.subtitle)
    for i = first, math.min(n, first + rows - 1) do drawField(i) end
    if first > 1 then put(W - 1, 3, "▲", UI.dim, UI.bg) end
    if first + rows - 1 < n then put(W - 1, fieldY(first + rows - 1), "▼", UI.dim, UI.bg) end
    drawHelp()
    drawButtons()
    if pv then
      put(3, pv.y - 1, "─ Preview " .. string.rep("─", math.max(0, pv.w - 10)), UI.dim, UI.bg)
      drawPreview()
    end
    fill(1, H, W, 1, UI.bar)
    put(2, H, clip("Tab/↑↓ next field  ←→ change  Enter next  Ctrl+S save  Ctrl+Q cancel", W - 2), UI.barFg, UI.bar)
  end

  local function move(d)
    focus = (focus - 1 + d) % (n + 2) + 1
    if focus <= n then
      if focus < first then first = focus
      elseif focus > first + rows - 1 then first = focus - rows + 1 end
    end
  end

  buffered(drawAll)
  while true do
    local ev = table.pack(event.pull())
    local name, mode = ev[1], "all" -- mode: "all" = full redraw, "field" = focused field only, nil = nothing
    if name == "key_down" then
      local ch, code = ev[3], ev[4]
      local ctrl, shift = keyboard.isControlDown(), keyboard.isShiftDown()
      local f = fields[focus]
      if ctrl and code == K.s then return current()
      elseif ctrl and (code == K.q or code == K.w) then return nil
      elseif code == K.tab then move(shift and -1 or 1)
      elseif code == K.up then move(-1)
      elseif code == K.down then move(1)
      elseif isKey(code, K.enter, K.numpadenter) then
        if focus == n + 1 then return current() end
        if focus == n + 2 then return nil end
        move(1)
      elseif focus > n then
        if code == K.left or code == K.right then focus = (focus == n + 1) and n + 2 or n + 1 end
      elseif TEXTLIKE[f.kind] then
        mode = "field"
        local e = edit[focus]
        local len = ulen(e.text)
        if code == K.left then e.cur = math.max(1, e.cur - 1)
        elseif code == K.right then e.cur = math.min(len + 1, e.cur + 1)
        elseif code == K.home then e.cur = 1
        elseif code == K["end"] then e.cur = len + 1
        elseif code == K.back then
          if e.cur > 1 then
            e.text = usub(e.text, 1, e.cur - 2) .. usub(e.text, e.cur)
            e.cur = e.cur - 1
          end
        elseif code == K.delete then
          e.text = usub(e.text, 1, e.cur - 1) .. usub(e.text, e.cur + 1)
        elseif ch and ch >= 32 and ch ~= 127 and not ctrl then
          insertText(unicode.char(ch))
        else
          mode = nil
        end
      else
        mode = "field"
        if code == K.left then cycle(focus, -1)
        elseif code == K.right or code == K.space then cycle(focus, 1)
        else mode = nil end
      end
    elseif name == "touch" then
      local tx, ty, btn = math.floor(ev[3]), math.floor(ev[4]), ev[5]
      for i = first, math.min(n, first + rows - 1) do
        if ty == fieldY(i) then
          focus = i
          local f = fields[i]
          if tx >= fx and tx < fx + fw then
            if TEXTLIKE[f.kind] then
              local e = edit[i]
              e.cur = math.max(1, math.min(ulen(e.text) + 1, e.scroll + tx - fx - 1))
            else
              cycle(i, btn == 1 and -1 or 1)
            end
          end
        end
      end
      if ty == buttonsY then
        for k, hb in ipairs(btnHits) do
          if tx >= hb.x1 and tx <= hb.x2 then
            if k == 1 then return current() end
            return nil
          end
        end
      end
    elseif name == "scroll" then
      move(ev[5] > 0 and -1 or 1)
    elseif name == "clipboard" then
      if focus <= n and TEXTLIKE[fields[focus].kind] then
        insertText(ev[3])
        mode = "field"
      else
        mode = nil
      end
    else
      mode = nil
    end
    if mode == "all" then
      buffered(drawAll)
    elseif mode == "field" then
      drawField(focus)
      drawPreview()
    end
  end
end

---------------------------------------------------------------------------
-- Previews used by the forms
---------------------------------------------------------------------------
local SAMPLE = {
  h1 = { { type = "h1", text = "Hot Deals" }, { type = "paragraph", text = "Only while stocks last." } },
  h2 = { { type = "h2", text = "Burgers" }, { type = "item", name = "Classic Burger", price = "4.99" } },
  h3 = { { type = "h3", text = "Dipping sauces" }, { type = "paragraph", text = "Ketchup, mustard, BBQ or spicy mayo." } },
  paragraph = { { type = "paragraph", text = "All burgers come on a toasted bun with pickles on the side. Ask for no onions!" } },
  note = { { type = "note", text = "COMBO: any burger + fries + drink for $7.99" } },
  item = {
    { type = "item", name = "Double Cheese", price = "6.49", desc = "Two patties, double cheddar", tag = "NEW" },
    { type = "item", name = "Onion Rings", price = "2.49", soldOut = true },
  },
  divider = {
    { type = "item", name = "Fries", price = "1.99" }, { type = "divider" },
    { type = "item", name = "Soda", price = "1.49" },
  },
}

local function realColumnWidth(m, w)
  local dw = displaySize(m)
  local _, cw = columnSetup(m, dw)
  return math.min(w, cw)
end

local function previewBlocks(m, list, w)
  local bg = col(m.settings.background, 0x000000)
  w = realColumnWidth(m, w)
  local lines = {}
  for _, b in ipairs(list) do
    local f = LAYOUT[b.type]
    if f then
      for _, ln in ipairs(f(b, m, w, bg)) do lines[#lines + 1] = ln end
    elseif b.type == "colbreak" then
      local ln = mkLine()
      seg(ln, 1, "(the menu continues in the next column or page)", 0x878787, bg)
      lines[#lines + 1] = ln
    end
  end
  while lines[1] and lines[1].margin do table.remove(lines, 1) end
  return lines, bg, w
end

local function previewStyle(m, key, vals, w)
  local tmp = { settings = m.settings, styles = {} }
  for k, v in pairs(m.styles) do tmp.styles[k] = v end
  tmp.styles[key] = vals
  local bg = col(m.settings.background, 0x000000)
  local dw, dh = displaySize(m)
  if key == "banner" then
    w = math.min(w, dw)
    return headerLines(tmp, w, dh, bg), bg, w
  elseif key == "footer" then
    w = math.min(w, dw)
    return { footerLine(tmp, w, "1/2") }, bg, w
  end
  return previewBlocks(tmp, SAMPLE[key] or {}, w)
end

---------------------------------------------------------------------------
-- Field definitions
---------------------------------------------------------------------------
local ALIGN3 = { "left", "center", "right" }

local function blockFields(t)
  local hidden = { key = "hidden", label = "Hidden", kind = "bool", help = "Hide this block on the display without deleting it." }
  if t == "item" then
    return {
      { key = "name", label = "Item name", kind = "text", maxLen = 60, help = "Shown on the left, e.g. Double Cheeseburger." },
      { key = "price", label = "Price", kind = "text", maxLen = 16, help = "Numbers get the currency added (4.99 -> $4.99). Text like '2 for $5' is shown as typed." },
      { key = "desc", label = "Description", kind = "text", maxLen = 200, help = "Optional small text under the item. Type \\n for a line break." },
      { key = "tag", label = "Badge", kind = "text", maxLen = 12, help = "Optional highlight label: NEW, HOT, DEAL, VEGGIE... Leave empty for none." },
      { key = "soldOut", label = "Sold out", kind = "bool", help = "Shows SOLD OUT instead of the price." },
      hidden,
    }
  elseif TEXT_SET[t] then
    return {
      { key = "text", label = "Text", kind = "text", maxLen = 400, help = "Long text wraps automatically. Type \\n to force a line break." },
      { key = "type", label = "Style", kind = "choice", options = TEXT_TYPES, labels = TYPE_LABELS, help = "Switch between heading levels, paragraph and note box." },
      { key = "align", label = "Alignment", kind = "choice", options = { "style", "left", "center", "right" },
        labels = { style = "(use the style's alignment)" }, help = "Overrides the alignment set under Styles." },
      hidden,
    }
  end
  return { hidden }
end

local function settingsFields()
  local mw, mh = gpu.maxResolution()
  return {
    { key = "title", label = "Title", kind = "text", maxLen = 40, help = "Big banner text at the top of every page." },
    { key = "subtitle", label = "Subtitle", kind = "text", maxLen = 120, help = "Smaller line under the title. Leave empty to hide." },
    { key = "footer", label = "Footer", kind = "text", maxLen = 160, help = "Text in the bottom bar. Leave empty to hide." },
    { key = "currency", label = "Currency", kind = "text", maxLen = 6, help = "Added to numeric prices, e.g. $  or  Cr  or  EU" },
    { key = "currencyPos", label = "Currency side", kind = "choice", options = { "before", "after" } },
    { key = "columns", label = "Columns", kind = "choice", options = { 1, 2, 3, 4 }, help = "Reduced automatically if the screen is too narrow." },
    { key = "colLines", label = "Column lines", kind = "bool", help = "Thin line between columns (uses the Divider color)." },
    { key = "background", label = "Background", kind = "color", help = "Page background color." },
    { key = "width", label = "Width", kind = "number", min = 0, max = mw, help = "Display resolution width. 0 = maximum (" .. mw .. ")." },
    { key = "height", label = "Height", kind = "number", min = 0, max = mh, help = "Display resolution height. 0 = maximum (" .. mh .. ")." },
    { key = "pageSeconds", label = "Page seconds", kind = "number", min = 2, max = 3600, default = 10, help = "Seconds per page when the menu needs more than one page." },
    { key = "pin", label = "Edit PIN", kind = "password", maxLen = 16, help = "If set, needed to edit or quit. Leave empty for no lock." },
  }
end

local function headingStyleFields()
  return {
    { key = "fg", label = "Text color", kind = "color" },
    { key = "bg", label = "Background", kind = "color", none = true, help = "None = use the page background." },
    { key = "align", label = "Alignment", kind = "choice", options = ALIGN3 },
    { key = "decor", label = "Decoration", kind = "choice", options = { "plain", "bar", "line", "underline", "box" },
      help = "bar = colored strip, line = ── TEXT ──, underline, box = framed." },
    { key = "lineFg", label = "Line color", kind = "color", help = "Color of lines, underlines, boxes (and bars with no background)." },
    { key = "big", label = "Big letters", kind = "bool", help = "Large block letters when the text fits in the column." },
    { key = "upper", label = "UPPERCASE", kind = "bool" },
    { key = "space", label = "Space above", kind = "choice", options = { 0, 1, 2, 3 } },
  }
end

local function paragraphStyleFields()
  return {
    { key = "fg", label = "Text color", kind = "color" },
    { key = "bg", label = "Background", kind = "color", none = true, help = "None = use the page background." },
    { key = "align", label = "Alignment", kind = "choice", options = ALIGN3 },
    { key = "indent", label = "Indent", kind = "choice", options = { 0, 1, 2, 3, 4 }, help = "Empty columns on both sides." },
    { key = "padding", label = "Padding", kind = "bool", help = "Colored line above and below (needs a background color)." },
    { key = "space", label = "Space above", kind = "choice", options = { 0, 1, 2 } },
  }
end

local STYLE_DEFS = {
  { key = "banner", label = "Title banner", desc = "big title + subtitle at the top", fields = {
    { key = "fg", label = "Title color", kind = "color" },
    { key = "bg", label = "Background", kind = "color", none = true },
    { key = "subFg", label = "Subtitle color", kind = "color" },
    { key = "size", label = "Letter size", kind = "choice", options = { "auto", "large", "medium", "small" },
      help = "auto = biggest size that fits the screen." },
    { key = "align", label = "Alignment", kind = "choice", options = ALIGN3 },
  } },
  { key = "h1", label = "Heading 1", desc = "headline", fields = headingStyleFields() },
  { key = "h2", label = "Heading 2", desc = "section header", fields = headingStyleFields() },
  { key = "h3", label = "Heading 3", desc = "sub-header", fields = headingStyleFields() },
  { key = "paragraph", label = "Paragraph", desc = "body text", fields = paragraphStyleFields() },
  { key = "note", label = "Note box", desc = "highlighted text", fields = paragraphStyleFields() },
  { key = "item", label = "Menu item", desc = "name .... price", fields = {
    { key = "nameFg", label = "Name color", kind = "color" },
    { key = "priceFg", label = "Price color", kind = "color" },
    { key = "descFg", label = "Description color", kind = "color" },
    { key = "leader", label = "Leader", kind = "choice", options = { ".", "·", "-", "_", "~", " " },
      labels = { ["."] = "dots .....", ["·"] = "middle dots ·····", ["-"] = "dashes -----",
                 ["_"] = "underscores _____", ["~"] = "tildes ~~~~~", [" "] = "none" },
      help = "Characters between the name and the price." },
    { key = "leaderFg", label = "Leader color", kind = "color" },
    { key = "tagFg", label = "Badge text", kind = "color" },
    { key = "tagBg", label = "Badge color", kind = "color" },
    { key = "soldFg", label = "Sold-out color", kind = "color" },
    { key = "upper", label = "UPPERCASE names", kind = "bool" },
    { key = "descIndent", label = "Desc. indent", kind = "choice", options = { 0, 1, 2, 3, 4 } },
    { key = "space", label = "Space above", kind = "choice", options = { 0, 1 }, help = "Blank line before every item." },
  } },
  { key = "divider", label = "Divider", desc = "horizontal line", fields = {
    { key = "fg", label = "Color", kind = "color" },
    { key = "char", label = "Character", kind = "choice", options = { "─", "═", "━", "-", "=", "~", "·", "*" } },
    { key = "space", label = "Space around", kind = "choice", options = { 0, 1, 2 } },
  } },
  { key = "footer", label = "Footer bar", desc = "bottom line", fields = {
    { key = "fg", label = "Text color", kind = "color" },
    { key = "bg", label = "Bar color", kind = "color" },
    { key = "align", label = "Alignment", kind = "choice", options = ALIGN3 },
  } },
}

---------------------------------------------------------------------------
-- Blocks
---------------------------------------------------------------------------
local function newBlock(t)
  if t == "item" then
    return { type = t, name = "", price = "", desc = "", tag = "", soldOut = false, hidden = false }
  elseif TEXT_SET[t] then
    return { type = t, text = "", align = "style", hidden = false }
  end
  return { type = t, hidden = false }
end

local function summary(b, m)
  local t = b.type
  if t == "item" then
    local s = trim(b.name)
    if trim(b.tag) ~= "" then s = s .. " [" .. trim(b.tag) .. "]" end
    if trim(b.desc) ~= "" then s = s .. "  - " .. trim(b.desc) end
    if b.soldOut then s = s .. "  (sold out)" end
    return s, formatPrice(b.price, m.settings)
  elseif t == "divider" then return string.rep("─", 16), ""
  elseif t == "spacer" then return "(empty line)", ""
  elseif t == "colbreak" then return "─── continue in next column ───", ""
  end
  return (trim(b.text):gsub("\\n", " / ")), ""
end

---------------------------------------------------------------------------
-- Display mode
---------------------------------------------------------------------------
local function checkPin(m)
  local pin = trim(m.settings.pin)
  if pin == "" then return true end
  local r = runForm({
    title = " Locked", subtitle = "enter the PIN ",
    fields = { { key = "pin", label = "PIN", kind = "password", help = "Ctrl+Q or Cancel to go back to the menu." } },
    values = { pin = "" }, okLabel = "Unlock",
  })
  if r and r.pin == pin then return true end
  if r then dialog("Wrong PIN", "That PIN is not correct.", { "OK" }) end
  return false
end

local function displayMode(m, preview)
  local W, H = displaySize(m)
  local cw, ch = gpu.getResolution()
  if cw ~= W or ch ~= H then gpu.setResolution(W, H) end
  local L, page = buildLayout(m, W, H), 1
  local interval = math.max(2, tonumber(m.settings.pageSeconds) or 10)
  local deadline = computer.uptime() + interval
  local function redraw() buffered(function() drawPage(L, page, m) end) end
  local function flip(d)
    deadline = computer.uptime() + interval
    if #L.pages > 1 then
      page = (page - 1 + d) % #L.pages + 1
      redraw()
    end
  end
  redraw()
  while true do
    local timeout = #L.pages > 1 and math.max(0, deadline - computer.uptime()) or nil
    local ev = table.pack(event.pull(timeout))
    local name = ev[1]
    if name == nil then
      if computer.uptime() >= deadline then flip(1) end
    elseif name == "key_down" then
      local code = ev[4]
      if isKey(code, K.right, K.down, K.pageDown, K.space) then flip(1)
      elseif isKey(code, K.left, K.up, K.pageUp) then flip(-1)
      elseif preview then return
      elseif code == K.e or code == K.q then
        if checkPin(m) then return code == K.e and "edit" or "quit" end
        redraw()
      end
    elseif name == "touch" then
      if preview and #L.pages <= 1 then return end
      flip(1)
    elseif name == "screen_resized" then
      local nw, nh = gpu.getResolution()
      if nw ~= W or nh ~= H then
        W, H = nw, nh
        L, page = buildLayout(m, W, H), 1
        redraw()
      end
    end
  end
end

---------------------------------------------------------------------------
-- Editor
---------------------------------------------------------------------------
local dirty = false

local function editBlock(m, b, isNew)
  local r = runForm({
    title = (isNew and " New " or " Edit ") .. typeInfo(b.type).label,
    subtitle = "Ctrl+S save · Ctrl+Q cancel ",
    fields = blockFields(b.type),
    values = b,
    preview = function(v, w) return previewBlocks(m, { v }, w) end,
  })
  if not r then return false end
  for k, v in pairs(r) do b[k] = v end
  return true
end

local function editSettings(m)
  local r = runForm({
    title = " Menu setup", subtitle = "Ctrl+S save · Ctrl+Q cancel ",
    fields = settingsFields(), values = m.settings,
    preview = function(v, w)
      local tmp = { settings = v, styles = m.styles }
      local bg = col(v.background, 0x000000)
      local dw, dh = displaySize(tmp)
      w = math.min(w, dw)
      local lines = headerLines(tmp, w, dh, bg)
      lines[#lines + 1] = mkLine()
      lines[#lines + 1] = footerLine(tmp, w, "1/2")
      return lines, bg, w
    end,
  })
  if not r then return false end
  for k, v in pairs(r) do m.settings[k] = v end
  return true
end

local function editStyles(m)
  local items = {}
  for _, d in ipairs(STYLE_DEFS) do items[#items + 1] = { label = d.label, desc = d.desc } end
  items[#items + 1] = { label = "Reset all styles", desc = "back to the default look", color = UI.err }
  local sel = 1
  while true do
    buffered(function()
      local W, H = gpu.getResolution()
      fill(1, 1, W, H, UI.bg)
      titleBar(" STYLES", "colors, alignment and decorations ")
    end)
    local k = pickList("Which style do you want to change?", items, sel)
    if not k then return end
    sel = k
    if k > #STYLE_DEFS then
      if dialog("Reset styles", "Reset every style to the default look?", { "Yes", "No" }, 2) == 1 then
        m.styles = deepcopy(DEFAULT_MENU.styles)
        dirty = true
      end
    else
      local d = STYLE_DEFS[k]
      local r = runForm({
        title = " Style: " .. d.label, subtitle = "Ctrl+S save · Ctrl+Q cancel ",
        fields = d.fields, values = m.styles[d.key],
        preview = function(v, w) return previewStyle(m, d.key, v, w) end,
      })
      if r then
        m.styles[d.key] = r
        dirty = true
      end
    end
  end
end

local EDITOR_BUTTONS = {
  { key = "↵", label = "Edit", action = "edit" },
  { key = "A", label = "Add", action = "add" },
  { key = "C", label = "Copy", action = "dup" },
  { key = "D", label = "Delete", action = "delete" },
  { key = "[", label = "Up", action = "up" },
  { key = "]", label = "Down", action = "down" },
  { key = "M", label = "Menu setup", action = "settings" },
  { key = "Y", label = "Styles", action = "styles" },
  { key = "P", label = "Preview", action = "preview" },
  { key = "S", label = "Save", action = "save" },
  { key = "Q", label = "Exit", action = "exit" },
}

local function layoutButtons(defs, W)
  local out, x, row = {}, 2, 1
  for _, d in ipairs(defs) do
    local kt, lt = " " .. d.key .. " ", " " .. d.label .. " "
    local w = ulen(kt) + ulen(lt)
    if x + w - 1 > W - 1 and x > 2 then x, row = 2, row + 1 end
    out[#out + 1] = { x = x, row = row, kt = kt, lt = lt, w = w, action = d.action }
    x = x + w + 1
  end
  return out, row
end

local function editorMode(m)
  local W, H = gpu.maxResolution()
  gpu.setResolution(W, H)
  local btns, btnRows = layoutButtons(EDITOR_BUTTONS, W)
  local listY = 3
  local listH = math.max(3, H - 3 - btnRows)
  local statusY = listY + listH
  local sel, top, msg, msgColor = 1, 1, nil, nil
  local rowHits = {}

  local function clampSel()
    local blocks = m.blocks
    if #blocks == 0 then sel, top = 1, 1; return end
    sel = math.max(1, math.min(#blocks, sel))
    if sel < top then top = sel elseif sel > top + listH - 1 then top = sel - listH + 1 end
    top = math.max(1, top)
  end

  local function draw()
    local blocks = m.blocks
    fill(1, 1, W, H, UI.bg)
    titleBar(" MENU EDITOR", (dirty and "● unsaved · " or "") .. DATA_FILE .. " ")
    put(2, 2, "  #  TYPE   CONTENT", UI.dim, UI.bg)
    put(W - 6, 2, "PRICE", UI.dim, UI.bg)
    if #blocks == 0 then
      put(4, listY + 1, clip("The menu is empty. Press A (or click Add) to add your first block.", W - 5), UI.dim, UI.bg)
    end
    rowHits = {}
    for r = 1, listH do
      local i = top + r - 1
      local b = blocks[i]
      if not b then break end
      local y = listY + r - 1
      local on = i == sel
      local bg = on and UI.selBg or UI.bg
      local fg = on and UI.selFg or UI.fg
      if on then fill(1, y, W, 1, bg) end
      local info = typeInfo(b.type)
      put(2, y, string.format("%3d", i), on and fg or UI.dim, bg)
      put(7, y, info.short, on and fg or info.color, bg)
      local s, price = summary(b, m)
      if b.hidden then s = "(hidden) " .. s end
      local sx = isHeading(b.type) and 14 or 16
      put(sx, y, clip(s, W - sx - 13), (b.hidden and not on) and UI.dim or fg, bg)
      if price ~= "" then
        local p = clip(price, 11)
        put(W - ulen(p), y, p, on and fg or UI.accent, bg)
      end
      rowHits[#rowHits + 1] = { y = y, i = i }
    end
    if top > 1 then put(W, listY, "▲", UI.dim, UI.bg) end
    if top + listH - 1 < #blocks then put(W, listY + listH - 1, "▼", UI.dim, UI.bg) end

    local dw, dh = displaySize(m)
    local L = buildLayout(m, dw, dh)
    local info = string.format("%d blocks  ·  display %dx%d  ·  %d column(s)  ·  %d page(s)%s",
      #blocks, dw, dh, L.n, #L.pages, #L.pages > 1 and (" rotating every " .. m.settings.pageSeconds .. "s") or "")
    put(2, statusY, clip(msg or info, W - 2), msg and (msgColor or UI.ok) or UI.dim, UI.bg)

    for _, bt in ipairs(btns) do
      local y = statusY + bt.row
      if y <= H then
        put(bt.x, y, bt.kt, UI.keyFg, UI.keyBg)
        put(bt.x + ulen(bt.kt), y, bt.lt, UI.btnFg, UI.btn)
        bt.y = y
      end
    end
  end

  local function save()
    local ok, err = saveMenu(m)
    if ok then
      dirty = false
      msg, msgColor = "Saved to " .. DATA_FILE, UI.ok
    else
      msg, msgColor = "Save failed: " .. tostring(err), UI.err
    end
    return ok
  end

  local function act(a)
    local blocks = m.blocks
    local b = blocks[sel]
    if a == "edit" then
      if b and editBlock(m, b) then dirty = true end
    elseif a == "add" then
      local items = {}
      for _, t in ipairs(TYPE_ORDER) do
        items[#items + 1] = { label = TYPES[t].label, desc = TYPES[t].desc, color = TYPES[t].color }
      end
      local k = pickList("Add which kind of block?", items)
      if k then
        local nb = newBlock(TYPE_ORDER[k])
        local okb = true
        if nb.type == "item" or TEXT_SET[nb.type] then okb = editBlock(m, nb, true) end
        if okb then
          local pos = #blocks == 0 and 1 or sel + 1
          table.insert(blocks, pos, nb)
          sel, dirty = pos, true
        end
      end
    elseif a == "dup" then
      if b then
        table.insert(blocks, sel + 1, deepcopy(b))
        sel, dirty = sel + 1, true
      end
    elseif a == "delete" then
      if b then
        local s = summary(b, m)
        local q = "Delete this " .. typeInfo(b.type).label:lower() .. "?\n" .. clip(s, 50)
        if dialog("Delete", q, { "Yes", "No" }, 2) == 1 then
          table.remove(blocks, sel)
          dirty = true
        end
      end
    elseif a == "up" then
      if b and sel > 1 then
        blocks[sel], blocks[sel - 1] = blocks[sel - 1], blocks[sel]
        sel, dirty = sel - 1, true
      end
    elseif a == "down" then
      if b and sel < #blocks then
        blocks[sel], blocks[sel + 1] = blocks[sel + 1], blocks[sel]
        sel, dirty = sel + 1, true
      end
    elseif a == "settings" then
      if editSettings(m) then dirty = true end
    elseif a == "styles" then
      editStyles(m)
    elseif a == "preview" then
      displayMode(m, true)
      gpu.setResolution(W, H)
      msg, msgColor = "Back from preview (arrow keys flip pages in preview).", UI.ok
    elseif a == "save" then
      save()
    elseif a == "exit" then
      if not dirty then return "exit" end
      local r = dialog("Unsaved changes", "Save your changes before going back to the display?",
        { "Save", "Don't save", "Cancel" }, 1)
      if r == 1 then
        if save() then return "exit" end
      elseif r == 2 then
        return "exit"
      end
    end
  end

  while true do
    clampSel()
    buffered(draw)
    msg = nil
    local handled = false
    repeat
      local ev = table.pack(event.pull())
      local a
      handled = true
      if ev[1] == "key_down" then
        local code = ev[4]
        local shift = keyboard.isShiftDown()
        if code == K.up then if shift then a = "up" else sel = sel - 1 end
        elseif code == K.down then if shift then a = "down" else sel = sel + 1 end
        elseif code == K.pageUp then sel = sel - listH
        elseif code == K.pageDown then sel = sel + listH
        elseif code == K.home then sel = 1
        elseif code == K["end"] then sel = #m.blocks
        elseif isKey(code, K.enter, K.numpadenter, K.e) then a = "edit"
        elseif code == K.a or code == K.insert then a = "add"
        elseif code == K.c then a = "dup"
        elseif code == K.d or code == K.delete then a = "delete"
        elseif code == K.lbracket then a = "up"
        elseif code == K.rbracket then a = "down"
        elseif code == K.m then a = "settings"
        elseif code == K.y then a = "styles"
        elseif code == K.p then a = "preview"
        elseif code == K.s then a = "save"
        elseif code == K.q then a = "exit"
        end
      elseif ev[1] == "touch" then
        local tx, ty = math.floor(ev[3]), math.floor(ev[4])
        for _, bt in ipairs(btns) do
          if bt.y == ty and tx >= bt.x and tx < bt.x + bt.w then a = bt.action end
        end
        for _, r in ipairs(rowHits) do
          if r.y == ty then
            if r.i == sel then a = "edit" else sel = r.i end
          end
        end
      elseif ev[1] == "scroll" then
        sel = sel - (ev[5] > 0 and 1 or -1)
      else
        handled = false
      end
      if a and act(a) == "exit" then return end
    until handled
  end
end

---------------------------------------------------------------------------
-- Main
---------------------------------------------------------------------------
local function main()
  initUI()
  local menu, loaded = loadMenu()
  dirty = not loaded
  local mode = cliOpts.e and "edit" or "display"
  while true do
    if mode == "edit" then
      editorMode(menu)
      mode = "display"
    else
      local r = displayMode(menu)
      if r == "quit" then return end
      mode = "edit"
    end
  end
end

pcall(term.setCursorBlink, false)
local ok, err = xpcall(main, function(e)
  if e == "interrupted" then return e end
  return debug.traceback(tostring(e))
end)

-- restore the screen for the shell
pcall(gpu.setActiveBuffer, 0)
local mw, mh = gpu.maxResolution()
gpu.setResolution(mw, mh)
gpu.setBackground(0x000000)
gpu.setForeground(0xFFFFFF)
term.clear()
pcall(term.setCursorBlink, true)
if not ok and err ~= "interrupted" then
  io.stderr:write("menuboard crashed:\n" .. tostring(err) .. "\n")
end
