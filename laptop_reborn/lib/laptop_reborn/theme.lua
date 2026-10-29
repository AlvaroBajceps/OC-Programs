-- Colour palettes and compiled pixel-art sprites for the laptop_reborn UI.
-- Sprites are plain ASCII cell maps: every non-"." key is resolved through the
-- sprite's `colors` table and compiled into horizontal runs of one colour.

local M = {}

M.PALETTES = {
  dark = {
    bg = 0x070B12,
    fg = 0xE6F1FF,
    dim = 0x7A8CA3,
    panel = 0x101A26,
    panel_hi = 0x18283A,
    border = 0x2C4258,
    head = 0x0C1520,
    accent = 0x35C7D6,
    ok = 0x3DDC84,
    warn = 0xFFC83D,
    bad = 0xFF5C6C,
    black = 0x000000,
  },
  light = {
    bg = 0xF4F7FB,
    fg = 0x15202B,
    dim = 0x5E7185,
    panel = 0xE4EBF3,
    panel_hi = 0xD2DEEA,
    border = 0x8FA6BC,
    head = 0xEAF1F8,
    accent = 0x0E7C93,
    ok = 0x12894B,
    warn = 0xB86A00,
    bad = 0xC62F45,
    black = 0x000000,
  },
}

M.SPRITES = {
  battery = {
    w = 7,
    h = 5,
    map = {
      ".####..",
      "#OOOO#T",
      "#OOOO#T",
      "#OOOO#T",
      ".####..",
    },
    colors = { ["#"] = 0x9FB4C8, O = 0x35D07F, T = 0x9FB4C8 },
  },
  bolt = {
    w = 5,
    h = 5,
    map = {
      "...##",
      "..##.",
      "#####",
      "..##.",
      ".##..",
    },
    colors = { ["#"] = 0xFFC83D },
  },
  arrow_up = {
    w = 5,
    h = 5,
    map = {
      "..#..",
      ".###.",
      "#####",
      "..#..",
      "..#..",
    },
    colors = { ["#"] = 0x3DDC84 },
  },
  arrow_down = {
    w = 5,
    h = 5,
    map = {
      "..#..",
      "..#..",
      "#####",
      ".###.",
      "..#..",
    },
    colors = { ["#"] = 0xFF5C6C },
  },
  transfer = {
    w = 7,
    h = 5,
    map = {
      ".....##",
      "#######",
      ".......",
      "#######",
      "##.....",
    },
    colors = { ["#"] = 0x35C7D6 },
  },
  wrench = {
    w = 7,
    h = 7,
    map = {
      ".####..",
      "#....#.",
      "#....#.",
      ".####..",
      "...#...",
      "..#....",
      ".#.....",
    },
    colors = { ["#"] = 0x9FB4C8 },
  },
  clock = {
    w = 5,
    h = 5,
    map = {
      ".###.",
      "#.#.#",
      "#.###",
      "#...#",
      ".###.",
    },
    colors = { ["#"] = 0xFFD166 },
  },
  wifi = {
    w = 7,
    h = 5,
    map = {
      "..###..",
      ".#...#.",
      "#..#..#",
      "...#...",
      "...#...",
    },
    colors = { ["#"] = 0x35C7D6 },
  },
  chart = {
    w = 7,
    h = 5,
    map = {
      "......c",
      "....b.c",
      "..a.b.c",
      "..a.b.c",
      "..a.b.c",
    },
    colors = { a = 0x3DDC84, b = 0xFFC83D, c = 0x35C7D6 },
  },
  warning = {
    w = 5,
    h = 5,
    map = {
      "..#..",
      ".###.",
      "#.!.#",
      "#.!.#",
      "#####",
    },
    colors = { ["#"] = 0xFFC83D, ["!"] = 0xFF6B6B },
  },
  check = {
    w = 5,
    h = 5,
    map = {
      "....#",
      "...#.",
      "#.#..",
      ".#...",
      ".....",
    },
    colors = { ["#"] = 0x3DDC84 },
  },
}

---@param sprite table
---@return table
function M.compile(sprite)
  local w = math.max(1, math.floor(tonumber(sprite.w) or 1))
  local h = math.max(1, math.floor(tonumber(sprite.h) or 1))
  local map = sprite.map or {}
  local colors = sprite.colors or {}
  local runs = {}
  for row = 1, h do
    local line = map[row] or ""
    local limit = math.min(#line, w)
    local col = 1
    while col <= limit do
      local key = line:sub(col, col)
      local color = colors[key]
      if color then
        local span = 1
        while col + span <= limit and line:sub(col + span, col + span) == key do
          span = span + 1
        end
        runs[#runs + 1] = { x = col, y = row, w = span, h = 1, color = color }
        col = col + span
      else
        col = col + 1
      end
    end
  end
  return { w = w, h = h, runs = runs }
end

M.COMPILED = {
  battery = M.compile(M.SPRITES.battery),
  bolt = M.compile(M.SPRITES.bolt),
  arrow_up = M.compile(M.SPRITES.arrow_up),
  arrow_down = M.compile(M.SPRITES.arrow_down),
  transfer = M.compile(M.SPRITES.transfer),
  wrench = M.compile(M.SPRITES.wrench),
  clock = M.compile(M.SPRITES.clock),
  wifi = M.compile(M.SPRITES.wifi),
  chart = M.compile(M.SPRITES.chart),
  warning = M.compile(M.SPRITES.warning),
  check = M.compile(M.SPRITES.check),
}

return M
