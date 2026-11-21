-- =============================================================================
-- Single Screen (Modern HUD) v2.0.0 — The Legend of Zelda: Phantom Hourglass
-- =============================================================================
-- Clean, zero-clutter single-screen & customizable side-by-side layouts:
--   - Modern PiP with 8 anchor positions + X/Y fine offsets + opacity + size
--   - Flexible non-overlapping Side-by-Side / Stacked layouts with split ratio,
--     alignment, and gap controls
--   - Automatic top-screen NPC speech bubble pop-up at the top of the primary
--     screen whenever the secondary screen is hidden or minimized
--   - Full click-to-bind hotkeys (Peek, Hide, Shrink, Grow, Switch Mode)
--   - Zero mod text drawn on screen
-- Cross-platform Lua 5.4 mod (PC + Android, USA AZEE & Europe AZEP).

local gfx   = require("ph.gfx")
local cfg   = require("ph.config")
local input = require("ph.input")
local ds    = require("ph.ds")
local mem   = require("ph.mem")
local hook  = require("ph.hook")
local log   = require("ph.logger")

-- -----------------------------------------------------------------------------
-- Live-configurable settings (editable & scrollable in F1 -> Mods)
-- -----------------------------------------------------------------------------
-- Display Mode
cfg.choice("mode",         "Display Mode",       { "Modern PiP", "Side-by-Side", "Hidden (Single)", "Top Only", "Vanilla (Off)" }, 1)

-- PiP (Overlaid) Settings
cfg.choice("pip_corner",   "PiP Position",       { "Top-Right", "Top-Center", "Top-Left", "Mid-Right", "Mid-Left", "Bottom-Right", "Bottom-Center", "Bottom-Left" }, 1)
cfg.int(   "pip_size",     "PiP Size (%)",       20, 10, 50, 2)
cfg.float( "pip_alpha",    "PiP Opacity",        0.83, 0.25, 1.00, 0.05)
cfg.int(   "pip_off_x",    "PiP Offset X (%)",   0, -25, 25, 1)
cfg.int(   "pip_off_y",    "PiP Offset Y (%)",   0, -25, 25, 1)
cfg.choice("tap_pip",      "Tap PiP Action",     { "Cycle Size", "Toggle Hide", "Click-Through" }, 3)

-- Side-by-Side (Non-Overlapping) Settings
cfg.choice("split_layout", "Split Placement",    { "Main Left / Top Right", "Top Left / Main Right", "Top Above Main", "Main Above Top" }, 1)
cfg.int(   "split_ratio",  "Split Main (%)",     62, 40, 80, 2)
cfg.choice("split_align",  "Split Align",        { "Center", "Top / Left", "Bottom / Right" }, 1)
cfg.int(   "split_gap",    "Split Gap (px)",     6, 0, 24, 2)

-- Smart Gameplay Features
cfg.choice("top_dialogue", "Top NPC Dialogue",   { "Hidden / Small", "When Hidden", "Off" }, 1)
cfg.choice("auto_boss",    "Dual-Screen Boss",   { "Auto Split", "Enlarge PiP", "Off" }, 3)

-- Click-to-Bind Hotkeys (Keyboard / Gamepad / Mouse)
cfg.hotkey("key_peek",     "Peek Top (Hold)",    "V")
cfg.hotkey("key_hide",     "Toggle Hide Top",    "H")
cfg.hotkey("key_smaller",  "Shrink Top",         "None")
cfg.hotkey("key_larger",   "Grow Top",           "None")
cfg.hotkey("key_mode",     "Switch Mode",        "None")

-- -----------------------------------------------------------------------------
-- Phantom Hourglass USA (AZEE) game-state & Top-Screen NPC Dialogue detection
-- -----------------------------------------------------------------------------
local IS_USA = (ph.game_code == "AZEE")

-- Dual-screen boss stages in Phantom Hourglass (Course::mIndex):
local BOSS_STAGES = {
    [42] = true, -- Cyclok
    [43] = true, -- Blaaz
    [44] = true, -- Crayk
    [45] = true, -- Gleeok
    [46] = true, -- Dongorongo
    [47] = true, -- Eox
    [48] = true, -- Cubus Sisters
    [49] = true, -- Bellum 1
    [50] = true, -- Bellum 2 (Ghost Ship)
    [51] = true, -- Bellumbeck
}

