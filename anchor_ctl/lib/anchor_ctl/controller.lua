---@class anchor_ctl.AnchorInfo
---@field present boolean|nil
---@field known boolean|nil
---@field disabled boolean|nil
---@field kind string|nil
---@field fuel_ticks number|nil
---@field fuel_count number|nil
---@field fuel_name string|nil
---@field address string|nil
---@field count number|nil
---@field ambiguous boolean|nil
---@field error string|nil

---@class anchor_ctl.DrawerInfo
---@field present boolean|nil
---@field count number|nil
---@field capacity number|nil
---@field item_count number|nil
---@field item_name string|nil
---@field pearls number|nil
---@field is_pearls boolean|nil
---@field percent number|nil
---@field slots number|nil
---@field address string|nil
---@field ambiguous boolean|nil
---@field error string|nil

---@class anchor_ctl.ControllerDeps
---@field cfg table
---@field anchor table
---@field drawer table
---@field redstone table
---@field state table
---@field now fun(): number
---@field log fun(level: string, message: string)

local ANCHOR_KINDS = {
  world = true,
  admin = true,
  personal = true,
  passive = true,
}

local ALL_CHANGED = {
  "chunkloading",
  "pearls",
  "anchor_fuel",
  "problem",
  "boot_mode",
  "deployment",
}

local DEPLOYMENT_FIELDS = {
  "dimension_id",
  "dimension_name",
  "chunks_chunkloaded",
  "anchor_address",
  "drawer_address",
  "redstone_side",
  "enabled_level",
  "disabled_level",
}

