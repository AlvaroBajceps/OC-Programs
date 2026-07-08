-- Teleporter TUI: every screen, hit-testing, and touch/keyboard input.
-- Renders into display's back-buffer (render() flips at the end). Hit regions
-- are rebuilt on each render and consumed by on_touch. Owns rename_buffer and
-- drives rename_mode via the shared app table; commits a rename through
-- config.set_name + protocol.broadcast_rename.

local computer = require("computer")

return function(deps)
  local config = deps.config
  local display = deps.display
  local peers = deps.peers
  local ae2 = deps.ae2
  local redstone = deps.redstone
  local protocol = deps.protocol
  local app = deps.app

  local gpu = display.get_gpu()
  local scr_w, scr_h = display.get_dims()
  local OUTCOME = config.OUTCOME

  local hit_regions = {}
  local rename_buffer = ""

  local function find_hit_region(x, y)
    for _, r in ipairs(hit_regions) do
      if x >= r.x1 and x <= r.x2 and y >= r.y1 and y <= r.y2 then
        return r
      end
    end
    return nil
  end

  local function outcome_label(code)
    if code == OUTCOME.CONFIRMED then
      return "TELEPORT CONFIRMED", 0x00FF66, 0x003311
    end
    if code == OUTCOME.USER_CANCEL then
      return "TELEPORT CANCELED", 0xFFAA00, 0x332200
    end
    if code == OUTCOME.HW_FAULT then
      return "HARDWARE FAULT", 0xFF4444, 0x330000
    end
    return "TELEPORT FAILED", 0xFF4444, 0x330000
  end

  local function render_normal()
    hit_regions = {}
    gpu.setBackground(0x000000)
    gpu.fill(1, 1, scr_w, scr_h, " ")

    gpu.setBackground(0x1A1A2E)
    gpu.setForeground(0x00BFFF)
    gpu.fill(1, 1, scr_w, 1, " ")
    display.draw_text_centered(1, 1, scr_w, " AE2 Spatial Teleporter ", 0x00BFFF, 0x1A1A2E)

    local rename_label = config.get_name() .. "  \226\156\142"
    local rename_label_w = #rename_label
    local rename_x = scr_w - rename_label_w - 1
    gpu.setBackground(0x1A1A2E)
    gpu.setForeground(0x00FF88)
    gpu.set(rename_x, 1, rename_label)
    hit_regions[#hit_regions + 1] = {
      type = "rename",
      x1 = rename_x,
      y1 = 1,
      x2 = scr_w,
      y2 = 1,
    }

    gpu.setBackground(0x333366)
    gpu.fill(1, 2, scr_w, 1, " ")
    gpu.setBackground(0x000000)

    local sorted = peers.all_sorted()
    local list_y = 3
    local box_w = 22
    local box_h = 5
    local gap = 2
    local margin = 2
    local max_cols = math.floor((scr_w - margin) / (box_w + gap))
    if max_cols < 1 then
      max_cols = 1
    end

    if #sorted == 0 then
      gpu.setForeground(0x888888)
      display.draw_text_centered(1, list_y + 3, scr_w, "Searching for peers on the network...", 0x888888, 0x000000)
    else
      for i, peer in ipairs(sorted) do
        local col = (i - 1) % max_cols
        local row = math.floor((i - 1) / max_cols)
        local bx = margin + col * (box_w + gap)
        local by = list_y + row * (box_h + gap)
        if by + box_h - 1 <= list_y + 14 then
          local is_sel = (peers.get_selected() == peer.addr)
          local border_color
          local bg_color
          local name_fg
          local status_fg
          if not peer.online then
            border_color = 0x444444
            bg_color = 0x000000
            name_fg = 0x666666
            status_fg = 0x555555
          elseif not peer.healthy then
            border_color = 0xDD0000
            bg_color = 0x220000
            name_fg = 0xFFAAAA
            status_fg = 0xFF4444
          elseif is_sel then
            border_color = 0x00DD00
            bg_color = 0x003300
            name_fg = 0x00FF00
            status_fg = 0x00FF00
          else
            border_color = 0x008800
            bg_color = 0x000000
            name_fg = 0xCCFFCC
            status_fg = 0x00AA00
          end
          display.draw_box(bx, by, box_w, box_h, border_color, bg_color)
          gpu.setBackground(bg_color)
          gpu.setForeground(name_fg)
          display.draw_text_centered(bx, by + 1, box_w, peer.name, name_fg, bg_color)
          gpu.setForeground(status_fg)
          local status_text = peer.online and (peer.healthy and " LIVE " or "UNHEALTHY") or "OFFLINE"
          display.draw_text_centered(bx, by + 2, box_w, status_text, status_fg, bg_color)
          if peer.addr == config.MY_ADDR then
            gpu.setForeground(0x888888)
            display.draw_text_centered(bx, by + 3, box_w, "(you)", 0x888888, bg_color)
          end
          hit_regions[#hit_regions + 1] = {
            type = "peer",
            addr = peer.addr,
            x1 = bx,
            y1 = by,
            x2 = bx + box_w - 1,
            y2 = by + box_h - 1,
            online = peer.online,
          }
        end
      end
    end

    local status_y = scr_h - 6
    gpu.setBackground(0x0A0A0A)
    gpu.fill(1, status_y, scr_w, 3, " ")

    local our_power = ae2.get_power()
    local power_ok = our_power >= config.AE_POWER_REQUIRED
    local power_color = power_ok and 0x00FF00 or 0xFF4444
    gpu.setBackground(0x0A0A0A)
    gpu.setForeground(0x888888)
    gpu.set(2, status_y, "Power:")
    gpu.setForeground(power_color)
    gpu.set(
      10,
      status_y,
      string.format("%.1fM AE / %.1fM AE req", our_power / 1000000, config.AE_POWER_REQUIRED / 1000000)
    )
    gpu.set(scr_w - 5, status_y, power_ok and " OK " or " LOW")

    local live_count = 0
    local unhealthy_count = 0
    local offline_count = 0
    for _, p in pairs(peers.all()) do
      if not p.online then
        offline_count = offline_count + 1
      elseif not p.healthy then
        unhealthy_count = unhealthy_count + 1
      else
        live_count = live_count + 1
      end
    end
    gpu.setForeground(0x888888)
    local peers_line = string.format("Peers: %d live / %d offline", live_count, offline_count)
    if unhealthy_count > 0 then
      peers_line = peers_line .. string.format(" / %d unhealthy", unhealthy_count)
    end
    gpu.set(2, status_y + 1, peers_line)

    local state_text = "Ready"
    if #sorted == 0 then
      state_text = "Discovering..."
    elseif peers.get_selected() then
      local sel = peers.get(peers.get_selected())
      state_text = "Selected: " .. (sel and sel.name or "?")
    end
    gpu.setForeground(0x00FF00)
    gpu.set(2, status_y + 2, "Status: " .. state_text)

    local btn_y = scr_h - 2
    local btn_h = 3
    local btn_text = " REQUEST TELEPORTER "
    local btn_w = #btn_text + 4
    local btn_x = math.floor((scr_w - btn_w) / 2)
    local btn_enabled = (
      peers.get_selected() ~= nil
      and peers.get(peers.get_selected())
      and peers.get(peers.get_selected()).online
    )
    local btn_fg = btn_enabled and 0x000000 or 0x666666
    local btn_bg = btn_enabled and 0x00DD00 or 0x222222
    local btn_border = btn_enabled and 0x00FF00 or 0x444444
    display.draw_filled_button(btn_x, btn_y - btn_h + 1, btn_w, btn_h, btn_text, btn_fg, btn_bg, btn_border)
    if btn_enabled then
      hit_regions[#hit_regions + 1] = {
        type = "button",
        action = "request",
        x1 = btn_x,
        y1 = btn_y - btn_h + 1,
        x2 = btn_x + btn_w - 1,
        y2 = btn_y,
      }
    end
  end

  local function render_requesting(st)
    hit_regions = {}
    gpu.setBackground(0x000000)
    gpu.fill(1, 1, scr_w, scr_h, " ")

    gpu.setBackground(0x002200)
    gpu.setForeground(0x00FF00)
    gpu.fill(1, 1, scr_w, 1, " ")
    display.draw_text_centered(1, 1, scr_w, " REQUESTING TELEPORT... ", 0x00FF00, 0x002200)

    local dest_name = st.tp_active_dest and peers.get(st.tp_active_dest) and peers.get(st.tp_active_dest).name
      or "unknown"
    gpu.setBackground(0x000000)
    gpu.setForeground(0xFFFFFF)
    display.draw_text_centered(1, 5, scr_w, "Destination: " .. dest_name, 0xFFFFFF, 0x000000)
    gpu.setForeground(0x888888)
    display.draw_text_centered(1, 7, scr_w, "Awaiting destination confirmation...", 0x888888, 0x000000)
    display.draw_text_centered(1, 8, scr_w, "Checking power availability...", 0x888888, 0x000000)

    local cancel_y = scr_h - 3
    local cancel_w = 20
    local cancel_x = math.floor((scr_w - cancel_w) / 2)
    display.draw_filled_button(cancel_x, cancel_y, cancel_w, 3, "  CANCEL  ", 0xFFFFFF, 0xAA0000, 0xFF4444)
    hit_regions[#hit_regions + 1] = {
      type = "button",
      action = "cancel",
      x1 = cancel_x,
      y1 = cancel_y,
      x2 = cancel_x + cancel_w - 1,
      y2 = cancel_y + 2,
    }
  end

  local function render_countdown(st)
    hit_regions = {}
    gpu.setBackground(0x1A0000)
    gpu.fill(1, 1, scr_w, scr_h, " ")

    gpu.setBackground(0x330000)
    gpu.setForeground(0xFF4444)
    gpu.fill(1, 1, scr_w, 1, " ")
    display.draw_text_centered(1, 1, scr_w, " WARNING: TELEPORTATION IN PROGRESS ", 0xFF4444, 0x330000)

    local src_name = config.get_name()
    if st.tp_active_src and peers.get(st.tp_active_src) then
      src_name = peers.get(st.tp_active_src).name
    end
    local dest_name = ""
    if st.tp_active_dest and peers.get(st.tp_active_dest) then
      dest_name = peers.get(st.tp_active_dest).name
    elseif st.tp_active_dest == config.MY_ADDR then
      dest_name = config.get_name()
    end
    gpu.setBackground(0x1A0000)
    gpu.setForeground(0xFFAA00)
    display.draw_text_centered(1, 3, scr_w, src_name .. "  \226\150\182  " .. dest_name, 0xFFAA00, 0x1A0000)

    local bar_x = math.floor(scr_w / 2) - 15
    local bar_y = 7
    gpu.setBackground(0x330000)
    gpu.fill(bar_x, bar_y, 30, 3, " ")

    local pct = st.tp_countdown_remaining / config.COUNTDOWN_DURATION
    local fill_w = math.floor(30 * pct)
    if fill_w > 0 then
      gpu.setBackground(pct > 0.3 and 0xFF0000 or 0xFF4400)
      gpu.fill(bar_x, bar_y, fill_w, 3, " ")
    end

    gpu.setBackground(0x000000)
    gpu.setForeground(0xFFFFFF)
    display.draw_text_centered(1, bar_y + 1, scr_w, "COUNTDOWN: " .. st.tp_countdown_remaining, 0xFFFFFF, 0x000000)

    gpu.setForeground(0xFF2222)
    gpu.setBackground(0x1A0000)
    display.draw_text_centered(1, 6, scr_w, tostring(st.tp_countdown_remaining), 0xFF2222, 0x1A0000)

    local dest_stale = st.tp_dest_power_ts == 0 or (computer.uptime() - st.tp_dest_power_ts) > config.POWER_STALE_SEC
    gpu.setForeground(0xAAAAAA)
    gpu.setBackground(0x1A0000)
    display.draw_text_centered(
      1,
      12,
      scr_w,
      string.format(
        "Source Power: %s %.1fM AE (%s)",
        st.tp_src_power_ok and "\226\156\148" or "\226\156\150",
        st.tp_src_power_val / 1000000,
        st.tp_src_power_ok and "OK" or "INSUFFICIENT"
      ),
      st.tp_src_power_ok and 0x00FF00 or 0xFF4444,
      0x1A0000
    )
    display.draw_text_centered(
      1,
      13,
      scr_w,
      string.format(
        "Dest Power:   %s %.1fM AE (%s%s)",
        st.tp_dest_power_ok and "\226\156\148" or "\226\156\150",
        st.tp_dest_power_val / 1000000,
        st.tp_dest_power_ok and "OK" or "INSUFFICIENT",
        dest_stale and " - STALE" or ""
      ),
      st.tp_dest_power_ok and 0x00FF00 or 0xFF4444,
      0x1A0000
    )
    display.draw_text_centered(1, 14, scr_w, "Dest Confirmed: \226\156\148", 0x00FF00, 0x1A0000)

    local cancel_y = scr_h - 3
    local cancel_w = 20
    local cancel_x = math.floor((scr_w - cancel_w) / 2)
    display.draw_filled_button(cancel_x, cancel_y, cancel_w, 3, "  CANCEL  ", 0xFFFFFF, 0xAA0000, 0xFF4444)
    hit_regions[#hit_regions + 1] = {
      type = "button",
      action = "cancel",
      x1 = cancel_x,
      y1 = cancel_y,
      x2 = cancel_x + cancel_w - 1,
      y2 = cancel_y + 2,
    }
    gpu.setForeground(0x888888)
    gpu.setBackground(0x1A0000)
    display.draw_text_centered(1, scr_h, scr_w, "Press CANCEL on any network computer to abort", 0x888888, 0x1A0000)
  end

  local function render_rename()
    hit_regions = {}
    gpu.setBackground(0x000000)
    gpu.fill(1, 1, scr_w, scr_h, " ")

    local field_w = 50
    local field_x = math.floor((scr_w - field_w) / 2)
    local field_y = 2
    display.draw_box(field_x, field_y, field_w, 3, 0x00BFFF, 0x000000)
    gpu.setBackground(0x000000)
    gpu.setForeground(0xFFFFFF)
    local display_buf = rename_buffer
    if #rename_buffer < config.MAX_NAME_LEN then
      display_buf = display_buf .. "_"
    end
    gpu.set(field_x + 1, field_y + 1, display_buf)
    gpu.setForeground(0x888888)
    gpu.set(field_x + field_w - 6, field_y + 1, string.format("%2d/%d", #rename_buffer, config.MAX_NAME_LEN))

    local key_w = 5
    local key_h = 3
    local gap = 1
    local kb_y = 6
    local rows = {
      "1234567890",
      "QWERTYUIOP",
      "ASDFGHJKL",
      "ZXCVBNM",
    }
    for r, row in ipairs(rows) do
      local row_w = #row * key_w + (#row - 1) * gap
      local row_x = math.floor((scr_w - row_w) / 2)
      local y = kb_y + (r - 1) * (key_h + gap)
      for i = 1, #row do
        local ch = row:sub(i, i)
        local x = row_x + (i - 1) * (key_w + gap)
        display.draw_filled_button(x, y, key_w, key_h, " " .. ch .. " ", 0xFFFFFF, 0x222266, 0x444488)
        hit_regions[#hit_regions + 1] = {
          type = "kb_key",
          char = ch,
          x1 = x,
          y1 = y,
          x2 = x + key_w - 1,
          y2 = y + key_h - 1,
        }
      end
    end

    local spec_y = kb_y + 4 * (key_h + gap)
    local space_w = 15
    local bs_w = 9
    local sym_w = 5
    local cancel_w = 11
    local enter_w = 15
    local total_spec = space_w + gap + bs_w + gap + sym_w + gap + sym_w + gap + cancel_w + gap + enter_w
    local spec_x = math.floor((scr_w - total_spec) / 2)
    local cx = spec_x
    display.draw_filled_button(cx, spec_y, space_w, key_h, "  SPACE  ", 0xFFFFFF, 0x444488, 0x6666AA)
    hit_regions[#hit_regions + 1] = {
      type = "kb_space",
      x1 = cx,
      y1 = spec_y,
      x2 = cx + space_w - 1,
      y2 = spec_y + key_h - 1,
    }
    cx = cx + space_w + gap
    display.draw_filled_button(cx, spec_y, bs_w, key_h, " BKSP ", 0xFFFFFF, 0xAA3333, 0xFF4444)
    hit_regions[#hit_regions + 1] = {
      type = "kb_back",
      x1 = cx,
      y1 = spec_y,
      x2 = cx + bs_w - 1,
      y2 = spec_y + key_h - 1,
    }
    cx = cx + bs_w + gap
    display.draw_filled_button(cx, spec_y, sym_w, key_h, " _ ", 0xFFFFFF, 0x222266, 0x444488)
    hit_regions[#hit_regions + 1] = {
      type = "kb_key",
      char = "_",
      x1 = cx,
      y1 = spec_y,
      x2 = cx + sym_w - 1,
      y2 = spec_y + key_h - 1,
    }
    cx = cx + sym_w + gap
    display.draw_filled_button(cx, spec_y, sym_w, key_h, " - ", 0xFFFFFF, 0x222266, 0x444488)
    hit_regions[#hit_regions + 1] = {
      type = "kb_key",
      char = "-",
      x1 = cx,
      y1 = spec_y,
      x2 = cx + sym_w - 1,
      y2 = spec_y + key_h - 1,
    }
    cx = cx + sym_w + gap
    display.draw_filled_button(cx, spec_y, cancel_w, key_h, " CANCEL ", 0xFFFFFF, 0xAA0000, 0xFF4444)
    hit_regions[#hit_regions + 1] = {
      type = "kb_cancel",
      x1 = cx,
      y1 = spec_y,
      x2 = cx + cancel_w - 1,
      y2 = spec_y + key_h - 1,
    }
    cx = cx + cancel_w + gap
    local can_commit = #rename_buffer > 0
    display.draw_filled_button(
      cx,
      spec_y,
      enter_w,
      key_h,
      " ENTER ",
      can_commit and 0x000000 or 0x666666,
      can_commit and 0x00AA00 or 0x222222,
      can_commit and 0x00FF00 or 0x444444
    )
    if can_commit then
      hit_regions[#hit_regions + 1] = {
        type = "kb_enter",
        x1 = cx,
        y1 = spec_y,
        x2 = cx + enter_w - 1,
        y2 = spec_y + key_h - 1,
      }
    end
  end

  local function render_cooldown(st)
    hit_regions = {}
    gpu.setBackground(0x000000)
    gpu.fill(1, 1, scr_w, scr_h, " ")

    local label, label_fg, banner_bg = outcome_label(st.tp_outcome)
    gpu.setBackground(banner_bg)
    gpu.setForeground(label_fg)
    gpu.fill(1, 1, scr_w, 3, " ")
    display.draw_text_centered(1, 2, scr_w, " " .. label .. " ", label_fg, banner_bg)

    gpu.setBackground(0x000000)
    gpu.setForeground(0xCCCCCC)
    local reason = st.tp_outcome_reason or ""
    if #reason > scr_w - 4 then
      reason = reason:sub(1, scr_w - 7) .. "..."
    end
    display.draw_text_centered(1, 5, scr_w, reason, 0xCCCCCC, 0x000000)

    local src_name = ""
    if st.tp_outcome_seq then
      local src_addr = st.tp_outcome_seq:match("^([^:]+):")
      if src_addr and peers.get(src_addr) then
        src_name = peers.get(src_addr).name
      elseif src_addr == config.MY_ADDR then
        src_name = config.get_name()
      end
    end
    if src_name ~= "" then
      gpu.setForeground(0x888888)
      display.draw_text_centered(1, 7, scr_w, "Sequence origin: " .. src_name, 0x888888, 0x000000)
    end

    local bar_w = math.min(60, scr_w - 8)
    local bar_x = math.floor((scr_w - bar_w) / 2)
    local bar_y = 11
    gpu.setBackground(0x222222)
    gpu.fill(bar_x, bar_y, bar_w, 3, " ")
    local pct = st.cooldown_total > 0 and (st.cooldown_remaining / st.cooldown_total) or 0
    local fill_w = math.floor(bar_w * pct)
    if fill_w > 0 then
      gpu.setBackground(label_fg)
      gpu.fill(bar_x, bar_y, fill_w, 3, " ")
    end
    gpu.setBackground(0x000000)
    gpu.setForeground(0xFFFFFF)
    display.draw_text_centered(1, bar_y + 1, scr_w, "COOLDOWN  " .. st.cooldown_remaining .. "s", 0xFFFFFF, 0x000000)

    gpu.setForeground(0x666666)
    local sync_state = st.cooldown_authority and "BROADCASTING" or "SYNCED"
    display.draw_text_centered(1, bar_y + 5, scr_w, "timer: " .. sync_state, 0x666666, 0x000000)

    gpu.setForeground(0x555555)
    display.draw_text_centered(
      1,
      scr_h,
      scr_w,
      "All network computers are locked until cooldown ends",
      0x555555,
      0x000000
    )
  end

  local function render_unhealthy(reason)
    hit_regions = {}
    gpu.setBackground(0x000000)
    gpu.setForeground(0xFF0000)
    gpu.fill(1, 1, scr_w, scr_h, " ")

    gpu.setBackground(0x330000)
    gpu.setForeground(0xFF4444)
    gpu.fill(1, 1, scr_w, 3, " ")
    display.draw_text_centered(1, 2, scr_w, " !! SYSTEM UNHEALTHY !! ", 0xFF4444, 0x330000)

    gpu.setBackground(0x000000)
    gpu.setForeground(0xFFAA00)
    display.draw_text_centered(1, 5, scr_w, "Teleporter locked until resolved", 0xFFAA00, 0x000000)

    gpu.setForeground(0xFFFFFF)
    local reason_trimmed = reason or "Unknown cause"
    if #reason_trimmed > scr_w - 4 then
      reason_trimmed = reason_trimmed:sub(1, scr_w - 7) .. "..."
    end
    display.draw_text_centered(1, 7, scr_w, reason_trimmed, 0xFFFFFF, 0x000000)

    local detail_y = 10
    gpu.setForeground(0xAAAAAA)
    if not redstone.has_rs() then
      display.draw_text_centered(1, detail_y, scr_w, "[ ] Redstone I/O component: MISSING", 0xFF4444, 0x000000)
      detail_y = detail_y + 1
    else
      display.draw_text_centered(1, detail_y, scr_w, "[+] Redstone I/O component: present", 0x00FF00, 0x000000)
      detail_y = detail_y + 1
      if redstone.is_black_high() then
        display.draw_text_centered(1, detail_y, scr_w, "[+] Cable (Black): healthy", 0x00FF00, 0x000000)
      else
        display.draw_text_centered(
          1,
          detail_y,
          scr_w,
          "[ ] Cable (Black): not detected on any side",
          0xFF4444,
          0x000000
        )
      end
      detail_y = detail_y + 1
      display.draw_text_centered(
        1,
        detail_y,
        scr_w,
        redstone.is_red_high() and "[+] Teleporter (Red): HERE" or "[ ] Teleporter (Red): elsewhere",
        redstone.is_red_high() and 0xFFAA00 or 0x888888,
        0x000000
      )
      detail_y = detail_y + 1
    end

    local red_count = redstone.count_red_high()
    if red_count > 1 then
      detail_y = detail_y + 1
      gpu.setForeground(0xFF4444)
      display.draw_text_centered(
        1,
        detail_y,
        scr_w,
        "CONFLICT: " .. red_count .. " nodes hold Red high (expected 0 or 1)",
        0xFF4444,
        0x000000
      )
      detail_y = detail_y + 1
      gpu.setForeground(0xCCCCCC)
      for _, p in pairs(peers.all()) do
        if p.online and p.has_tp then
          display.draw_text_centered(1, detail_y, scr_w, "  - " .. p.name, 0xCCCCCC, 0x000000)
          detail_y = detail_y + 1
        end
      end
      if redstone.is_black_high() and redstone.is_red_high() then
        display.draw_text_centered(
          1,
          detail_y,
          scr_w,
          "  - " .. config.get_name() .. " (this node)",
          0xCCCCCC,
          0x000000
        )
        detail_y = detail_y + 1
      end
    end

    gpu.setForeground(0x555555)
    display.draw_text_centered(
      1,
      scr_h,
      scr_w,
      "Fix the hardware/wiring and the screen will recover automatically",
      0x555555,
      0x000000
    )
  end

  local function render()
    display.set_active_buffer(display.get_back_buffer())
    local unhealthy, reason = redstone.check_health()
    if unhealthy then
      render_unhealthy(reason)
    elseif app.rename_mode then
      render_rename()
    else
      local st = protocol.snapshot()
      if st.state == "IDLE" then
        render_normal()
      elseif st.state == "REQUESTING" then
        render_requesting(st)
      elseif st.state == "COUNTDOWN_LOCAL" or st.state == "COUNTDOWN_REMOTE" then
        render_countdown(st)
      elseif st.state == "COOLDOWN" then
        render_cooldown(st)
      end
    end
    display.flip()
  end

  local function on_touch(_, _, x, y)
    local region = find_hit_region(x, y)
    if not region then
      return
    end
    if app.rename_mode then
      if region.type == "kb_key" and #rename_buffer < config.MAX_NAME_LEN then
        rename_buffer = rename_buffer .. region.char
        app.dirty = true
        return
      end
      if region.type == "kb_space" and #rename_buffer < config.MAX_NAME_LEN then
        rename_buffer = rename_buffer .. " "
        app.dirty = true
        return
      end
      if region.type == "kb_back" and #rename_buffer > 0 then
        rename_buffer = rename_buffer:sub(1, -2)
        app.dirty = true
        return
      end
      if region.type == "kb_cancel" then
        app.rename_mode = false
        rename_buffer = ""
        app.dirty = true
        return
      end
      if region.type == "kb_enter" and #rename_buffer > 0 then
        config.set_name(rename_buffer)
        protocol.broadcast_rename()
        app.rename_mode = false
        rename_buffer = ""
        app.dirty = true
        return
      end
      return
    end
    local st = protocol.snapshot()
    if region.type == "rename" then
      if st.state == "IDLE" then
        app.rename_mode = true
        rename_buffer = config.get_name()
        app.dirty = true
      end
      return
    end
    if region.type == "peer" then
      if region.online and st.state == "IDLE" then
        peers.set_selected(region.addr)
      end
    elseif region.type == "button" then
      if region.action == "request" and peers.get_selected() and st.state == "IDLE" then
        protocol.request_teleport(peers.get_selected())
      elseif region.action == "cancel" then
        if st.state == "REQUESTING" or st.state == "COUNTDOWN_LOCAL" or st.state == "COUNTDOWN_REMOTE" then
          protocol.abort_user_cancel()
        end
      end
    end
  end

  local function on_key(_, _, _, char, code)
    if not app.rename_mode then
      return
    end

    if code == 28 then
      if #rename_buffer > 0 then
        config.set_name(rename_buffer)
        protocol.broadcast_rename()
      end
      app.rename_mode = false
      rename_buffer = ""
      app.dirty = true
      return
    end

    if code == 1 then
      app.rename_mode = false
      rename_buffer = ""
      app.dirty = true
      return
    end

    if code == 14 then
      rename_buffer = rename_buffer:sub(1, -2)
      app.dirty = true
      return
    end

    if char and char >= 32 and char <= 126 and #rename_buffer < config.MAX_NAME_LEN then
      rename_buffer = rename_buffer .. string.char(char)
      app.dirty = true
    end
  end

  return {
    render = render,
    on_touch = on_touch,
    on_key = on_key,
  }
end