local function valid_ram_ptr(p)
    return p >= 0x02000000 and p < 0x023FFF00
end

local function read_game_state()
    local state = {
        in_adventure = not IS_USA,
        stage = -1,
        boss_active = false,
    }
    if not IS_USA then
        return state
    end

    local mode_id   = mem.u32(0x027E0618)
    local adv_flags = mem.u32(0x027E0F74)
    local map_mgr   = mem.u32(0x027E0E60)

    if mode_id == 2 and valid_ram_ptr(adv_flags) and valid_ram_ptr(map_mgr) then
        local course = mem.u32(map_mgr)
        if valid_ram_ptr(course) then
            local stage = mem.s32(course)
            if stage >= 0 and stage < 128 then
                state.in_adventure = true
                state.stage = stage
                state.boss_active = (BOSS_STAGES[stage] == true)
            end
        end
    end
    return state
end

-- Real-time Top-Screen NPC Dialogue Detector (via ARM9 hook on UnkStruct_0203dae0::Draw)
-- Works on both USA (AZEE: 0x0203E16C) and Europe (AZEP: 0x0203E1B0).
-- Detects whenever Phantom Hourglass draws an active OBJ text box on layer 0 (Top Screen)
-- in the bottom dialogue bubble region (screen_y >= 88). Zero cost when no dialogue is open.
local top_dlg_last_frame = -1000
local top_dlg_min_y = 128
local top_dlg_frame_y = 192
local top_dlg_last_sample_frame = -1

local OBJ_DRAW_ADDR = (ph.game_code == "AZEE") and 0x0203E16C
    or (ph.game_code == "AZEP") and 0x0203E1B0
    or nil

if OBJ_DRAW_ADDR then
    hook.pre(OBJ_DRAW_ADDR, function(cpu)
        local this_obj = cpu.r0
        if not valid_ram_ptr(this_obj) then return false end
        -- Same visibility check as UnkStruct_0203dae0::Draw (VRAM slot != -1 and num_objs > 0)
        if mem.u32(this_obj + 280) == 0xFFFFFFFF then return false end
        if mem.s8(this_obj + 287) <= 0 then return false end

        -- Exact 2D engine & screen layer resolution (matches ph_text.cpp)
        local single_eng = (mem.u8(0x027E0C54) ~= 0)
        local engine = single_eng and 0 or ((mem.u8(this_obj + 80) ~= 0) and 1 or 0)
        local swap = ((mem.u32(0x04000304) >> 15) & 1) ~= 0
        local layer = (engine == 0) and (swap and 0 or 1) or (swap and 1 or 0)

        if layer == 0 then
            -- Signed 32-bit screen_y in r2
            local sy = cpu.r2
            if sy >= 0x80000000 then sy = sy - 0x100000000 end
            if sy >= 88 and sy < 190 then
                local f = ph.frame or 0
                if f ~= top_dlg_last_sample_frame then
                    top_dlg_frame_y = sy
                    top_dlg_last_sample_frame = f
                elseif sy < top_dlg_frame_y then
                    top_dlg_frame_y = sy
                end
                top_dlg_min_y = top_dlg_frame_y
                top_dlg_last_frame = f
            end
        end
        return false
    end)
end

-- Check whether the DS top screen is currently blanked / faded fully to black.
local function is_top_screen_blank(disp)
    if not disp.screens_enabled or not disp.top_enabled then
        return true
    end
    local mb = disp.screen_swap and disp.master_bright_a or disp.master_bright_b
    local mb_mode = (mb >> 14) & 3
    local mb_evy  = mb & 0x1F
    if mb_mode == 2 and mb_evy >= 16 then
        return true
    end
    return false
end

-- -----------------------------------------------------------------------------
-- Runtime state, debouncing & smooth animations
-- -----------------------------------------------------------------------------
-- pip_state: 0 = normal, 1 = zoomed (via tap), 2 = hidden (via tap)
local pip_state   = 0
local user_hidden = false
local anim_scale  = 1.0
local anim_alpha  = 1.0
local anim_peek   = 0.0
local anim_dlg    = 0.0

