--[[ ------------------------------------------------------------------
  MENU BOARD (low-memory edition) - editable fast-food menu for OpenOS

  Files:    menu.lua  menu_view.lua  menu_edit.lua   (same folder, e.g. /home)
  Run:      menu                 (data saved to /home/menu.cfg)
            menu /path/file.cfg  (use another data file)

  Memory:   only the viewer OR the editor is in RAM at a time, and each part
            is streamed into the compiler, so no big source string is built.
            Needs roughly 110 KB free (check with the "free" command).

  Hardware: Tier 2 GPU + Tier 2 screen minimum (80x25, 16 colours).
            Keyboard attached to the screen for editing.

  Display:  Left/Right arrows or click left/right half = change page.
            E = open editor     Q = quit     (asks for PIN if one is set)
  Editor:   Click a row on the left, edit the form on the right.
            Tab / Enter / Down = next field     Up = previous field
            Left/Right (or click) changes  < choice >  fields.
            Ins = add item   Del = delete row   F2 = save   F5 = done
-------------------------------------------------------------------- ]]
local component = require("component")
local fs        = require("filesystem")
local shell     = require("shell")
local ser       = require("serialization")
local term      = require("term")
local unicode   = require("unicode")

local gpu = component.isAvailable("gpu") and component.gpu
if not gpu or not gpu.getScreen() then io.stderr:write("menu: needs a GPU connected to a screen\n") return end
if gpu.maxDepth() < 4 then io.stderr:write("menu: needs a Tier 2+ GPU AND Tier 2+ screen\n") return end

-- find the other two parts: next to this file, else working dir, else /home
local function here() end
local ok, info = pcall(debug.getinfo, here, "S")
local DIR = ok and type(info) == "table" and tostring(info.source):match("^[=@](.*/)") or "/home/"
for _, d in ipairs({DIR, shell.getWorkingDirectory() .. "/", "/home/", "/usr/bin/"}) do
  if fs.exists(d .. "menu_view.lua") then DIR = d break end
end

local ulen, max, floor, min = unicode.len, math.max, math.floor, math.min
local M = {gpu = gpu, ulen = ulen, usub = unicode.sub, uchar = unicode.char, W = 80, H = 25,
  dirty = false, FILE = shell.resolve(({...})[1] or "/home/menu.cfg")}
M.CMAP = {red = 6, yellow = 5, orange = 10, green = 9, blue = 8, purple = 11, cyan = 12,
  brown = 13, gray = 4, darkred = 7}
M.K = {enter = 28, nenter = 156, back = 14, tab = 15, up = 200, down = 208, left = 203,
  right = 205, home = 199, ["end"] = 207, del = 211, ins = 210, pgup = 201, pgdn = 209,
  f2 = 60, f5 = 63}

-- drawing primitives shared by viewer and editor (colour cache saves GPU calls)
local DRAW, CLIP, cf, cb = true, 9999, nil, nil
function M.mode(d, c) DRAW, CLIP = d, c or 9999 end
function M.reset() cf, cb = nil, nil end
function M.put(x, y, s, f, b)
  if DRAW and y <= CLIP and s ~= "" then
    b, f = b or 0, f or 2
    if b ~= cb then gpu.setBackground(b, true) cb = b end
    if f ~= cf then gpu.setForeground(f, true) cf = f end
    gpu.set(x, y, s)
  end
end
function M.fill(x, y, w, h, b)
  if DRAW and w > 0 and h > 0 then
    if b ~= cb then gpu.setBackground(b, true) cb = b end
    gpu.fill(x, y, w, h, " ")
  end
end
function M.wrap(text, w, fn) -- calls fn(line, n) per wrapped line, returns count
  w = max(1, w)
  local n, line, usub = 0, "", M.usub
  local function emit(s) n = n + 1 if fn then fn(s, n) end end
  for word in tostring(text or ""):gmatch("%S+") do
    while ulen(word) > w do
      if line ~= "" then emit(line) line = "" end
      emit(usub(word, 1, w))
      word = usub(word, w + 1)
    end
    if word ~= "" then
      if line == "" then line = word
      elseif ulen(line) + 1 + ulen(word) <= w then line = line .. " " .. word
      else emit(line) line = word end
    end
  end
  if line ~= "" or n == 0 then emit(line) end
  return n
end
function M.alignX(x, w, s, align)
  if align == "center" then return x + max(0, floor((w - ulen(s)) / 2)) end
  return x
end
function M.yes(v) return v ~= "no" end

function M.save()
  local f, err = io.open(M.FILE, "w")
  if not f then return false, err end
  f:write(ser.serialize(M.menu))
  f:close()
  M.dirty = false
  return true
end

function M.applyRes(edit)
  local mw, mh = gpu.maxResolution()
  local w, h = mw, mh
  if edit then w, h = min(mw, 80), min(mh, 25)
  else
    local rw, rh = tostring(M.menu.res or ""):match("^(%d+)%s*[xX]%s*(%d+)$")
    if rw then w, h = max(30, min(mw, tonumber(rw))), max(10, min(mh, tonumber(rh))) end
  end
  local cw, ch = gpu.getResolution()
  if cw ~= w or ch ~= h then gpu.setResolution(w, h) end
  M.W, M.H = w, h
end

-- stream a part into the compiler 512 bytes at a time (no big source string)
local function run(name, ...)
  local h = io.open(DIR .. name, "r")
  if not h then error("missing file " .. DIR .. name, 0) end
  local f, e = load(function() return h:read(512) end, "=" .. name, "t", _ENV)
  h:close()
  if not f then error(e, 0) end
  local r = f(M, ...)
  f = nil
  if collectgarbage then pcall(collectgarbage) end
  return r
end

local function loadData()
  local f = io.open(M.FILE, "r")
  if not f then return end
  local s = f:read("*a")
  f:close()
  local good, t = pcall(ser.unserialize, s)
  if good and type(t) == "table" and type(t.sections) == "table" then return t end
end

local PALETTE = {[0] = 0x0E1116, 0x1C222B, 0xFFFFFF, 0xC9CDD3, 0x7E8794, 0xFFC72C,
  0xDA291C, 0x7A1209, 0x2D6CDF, 0x27A055, 0xF28C1E, 0x8456C9, 0x1FB5C4, 0x8A5A2B,
  0x2B3442, 0x3D5A8C}
local oW, oH = gpu.getResolution()
local oldPal = {}
for i = 0, 15 do oldPal[i] = gpu.getPaletteColor(i) gpu.setPaletteColor(i, PALETTE[i]) end

local good, err = xpcall(function()
  M.menu = loadData()
  if not M.menu then
    M.menu = run("menu_view.lua", "defaults")
    M.save()
  end
  while run("menu_view.lua") == "edit" do
    run("menu_edit.lua")
    M.save() -- saved after the editor is unloaded, to keep the memory peak low
  end
end, debug.traceback)

for i = 0, 15 do pcall(gpu.setPaletteColor, i, oldPal[i]) end
gpu.setResolution(oW, oH)
gpu.setForeground(0xFFFFFF)
gpu.setBackground(0x000000)
term.clear()
if not good then io.stderr:write(tostring(err) .. "\n") end
