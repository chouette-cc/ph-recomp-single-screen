-- =============================================================================
-- Single Screen (Modern HUD) for The Legend of Zelda: Phantom Hourglass Recomp
-- =============================================================================
-- Full-screen primary touch display with a modern, translucent Picture-in-Picture
-- minimap overlay, automatic clean map border cropping in exploration, optional
-- dual-screen boss handling, and click-to-bind top-screen peeking.
-- Cross-platform Lua 5.4 mod (PC + Android, USA AZEE & Europe AZEP).

local gfx   = require("ph.gfx")
local cfg   = require("ph.config")
local input = require("ph.input")
local ds    = require("ph.ds")
local mem   = require("ph.mem")
local log   = require("ph.logger")

-- -----------------------------------------------------------------------------
-- Live-configurable settings (editable in F1 -> Mods without restarting)
-- -----------------------------------------------------------------------------
cfg.choice("mode",       "Display Mode",      { "Modern PiP", "Minimal (Peek)", "Side-by-Side", "Top Only", "Vanilla (Off)" }, 1)
cfg.choice("pip_corner", "Minimap Corner",    { "Top-Right", "Top-Left", "Bottom-Right", "Bottom-Left" }, 1)
cfg.int(   "pip_size",   "Minimap Size (%)",  20, 10, 48, 2)
cfg.float( "pip_alpha",  "Minimap Opacity",   0.83, 0.25, 1.00, 0.05)
cfg.choice("auto_boss",  "Dual-Screen Boss",  { "Auto Split", "Enlarge PiP", "Off" }, 3)
cfg.choice("tap_pip",    "Tap Minimap",       { "Cycle Size", "Toggle Hide", "Click-Through" }, 3)
cfg.hotkey("peek_key",   "Peek Hotkey",       "V")

-- -----------------------------------------------------------------------------
-- Phantom Hourglass USA (AZEE) game-state helpers (safely gated by game_code)
-- -----------------------------------------------------------------------------
local IS_USA = (ph.game_code == "AZEE")

-- Dual-screen boss stages in Phantom Hourglass (Course::mIndex):
-- 42 Cyclok, 43 Blaaz, 44 Crayk, 45 Gleeok, 46 Dongorongo,
-- 47 Eox, 48 Cubus Sisters, 49 Bellum 1, 50 Bellum 2 (Ghost Ship), 51 Bellumbeck
local BOSS_STAGES = {
    [42] = "Cyclok",
    [43] = "Blaaz",
    [44] = "Crayk",
    [45] = "Gleeok",
    [46] = "Dongorongo",
    [47] = "Eox",
    [48] = "Cubus Sisters",
    [49] = "Bellum",
    [50] = "Ghost Ship",
    [51] = "Bellumbeck",
}

local function valid_ram_ptr(p)
    return p >= 0x02000000 and p < 0x023FFF00
end

local function read_game_state()
    local state = {
        in_adventure = not IS_USA, -- fallback on non-AZEE regions
        stage = -1,
        boss_name = nil,
    }
    if not IS_USA then
        return state
    end

    local mode_id = mem.u32(0x027E0618)
    local adv_flags = mem.u32(0x027E0F74)
    local map_mgr = mem.u32(0x027E0E60)

    if mode_id == 2 and valid_ram_ptr(adv_flags) and valid_ram_ptr(map_mgr) then
        local course = mem.u32(map_mgr)
        if valid_ram_ptr(course) then
            local stage = mem.s32(course)
            if stage >= 0 and stage < 128 then
                state.in_adventure = true
                state.stage = stage
                state.boss_name = BOSS_STAGES[stage]
            end
        end
    end
    return state
end

-- Check whether the DS top screen is currently blanked / faded fully to black.
local function is_top_screen_blank(disp)
    if not disp.screens_enabled or not disp.top_enabled then
        return true
    end
    local mb = disp.screen_swap and disp.master_bright_a or disp.master_bright_b
    local mb_mode = (mb >> 14) & 3
    local mb_evy  = mb & 0x1F
    -- Mode 2 = fade to black; EVY >= 16 = 100% black
    if mb_mode == 2 and mb_evy >= 16 then
        return true
    end
    return false
end