-- Stability tracking to eliminate 60 Hz flickering during dual-3D scenes (Title/Intro)
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

local function bind_down(cfg_key, default_bind)
    local bind = cfg.get(cfg_key, default_bind)
    if not bind or bind == "" or bind == "None" then return false end
    return input.key_down(bind)
end

local function bind_pressed(cfg_key, default_bind)
    local bind = cfg.get(cfg_key, default_bind)
    if not bind or bind == "" or bind == "None" then return false end
    return input.key_pressed(bind)
end

-- Fit rectangle inside (bx, by, bw, bh) with alignment ("Center", "Top / Left", "Bottom / Right")
local function fit_rect_aligned(bx, by, bw, bh, aspect, align)
    local w, h
    if bw / bh > aspect then
        h = bh
        w = h * aspect
    else
        w = bw
        h = w / aspect
    end
    local rx, ry
    if align == "Top / Left" then
        rx = bx
        ry = by
    elseif align == "Bottom / Right" then
        rx = bx + (bw - w)
        ry = by + (bh - h)
    else
        rx = bx + (bw - w) * 0.5
        ry = by + (bh - h) * 0.5
    end
    return rx, ry, w, h
end

local function fit_rect(bx, by, bw, bh, aspect)
    return fit_rect_aligned(bx, by, bw, bh, aspect, "Center")
end

-- Sleek frame around a screen rect (zero text!)
local function draw_frame(x, y, w, h, ui, border_argb, alpha)
    if alpha <= 0.02 then return end
    local a_shadow = math.floor(clamp(alpha * 0x60, 0, 255))
    local a_bg     = math.floor(clamp(alpha * 0xB8, 0, 255))
    local a_border = math.floor(clamp(alpha * ((border_argb >> 24) & 0xFF), 0, 255))
    local col_border = (a_border << 24) | (border_argb & 0x00FFFFFF)
    local pad = math.max(1.0, 2.0 * ui)
    local off = math.max(2.0, 3.0 * ui)

    gfx.fill(x + off, y + off, w, h, (a_shadow << 24))
    gfx.fill(x - pad, y - pad, w + pad * 2, h + pad * 2, (a_bg << 24) | 0x0C1018)
    gfx.outline(x - pad, y - pad, w + pad * 2, h + pad * 2, math.max(1.5, 2.0 * ui), col_border)
end

-- Draw centered Peek overlay (no text!)
local function draw_peek_overlay(win_w, win_h, ui, alpha)
    local dim_a = math.floor(clamp(alpha * 0x99, 0, 255))
    gfx.fill(0, 0, win_w, win_h, (dim_a << 24))
    local max_w = win_w * (0.62 + 0.14 * alpha)
    local max_h = win_h * (0.62 + 0.14 * alpha)
    local px, py, pw, ph_h = fit_rect((win_w - max_w) * 0.5, (win_h - max_h) * 0.5, max_w, max_h, 256.0 / 192.0)
    draw_frame(px, py, pw, ph_h, ui, 0xEEFFD25A, alpha)
    gfx.draw_screen("top", px, py, pw, ph_h, { smooth = true, wide = false, alpha = alpha })
    gfx.set_touch_rect(px, py, pw, ph_h, { block = true, priority = 20 })
end

-- Draw Top-Screen NPC Dialogue bubble pop-up cleanly at top-center of primary screen (zero extra text!)
local function draw_top_dialogue_popup(bx, by, bw, bh, ui, alpha)
    if alpha <= 0.02 then return end
    -- Crop the speech bubble strip from the bottom of the Top Screen (256x192)
    local src_y = clamp(top_dlg_min_y - 14, 100, 124)
    local src_h = 191 - src_y
    local src_x = 8
    local src_w = 240
    local aspect = src_w / src_h

    local dw = clamp(bw * 0.66, 200.0 * ui, bw - 20.0 * ui)
    local dh = dw / aspect
    if dh > bh * 0.30 then
        dh = bh * 0.30
        dw = dh * aspect
    end
    local dx = bx + (bw - dw) * 0.5
    local slide = (1.0 - alpha) * (-14.0 * ui)
    local dy = by + 8.0 * ui + slide

    draw_frame(dx, dy, dw, dh, ui, 0xE0E5C468, alpha)
    gfx.draw_screen("top", dx, dy, dw, dh, {
        smooth = true,
        wide   = false,
        alpha  = alpha,
        src    = { x = src_x, y = src_y, w = src_w, h = src_h },
    })