local function add_reason(reasons, seen, reason)
  if reason and not seen[reason] then
    seen[reason] = true
    reasons[#reasons + 1] = reason
  end
end

---@param deps anchor_ctl.ControllerDeps
---@return table
return function(deps)
  local cfg = deps.cfg
  local anchor = deps.anchor
  local drawer = deps.drawer
  local redstone = deps.redstone
  local state = deps.state
  local now = deps.now
  local log = deps.log

  local changed = {}

  local mode = "keep_state"
  local desired = nil
  local actual = nil
  ---@type anchor_ctl.AnchorInfo|nil
  local anchor_info = nil
  ---@type anchor_ctl.DrawerInfo|nil
  local drawer_info = nil
  local redstone_available = false
  local redstone_level = nil
  local mismatch = false
  local mismatch_since = nil
  local next_poll = 0
  local last_view = nil
  local state_save_failed = false
  local state_load_failed = false
  local redstone_write_failed = false

  local controller = {
    changed = changed,
  }

  local function mark_all_changed()
    for _, key in ipairs(ALL_CHANGED) do
      changed[key] = true
    end
  end

  local function read_safe(wrapper)
    if not wrapper or type(wrapper.read) ~= "function" then
      return nil
    end
    local ok, info = pcall(wrapper.read)
    if ok and type(info) == "table" then
      return info
    end
    return nil
  end

  local function is_anchor_present()
    return anchor_info ~= nil and anchor_info.present == true
  end

  local function is_drawer_present()
    return drawer_info ~= nil and drawer_info.present == true
  end

  local function compute_actual()
    if anchor_info and anchor_info.known == true then
      return not (anchor_info.disabled == true)
    end
    return nil
  end

  local function derive_problems()
    local reasons = {}
    local seen = {}
    ---@type anchor_ctl.AnchorInfo
    local ai = anchor_info or {}
    ---@type anchor_ctl.DrawerInfo
    local di = drawer_info or {}

    if not is_anchor_present() then
      if ai.ambiguous then
        add_reason(reasons, seen, "anchor ambiguous (" .. tostring(ai.count or 0) .. " found)")
      else
        add_reason(reasons, seen, "anchor unavailable")
      end
    else
      local kind = ai.kind
      if not ANCHOR_KINDS[kind] then
        add_reason(reasons, seen, "anchor type " .. (kind or "missing"))
      end

      if not ai.known then
        add_reason(reasons, seen, "anchor read failed")
      end

      if ai.known and desired ~= false and (ai.fuel_count or 0) == 0 then
        add_reason(reasons, seen, "anchor has no fuel")
      end
    end

    local drawer_slot_error = di.error == "drawer slot out of range"
    if drawer_slot_error then
      add_reason(reasons, seen, "drawer slot out of range")
    end
    if not is_drawer_present() then
      if not drawer_slot_error then
        if di.ambiguous then
          add_reason(reasons, seen, "drawer ambiguous (" .. tostring(di.count or 0) .. " found)")
        else
          add_reason(reasons, seen, "drawer unavailable")
        end
      end
    elseif di.is_pearls == false and (di.item_count or 0) > 0 then
      add_reason(reasons, seen, "drawer contains " .. (di.item_name or "unknown item") .. ", not ender pearls")
    end

    if not redstone_available then
      add_reason(reasons, seen, "redstone card missing")
    end
    if redstone_write_failed then
      add_reason(reasons, seen, "redstone write failed")
    end
    if mismatch then
      add_reason(reasons, seen, "anchor did not follow redstone")
    end
    if state_save_failed then
      add_reason(reasons, seen, "state save failed")
    end
    if state_load_failed then
      add_reason(reasons, seen, "state load failed")
    end

    return reasons
  end

  function controller.problems()
    return derive_problems()
  end

  function controller.view()
    local reasons = derive_problems()
    ---@type anchor_ctl.AnchorInfo
    local ai = anchor_info or {}
    ---@type anchor_ctl.DrawerInfo
    local di = drawer_info or {}
    local deployment = {
      dimension_id = cfg.DEPLOYMENT.DIMENSION_ID,
      dimension_name = cfg.DEPLOYMENT.DIMENSION_NAME,
      chunks_chunkloaded = cfg.DEPLOYMENT.CHUNKS_CHUNKLOADED,
      anchor_address = ai.address or cfg.ANCHOR_ADDRESS,
      drawer_address = di.address or cfg.DRAWER_ADDRESS,
      redstone_side = cfg.REDSTONE_SIDE,
      enabled_level = cfg.ENABLED_LEVEL,
      disabled_level = cfg.DISABLED_LEVEL,
    }

    local view = {
      chunkloading = actual,
      pearls = is_drawer_present() and di.pearls or nil,
      pearls_attributes = {
        capacity = di.capacity,
        percent = di.percent,
        item_count = di.item_count,
        item_name = di.item_name,
        is_pearls = di.is_pearls,
        slots = di.slots,
        error = di.error,
      },
      anchor_fuel = is_anchor_present() and ai.fuel_count or nil,
      anchor_fuel_attributes = {
        ticks = ai.fuel_ticks,
        fuel_name = ai.fuel_name,
        kind = ai.kind,
        disabled = ai.disabled,
        address = ai.address,
        error = ai.error,
      },
      boot_mode = mode,
      problem = #reasons > 0,
      problem_attributes = {
        reasons = reasons,
        anchor_address = ai.address or cfg.ANCHOR_ADDRESS,
        drawer_address = di.address or cfg.DRAWER_ADDRESS,
        redstone_level = redstone_level,
        desired = desired,
        error = reasons[1],
      },
      deployment = deployment,
      desired = desired,
      redstone_level = redstone_level,
    }

    return view
  end

  local function refresh_redstone()
    redstone_available = (redstone.available and redstone.available() == true) or false
    redstone_level = nil
    if redstone_available and redstone.get_level then
      local level = redstone.get_level()
      if type(level) == "number" then
        redstone_level = level
      end
    end
  end

  local function deep_field_equal(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then
      return a == b
    end
    for _, field in ipairs(DEPLOYMENT_FIELDS) do
      if a[field] ~= b[field] then
        return false
      end
    end
    return true
  end

  local function scalar_table_equal(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then
      return a == b
    end
    for field, value in pairs(a) do
      if b[field] ~= value then
        return false
      end
    end
    for field in pairs(b) do
      if a[field] == nil then
        return false
      end
    end
    return true
  end

  local function array_equal(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then
      return a == b
    end
    if #a ~= #b then
      return false
    end
    for index = 1, #a do
      if a[index] ~= b[index] then
        return false
      end
    end
    return true
  end

  local function problem_attributes_equal(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then
      return a == b
    end
    return array_equal(a.reasons, b.reasons)
      and a.anchor_address == b.anchor_address
      and a.drawer_address == b.drawer_address
      and a.redstone_level == b.redstone_level
      and a.desired == b.desired
      and a.error == b.error
  end

  local function view_field_equal(key, new_view, old_view)
    if key == "deployment" then
      return deep_field_equal(new_view.deployment, old_view.deployment)
    elseif key == "problem" then
      return new_view.problem == old_view.problem
        and problem_attributes_equal(new_view.problem_attributes, old_view.problem_attributes)
    elseif key == "pearls" then
      return new_view.pearls == old_view.pearls
        and scalar_table_equal(new_view.pearls_attributes, old_view.pearls_attributes)
    elseif key == "anchor_fuel" then
      return new_view.anchor_fuel == old_view.anchor_fuel
        and scalar_table_equal(new_view.anchor_fuel_attributes, old_view.anchor_fuel_attributes)
    end
    return new_view[key] == old_view[key]
  end

  function controller.boot()
    state_load_failed = false
    state_save_failed = false
    redstone_write_failed = false

    local saved, load_err = state.load(cfg.STATE_FILE)
    if load_err then
      state_load_failed = true
      log("warn", "state load failed: " .. tostring(load_err))
    end

    local saved_mode = nil
    if type(saved) == "table" then
      saved_mode = saved.boot_mode
    end

    mode = state.normalize_mode(saved_mode) or state.normalize_mode(cfg.BOOT_MODE) or "keep_state"

    local save_ok, save_err = state.save(cfg.STATE_FILE, { boot_mode = mode })
    if not save_ok then
      state_save_failed = true
      log("warn", "state save failed: " .. tostring(save_err))
    end

    anchor_info = read_safe(anchor)
    drawer_info = read_safe(drawer)
    refresh_redstone()

    local resolution = state.resolve_boot(mode, anchor_info or { known = false }, cfg)
    desired = resolution.enabled

    if redstone_available then
      local ok, err = redstone.set_enabled(desired)
      if not ok then
        redstone_write_failed = true
        log("warn", "redstone write failed: " .. tostring(err))
      end
      refresh_redstone()
    end

    actual = compute_actual()
    mismatch = false
    mismatch_since = nil
    next_poll = now() + cfg.COMMAND_SETTLE

    mark_all_changed()
    last_view = controller.view()
  end

  function controller.command(name, value)
    if name == "chunkloading" then
      if not redstone.available or not redstone.available() then
        redstone_available = false
        return false, "redstone card missing"
      end
      redstone_available = true

      local enabled = value == true
      local ok, err = redstone.set_enabled(enabled)
      if not ok then
        redstone_write_failed = true
        return false, err
      end

      redstone_write_failed = false
      desired = enabled
      mismatch = false
      mismatch_since = nil
      next_poll = now() + cfg.COMMAND_SETTLE
      refresh_redstone()
      return true
    end

    if name == "boot_mode" then
      local normalized = state.normalize_mode(value)
      if not normalized then
        return false, "invalid boot mode"
      end

      local previous = mode
      mode = normalized
      local ok, err = state.save(cfg.STATE_FILE, { boot_mode = mode })
      if not ok then
        mode = previous
        state_save_failed = true
        return false, err
      end

      state_save_failed = false
      changed.boot_mode = true
      return true
    end

    return false, "unknown command"
  end

  function controller.tick(at)
    if at < next_poll then
      return
    end

    anchor_info = read_safe(anchor)
    drawer_info = read_safe(drawer)
    refresh_redstone()

    if
      redstone_write_failed
      and redstone_available
      and desired ~= nil
      and redstone_level == redstone.level_for(desired)
    then
      redstone_write_failed = false
    end

    actual = compute_actual()

    if actual == nil or actual == desired then
      mismatch = false
      mismatch_since = nil
    elseif redstone_level ~= nil and redstone_level == redstone.level_for(desired) then
      if not mismatch_since then
        mismatch_since = at
      end
      if at - mismatch_since >= cfg.MISMATCH_TIMEOUT then
        mismatch = true
      end
    else
      if desired ~= actual then
        log("info", "external redstone override: desired " .. tostring(desired) .. " -> " .. tostring(actual))
        desired = actual
      end
      mismatch = false
      mismatch_since = nil
    end

    next_poll = at + cfg.POLL_INTERVAL

    local new_view = controller.view()
    if last_view then
      for _, key in ipairs(ALL_CHANGED) do
        if not view_field_equal(key, new_view, last_view) then
          changed[key] = true
        end
      end
    end
    last_view = new_view
  end

  return controller
end