-- -----------------------------------------------------------------------------
-- Runtime interactive state, stability debouncing & smooth animation values
-- -----------------------------------------------------------------------------
-- pip_state: 0 = compact (default), 1 = expanded, 2 = hidden (shows tiny [MAP +] tab)
local pip_state = 0
local anim_scale = 1.0
local anim_alpha = 1.0
local anim_peek  = 0.0
local prev_boss_name = nil

-- Stability tracking to prevent 60 Hz flickering during dual-3D scenes (e.g. Title Screen),
-- where Phantom Hourglass alternates POWCNT1 (screen_swap) and wide_layer every frame.
local prev_swap = nil
local prev_wide_layer = nil
local last_flip_frame = -100
local swap_stable_frames = 0
local blank_streak = 0

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function lerp(a, b, t)
    return a + (b - a) * clamp(t, 0.0, 1.0)
end

local function point_in(px, py, x, y, w, h)
    return px >= x and px < x + w and py >= y and py < y + h
end

local function is_peek_held()
    local bind = cfg.get("peek_key", "V")
    if not bind or bind == "" or bind == "None" then return false end
    return input.key_down(bind)
end

-- Compute an aspect-preserving fit rectangle inside (bx, by, bw, bh)
local function fit_rect(bx, by, bw, bh, aspect)
    local w, h
    if bw / bh > aspect then
        h = bh
        w = h * aspect
    else
        w = bw
        h = w / aspect
    end
    return bx + (bw - w) * 0.5, by + (bh - h) * 0.5, w, h
end

-- Draw a sleek modern frame around a screen rect
local function draw_frame(x, y, w, h, ui, border_argb, alpha)
    if alpha <= 0.02 then return end
    local a_shadow = math.floor(clamp(alpha * 0x60, 0, 255))
    local a_bg     = math.floor(clamp(alpha * 0xB8, 0, 255))
    local a_border = math.floor(clamp(alpha * ((border_argb >> 24) & 0xFF), 0, 255))
    local col_border = (a_border << 24) | (border_argb & 0x00FFFFFF)
    local pad = math.max(1.0, 2.0 * ui)
    local off = math.max(2.0, 3.0 * ui)

    -- Drop shadow
    gfx.fill(x + off, y + off, w, h, (a_shadow << 24))
    -- Matte dark backdrop
    gfx.fill(x - pad, y - pad, w + pad * 2, h + pad * 2, (a_bg << 24) | 0x0C1018)
    -- Crisp outline
    gfx.outline(x - pad, y - pad, w + pad * 2, h + pad * 2, math.max(1.5, 2.0 * ui), col_border)
end

-- Draw a tiny translucent pill label at (x, y)
local function draw_pill(x, y, label, ui, bg_rgb, fg_rgb, alpha)
    if alpha <= 0.05 then return 0, 0 end
    local sz = math.max(9.0, 10.0 * ui)
    local px = 6.0 * ui
    local py = 4.0 * ui
    local tw = sz * #label
    local bw = tw + px * 2
    local bh = sz + py * 2
    local a_bg = math.floor(clamp(alpha * 0xC8, 0, 255))
    local a_fg = math.floor(clamp(alpha * 0xFF, 0, 255))
    gfx.fill(x, y, bw, bh, (a_bg << 24) | (bg_rgb & 0x00FFFFFF))
    gfx.outline(x, y, bw, bh, math.max(1.0, 1.2 * ui), (a_bg << 24) | (fg_rgb & 0x00FFFFFF))
    gfx.text(x + px, y + py, sz, label, (a_fg << 24) | (fg_rgb & 0x00FFFFFF))
    return bw, bh
end