end

-- Draw customizable Side-by-Side / Stacked (non-overlapping) layout
local function draw_side_by_side(ctx, win_w, win_h, ui, is_boss, dual_3d_active)
    local layout = cfg.get("split_layout", "Main Left / Top Right")
    local ratio  = clamp((cfg.get("split_ratio", 62) or 62) / 100.0, 0.40, 0.80)
    local align  = cfg.get("split_align", "Center")
    local gap    = (cfg.get("split_gap", 6) or 6) * ui
    local pad    = 4.0 * ui

    local wide_bot = (not dual_3d_active) and ctx.wide and ctx.wide_extra > 0 and ctx.wide_layer == 1
    local bot_aspect = wide_bot and ((256.0 + 2.0 * ctx.wide_extra) / 192.0) or (256.0 / 192.0)
    local top_aspect = 256.0 / 192.0

    local avail_w = math.max(1.0, win_w - pad * 2)
    local avail_h = math.max(1.0, win_h - pad * 2)
    local bx, by, bw, bh
    local tx, ty, tw, th

    if layout == "Top Left / Main Right" then
        local body_w = math.max(1.0, avail_w - gap)
        local main_w = body_w * ratio
        local top_w  = body_w - main_w
        tx, ty, tw, th = fit_rect_aligned(pad, pad, top_w, avail_h, top_aspect, align)
        bx, by, bw, bh = fit_rect_aligned(pad + top_w + gap, pad, main_w, avail_h, bot_aspect, align)
    elseif layout == "Top Above Main" then
        local body_h = math.max(1.0, avail_h - gap)
        local main_h = body_h * ratio
        local top_h  = body_h - main_h
        tx, ty, tw, th = fit_rect_aligned(pad, pad, avail_w, top_h, top_aspect, align)
        bx, by, bw, bh = fit_rect_aligned(pad, pad + top_h + gap, avail_w, main_h, bot_aspect, align)
    elseif layout == "Main Above Top" then
        local body_h = math.max(1.0, avail_h - gap)
        local main_h = body_h * ratio
        local top_h  = body_h - main_h
        bx, by, bw, bh = fit_rect_aligned(pad, pad, avail_w, main_h, bot_aspect, align)
        tx, ty, tw, th = fit_rect_aligned(pad, pad + main_h + gap, avail_w, top_h, top_aspect, align)
    else
        -- Default: Main Left / Top Right
        local body_w = math.max(1.0, avail_w - gap)
        local main_w = body_w * ratio
        local top_w  = body_w - main_w
        bx, by, bw, bh = fit_rect_aligned(pad, pad, main_w, avail_h, bot_aspect, align)
        tx, ty, tw, th = fit_rect_aligned(pad + main_w + gap, pad, top_w, avail_h, top_aspect, align)
    end

    gfx.draw_screen("bottom", bx, by, bw, bh, { smooth = ctx.smooth, wide = wide_bot })
    gfx.set_touch_rect(bx, by, bw, bh, { wide = wide_bot, priority = 0 })

    local border = is_boss and 0xEEFFD25A or 0xCCE5C468
    draw_frame(tx, ty, tw, th, ui, border, 0.95)
    gfx.draw_screen("top", tx, ty, tw, th, { smooth = ctx.smooth, wide = false })
    return bx, by, bw, bh
end

-- -----------------------------------------------------------------------------
-- Main Draw Hook
-- -----------------------------------------------------------------------------
ph.on("draw", function(ctx)
    local mode = cfg.get("mode", "Modern PiP")
    if mode == "Vanilla (Off)" then
        return false
    end

    local win_w, win_h, ui = ctx.win_w, ctx.win_h, ctx.ui_scale
    local dt = clamp(ph.dt or (1.0 / 60.0), 0.001, 0.05)
    local f  = ph.frame or 0
    local disp = ds.display()
    local gs = read_game_state()
    local ptr = input.pointer()

    -- Stability debouncing for dual-3D alternation (Title/Intro)
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

    -- Process click-to-bind action hotkeys
    if bind_pressed("key_mode", "None") then
        local next_mode = (mode == "Modern PiP") and "Side-by-Side"
            or (mode == "Side-by-Side") and "Hidden (Single)"
            or "Modern PiP"
        cfg.set("mode", next_mode)
        mode = next_mode
        user_hidden = false
        pip_state = 0
    end

    if bind_pressed("key_hide", "H") then
        if mode == "Modern PiP" and pip_state == 2 then
            pip_state = 0
            user_hidden = false
        else
            user_hidden = not user_hidden
        end
    end

    if bind_pressed("key_smaller", "None") then
        if mode == "Side-by-Side" then
            local cur = cfg.get("split_ratio", 62) or 62
            cfg.set("split_ratio", clamp(cur + 4, 40, 80))
        else
            local cur = cfg.get("pip_size", 20) or 20
            cfg.set("pip_size", clamp(cur - 4, 10, 50))
            pip_state = 0
        end
    end

    if bind_pressed("key_larger", "None") then
        if mode == "Side-by-Side" then
            local cur = cfg.get("split_ratio", 62) or 62
            cfg.set("split_ratio", clamp(cur - 4, 40, 80))
        else
            local cur = cfg.get("pip_size", 20) or 20
            cfg.set("pip_size", clamp(cur + 4, 10, 50))
            pip_state = 0
        end
    end

    local peeking = bind_down("key_peek", "V")
    anim_peek = lerp(anim_peek, peeking and 1.0 or 0.0, dt * 16.0)

    local auto_boss = cfg.get("auto_boss", "Off")
    local boss_active = gs.boss_active

    -- 1. Top Only mode
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

    -- 2. Side-by-Side mode OR Auto Split during bosses (unless user hid secondary screen!)
    local use_side_by_side = (mode == "Side-by-Side" and not user_hidden)
        or (boss_active and auto_boss == "Auto Split" and not user_hidden)
    if use_side_by_side then
        draw_side_by_side(ctx, win_w, win_h, ui, boss_active, dual_3d_active)
        if anim_peek > 0.02 then
            draw_peek_overlay(win_w, win_h, ui, anim_peek)
        end
        return true
    end

    -- 3. Primary Full-Screen Bottom Canvas (Modern PiP, Hidden Single, or hidden Side-by-Side)
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

    -- 4. Peek overlay takes priority while held (zero text!)
    if anim_peek > 0.02 then
        draw_peek_overlay(win_w, win_h, ui, anim_peek)
        return true
    end

    -- Determine whether the PiP is currently hidden
    local boss_enlarge = (boss_active and auto_boss == "Enlarge PiP")
    local secondary_hidden
    if mode == "Hidden (Single)" then
        secondary_hidden = (not user_hidden) and (not boss_enlarge)
    else
        secondary_hidden = (user_hidden or pip_state == 2) and (not boss_enlarge)
    end

    local top_dlg_active = ((f - top_dlg_last_frame) <= 15) and (not dual_3d_active) and (not top_blank)

    -- 5. Modern PiP overlay (when not hidden)
    local base_pct = (cfg.get("pip_size", 20) or 20) / 100.0
    if not secondary_hidden then
        local tap_mode  = cfg.get("tap_pip", "Click-Through")
        local pos       = cfg.get("pip_corner", "Top-Right")
        local cfg_alpha = cfg.get("pip_alpha", 0.83) or 0.83
        local off_x_pct = (cfg.get("pip_off_x", 0) or 0) / 100.0
        local off_y_pct = (cfg.get("pip_off_y", 0) or 0) / 100.0

        local target_scale = 1.0
        if boss_enlarge then
            target_scale = 1.55
        elseif pip_state == 1 then
            target_scale = 1.60
        end
        local target_alpha = top_blank and 0.0 or (boss_enlarge and math.max(cfg_alpha, 0.94) or cfg_alpha)
        anim_scale = lerp(anim_scale, target_scale, dt * 14.0)
        anim_alpha = lerp(anim_alpha, target_alpha, dt * 12.0)

        if anim_alpha > 0.02 then
            -- Automatic Clean Map Crop during stable in-game exploration (disabled on title/swaps/bosses/dialogue)
            local use_crop = gs.in_adventure
                and (not boss_active)
                and (not top_dlg_active)
                and (not dual_3d_active)
                and (not disp.screen_swap)
                and (swap_stable_frames >= 6)
            local src_rect = use_crop and { x = 8, y = 10, w = 240, h = 172 } or nil
            local pip_aspect = use_crop and (240.0 / 172.0) or (256.0 / 192.0)

            local margin = 12.0 * ui
            local pw = clamp(win_w * base_pct * anim_scale, 96.0 * ui, win_w * 0.62)
            local ph_h = pw / pip_aspect
            if ph_h > win_h * 0.56 then
                ph_h = win_h * 0.56
                pw = ph_h * pip_aspect
            end

            -- 8-way anchor positioning
            local px, py
            if pos == "Top-Right" then
                px, py = win_w - pw - margin, margin
            elseif pos == "Top-Center" then
                px, py = (win_w - pw) * 0.5, margin
            elseif pos == "Top-Left" then
                local overlaps = (bx < pw * 0.45)
                local hud_y = (overlaps and not boss_enlarge and pip_state == 0) and (by + bh * 0.125) or margin
                px, py = margin, math.min(hud_y, win_h - ph_h - margin)
            elseif pos == "Mid-Right" then
                px, py = win_w - pw - margin, (win_h - ph_h) * 0.5
            elseif pos == "Mid-Left" then
                px, py = margin, (win_h - ph_h) * 0.5
            elseif pos == "Bottom-Right" then
                px, py = win_w - pw - margin, win_h - ph_h - margin
            elseif pos == "Bottom-Center" then
                px, py = (win_w - pw) * 0.5, win_h - ph_h - margin
            else
                -- Bottom-Left
                local overlaps = (bx < pw * 0.45)
                local hud_y = (overlaps and not boss_enlarge and pip_state == 0) and (bh * 0.15) or margin
                px, py = margin, math.max(margin, win_h - ph_h - hud_y)
            end

            -- Apply user fine offsets X / Y (% of window dimensions), clamped safely inside viewport
            px = clamp(px + off_x_pct * win_w, 4.0 * ui, math.max(4.0 * ui, win_w - pw - 4.0 * ui))
            py = clamp(py + off_y_pct * win_h, 4.0 * ui, math.max(4.0 * ui, win_h - ph_h - 4.0 * ui))

            if tap_mode ~= "Click-Through" then
                if ptr.just_pressed and point_in(ptr.x, ptr.y, px, py, pw, ph_h) then
                    if tap_mode == "Toggle Hide" then
                        user_hidden = true
                    else
                        pip_state = (pip_state + 1) % 3
                    end
                end
                gfx.set_touch_rect(px, py, pw, ph_h, { block = true, priority = 10 })
            end

            local border_col = boss_enlarge and 0xF0FFD25A or (pip_state == 1 and 0xEE8AB4FF or 0xDCE5C468)
            draw_frame(px, py, pw, ph_h, ui, border_col, anim_alpha)

            local draw_opts = { smooth = true, wide = false, alpha = anim_alpha }
            if src_rect then draw_opts.src = src_rect end
            gfx.draw_screen("top", px, py, pw, ph_h, draw_opts)
        end
    end

    -- 6. Top-Screen NPC Dialogue Pop-up when secondary screen is hidden or minimized
    local dlg_mode = cfg.get("top_dialogue", "Hidden / Small")
    local is_small_pip = (not secondary_hidden) and (pip_state == 0) and (not boss_enlarge) and (base_pct <= 0.245)
    local want_dlg = false
    if dlg_mode == "When Hidden" then
        want_dlg = top_dlg_active and secondary_hidden
    elseif dlg_mode == "Hidden / Small" then
        want_dlg = top_dlg_active and (secondary_hidden or is_small_pip)
    end
    anim_dlg = lerp(anim_dlg, want_dlg and 1.0 or 0.0, dt * 16.0)
    if anim_dlg > 0.02 then
        draw_top_dialogue_popup(bx, by, bw, bh, ui, anim_dlg)
    end

    return true
end)

log.info("Single Screen (Modern HUD) v2.0.0 loaded.")