-- Draw Side-by-Side layout (Bottom primary + Top beside it in wide windows, stacked in portrait)
local function draw_dual_split(ctx, win_w, win_h, ui, is_boss, boss_name, dual_3d_active)
    local gap = 8.0 * ui
    local pad = 6.0 * ui
    local wide_bot = (not dual_3d_active) and ctx.wide and ctx.wide_extra > 0 and ctx.wide_layer == 1
    local bot_aspect = wide_bot and ((256.0 + 2.0 * ctx.wide_extra) / 192.0) or (256.0 / 192.0)
    local top_aspect = 256.0 / 192.0

    local bx, by, bw, bh
    local tx, ty, tw, th

    if win_w >= win_h * 1.35 then
        -- Landscape: Bottom (56% width) on the left, Top (44% width) on the right
        local avail_w = win_w - pad * 2 - gap
        local avail_h = win_h - pad * 2
        local left_w  = avail_w * 0.56
        local right_w = avail_w - left_w
        bx, by, bw, bh = fit_rect(pad, pad, left_w, avail_h, bot_aspect)
        tx, ty, tw, th = fit_rect(pad + left_w + gap, pad, right_w, avail_h, top_aspect)
    else
        -- Portrait or 4:3: Top above Bottom (classic DS stack, maximized cleanly)
        local v = gfx.default_views("both")
        tx, ty, tw, th = v.top.x, v.top.y, v.top.w, v.top.h
        bx, by, bw, bh = v.bottom.x, v.bottom.y, v.bottom.w, v.bottom.h
    end

    gfx.draw_screen("bottom", bx, by, bw, bh, { smooth = ctx.smooth, wide = wide_bot })
    gfx.set_touch_rect(bx, by, bw, bh, { wide = wide_bot, priority = 0 })

    local border = is_boss and 0xEEFFD25A or 0xDCE5C468
    draw_frame(tx, ty, tw, th, ui, border, 0.95)
    gfx.draw_screen("top", tx, ty, tw, th, { smooth = ctx.smooth, wide = false })

    if is_boss and boss_name then
        draw_pill(tx + 6 * ui, ty + 6 * ui, "BOSS: " .. boss_name, ui, 0x1A1508, 0xFFD25A, 0.92)
    end
end

-- -----------------------------------------------------------------------------
-- Main Draw Hook
-- -----------------------------------------------------------------------------
ph.on("draw", function(ctx)
    local mode = cfg.get("mode", "Modern PiP")
    if mode == "Vanilla (Off)" then
        return false -- hand control back to the default renderer
    end

    local win_w, win_h, ui = ctx.win_w, ctx.win_h, ctx.ui_scale
    local dt = clamp(ph.dt or (1.0 / 60.0), 0.001, 0.05)
    local f  = ph.frame or 0
    local disp = ds.display()
    local gs = read_game_state()
    local ptr = input.pointer()

    -- Track POWCNT1 screen_swap / wide_layer alternation (dual-3D title/cutscene frames).
    if prev_swap ~= nil and (disp.screen_swap ~= prev_swap or ctx.wide_layer ~= prev_wide_layer) then
        last_flip_frame = f
        swap_stable_frames = 0
    else
        swap_stable_frames = swap_stable_frames + 1
    end
    prev_swap = disp.screen_swap
    prev_wide_layer = ctx.wide_layer
    local dual_3d_active = (f - last_flip_frame) <= 12

    if is_top_screen_blank(disp) and not dual_3d_active then
        blank_streak = blank_streak + 1
    else
        blank_streak = 0
    end
    local top_blank = (blank_streak >= 3)

    -- Notify once on boss entry if Auto Boss is enabled
    local auto_boss = cfg.get("auto_boss", "Off")
    if gs.boss_name ~= prev_boss_name then
        if gs.boss_name and auto_boss ~= "Off" then
            ph.notify("Boss detected: " .. gs.boss_name .. " (" .. auto_boss .. ")", 2200)
        end
        prev_boss_name = gs.boss_name
    end

    -- 1. Side-by-Side mode OR Auto Split during dual-screen bosses
    local boss_active = (gs.boss_name ~= nil)
    if mode == "Side-by-Side" or (boss_active and auto_boss == "Auto Split") then
        draw_dual_split(ctx, win_w, win_h, ui, boss_active, gs.boss_name, dual_3d_active)
        return true
    end

    -- 2. Top Only mode
    if mode == "Top Only" then
        local wide_top = (not dual_3d_active) and ctx.wide and ctx.wide_extra > 0 and ctx.wide_layer == 0
        local tx, ty, tw, th
        if wide_top then
            local v = gfx.default_views("top").top
            tx, ty, tw, th = v.x, v.y, v.w, v.h
        elseif ctx.stretch then
            tx, ty, tw, th = 0, 0, win_w, win_h
        else
            tx, ty, tw, th = fit_rect(0, 0, win_w, win_h, 256.0 / 192.0)
        end
        gfx.draw_screen("top", tx, ty, tw, th, { smooth = ctx.smooth, wide = wide_top })
        return true
    end

    -- 3. Primary Single-Screen Canvas (Modern PiP & Minimal Peek)
    -- During dual-3D alternation (Title Screen), lock bottom to steady 4:3 so it never flickers!
    local wide_bot = (not dual_3d_active) and ctx.wide and ctx.wide_extra > 0 and ctx.wide_layer == 1
    local bx, by, bw, bh
    if wide_bot then
        local vbot = gfx.default_views("bottom").bottom
        bx, by, bw, bh = vbot.x, vbot.y, vbot.w, vbot.h
    elseif ctx.stretch then
        bx, by, bw, bh = 0, 0, win_w, win_h
    else
        bx, by, bw, bh = fit_rect(0, 0, win_w, win_h, 256.0 / 192.0)
    end
    gfx.draw_screen("bottom", bx, by, bw, bh, { smooth = ctx.smooth, wide = wide_bot })
    gfx.set_touch_rect(bx, by, bw, bh, { wide = wide_bot, priority = 0 })

    -- Keyboard shortcut: P cycles PiP (Compact -> Large -> Hidden) on PC
    if input.key_pressed("P") then
        pip_state = (pip_state + 1) % 3
    end

    -- 4. Hold-to-Peek overlay (centered, uncropped, 74% viewport)
    local peeking = is_peek_held()
    anim_peek = lerp(anim_peek, peeking and 1.0 or 0.0, dt * 16.0)
    if anim_peek > 0.02 then
        local dim_a = math.floor(clamp(anim_peek * 0x99, 0, 255))
        gfx.fill(0, 0, win_w, win_h, (dim_a << 24))
        local max_w = win_w * (0.62 + 0.14 * anim_peek)
        local max_h = win_h * (0.62 + 0.14 * anim_peek)
        local px, py, pw, ph_h = fit_rect((win_w - max_w) * 0.5, (win_h - max_h) * 0.5, max_w, max_h, 256.0 / 192.0)
        draw_frame(px, py, pw, ph_h, ui, 0xEEFFD25A, anim_peek)
        gfx.draw_screen("top", px, py, pw, ph_h, { smooth = true, wide = false, alpha = anim_peek })
        draw_pill(px + 8 * ui, py + 8 * ui, "TOP SCREEN (PEEK)", ui, 0x161922, 0xFFD25A, anim_peek)
        gfx.set_touch_rect(px, py, pw, ph_h, { block = true, priority = 20 })
        return true
    end

    -- 5. Minimal (Peek) mode: no permanent PiP, just a tiny subtle [MAP] corner chip
    if mode == "Minimal (Peek)" and not (boss_active and auto_boss == "Enlarge PiP") then
        local margin = 10.0 * ui
        local chip_label = "MAP"
        local chip_sz = math.max(10.0, 11.0 * ui)
        local cw = chip_sz * #chip_label + 14.0 * ui
        local ch = chip_sz + 10.0 * ui
        local corner = cfg.get("pip_corner", "Top-Right")
        local cx = (corner == "Top-Right" or corner == "Bottom-Right") and (win_w - cw - margin) or margin
        local cy = (corner == "Bottom-Left" or corner == "Bottom-Right") and (win_h - ch - margin) or margin

        if ptr.just_pressed and point_in(ptr.x, ptr.y, cx, cy, cw, ch) then
            cfg.set("mode", "Modern PiP")
            pip_state = 0
            ph.notify("Modern PiP enabled", 1500)
        end
        gfx.set_touch_rect(cx, cy, cw, ch, { block = true, priority = 10 })
        draw_pill(cx, cy, chip_label, ui, 0x141822, 0x8AB4FF, 0.72)
        return true
    end

    -- 6. Modern PiP overlay
    local tap_mode  = cfg.get("tap_pip", "Click-Through")
    local corner    = cfg.get("pip_corner", "Top-Right")
    local base_pct  = (cfg.get("pip_size", 20) or 20) / 100.0
    local cfg_alpha = cfg.get("pip_alpha", 0.83) or 0.83
    local boss_enlarge = (boss_active and auto_boss == "Enlarge PiP")

    -- Hidden state (user tapped to collapse PiP into a tiny [MAP +] restore chip)
    if pip_state == 2 and not boss_enlarge then
        local margin = 10.0 * ui
        local chip_label = "MAP +"
        local chip_sz = math.max(10.0, 11.0 * ui)
        local cw = chip_sz * #chip_label + 14.0 * ui
        local ch = chip_sz + 10.0 * ui
        local cx = (corner == "Top-Right" or corner == "Bottom-Right") and (win_w - cw - margin) or margin
        local cy = (corner == "Bottom-Left" or corner == "Bottom-Right") and (win_h - ch - margin) or margin

        if ptr.just_pressed and point_in(ptr.x, ptr.y, cx, cy, cw, ch) then
            pip_state = 0
        end
        gfx.set_touch_rect(cx, cy, cw, ch, { block = true, priority = 10 })
        draw_pill(cx, cy, chip_label, ui, 0x141822, 0x8AB4FF, 0.80)
        return true
    end

    -- Smooth target scale & opacity
    local target_scale = 1.0
    if boss_enlarge then
        target_scale = 1.55
    elseif pip_state == 1 then
        target_scale = 1.60
    end
    local target_alpha = top_blank and 0.0 or (boss_enlarge and math.max(cfg_alpha, 0.94) or cfg_alpha)
    anim_scale = lerp(anim_scale, target_scale, dt * 14.0)
    anim_alpha = lerp(anim_alpha, target_alpha, dt * 12.0)

    if anim_alpha <= 0.02 then
        return true
    end

    -- Automatic Clean Map Crop: trim the decorative torn DS parchment border ONLY during stable
    -- in-game exploration (disabled on logos/title/file-select, bosses, dual-3D, or 3D-on-top swaps!).
    local use_crop = gs.in_adventure
        and (not boss_active)
        and (not dual_3d_active)
        and (not disp.screen_swap)
        and (swap_stable_frames >= 6)
    local src_rect = use_crop and { x = 8, y = 10, w = 240, h = 172 } or nil
    local pip_aspect = use_crop and (240.0 / 172.0) or (256.0 / 192.0)

    -- Compute PiP rectangle anchored cleanly to the chosen window corner
    local margin = 12.0 * ui
    local pw = clamp(win_w * base_pct * anim_scale, 96.0 * ui, win_w * 0.62)
    local ph_h = pw / pip_aspect
    if ph_h > win_h * 0.56 then
        ph_h = win_h * 0.56
        pw = ph_h * pip_aspect
    end

    local px, py
    local overlaps_game = (bx < pw * 0.45)
    if corner == "Top-Right" then
        px = win_w - pw - margin
        py = margin
    elseif corner == "Top-Left" then
        px = margin
        -- Clear Link's top-left heart row when overlapping the game area
        local hud_clear = (overlaps_game and not boss_enlarge and pip_state == 0) and (by + bh * 0.125) or margin
        py = math.min(hud_clear, win_h - ph_h - margin)
    elseif corner == "Bottom-Right" then
        px = win_w - pw - margin
        py = win_h - ph_h - margin
    else
        -- Bottom-Left: clear the green Menu button when overlapping the game area
        px = margin
        local hud_clear = (overlaps_game and not boss_enlarge and pip_state == 0) and (bh * 0.15) or margin
        py = math.max(margin, win_h - ph_h - hud_clear)
    end

    -- Handle interactive PiP tap
    if tap_mode ~= "Click-Through" then
        if ptr.just_pressed and point_in(ptr.x, ptr.y, px, py, pw, ph_h) then
            if tap_mode == "Toggle Hide" then
                pip_state = 2
            else
                pip_state = (pip_state + 1) % 3
            end
        end
        gfx.set_touch_rect(px, py, pw, ph_h, { block = true, priority = 10 })
    end

    -- Render PiP with modern dark-slate + antique Zelda gold frame
    local border_col = boss_enlarge and 0xF0FFD25A or (pip_state == 1 and 0xEE8AB4FF or 0xDCE5C468)
    draw_frame(px, py, pw, ph_h, ui, border_col, anim_alpha)

    local draw_opts = {
        smooth = true,
        wide   = false,
        alpha  = anim_alpha,
    }
    if src_rect then
        draw_opts.src = src_rect
    end
    gfx.draw_screen("top", px, py, pw, ph_h, draw_opts)

    if boss_enlarge and gs.boss_name then
        draw_pill(px + 6 * ui, py + 6 * ui, "BOSS: " .. gs.boss_name, ui, 0x1A1508, 0xFFD25A, anim_alpha)
    elseif pip_state == 1 then
        draw_pill(px + 6 * ui, py + 6 * ui, "ZOOM  (tap to hide)", ui, 0x141822, 0x8AB4FF, anim_alpha * 0.9)
    end

    return true
end)

log.info("Single Screen (Modern HUD) v1.0.0 loaded — press F1 -> Mods to customize or rebind Peek Hotkey.")
