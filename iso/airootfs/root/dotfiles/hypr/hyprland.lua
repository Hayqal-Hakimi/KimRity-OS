-- hyprland.lua — KimRity Hyprland config
--
-- Hyprland >= 0.56 no longer reads hyprland.conf; configs are Lua. This file
-- is a standalone translation of the old hand-written hyprland.conf — no
-- Omarchy helpers, no external modules. Every binding here existed in the old
-- file; the mapping (hyprland.conf -> hl.*) follows Omarchy's default config
-- from /usr/share/omarchy and was verified against Hyprland 0.57.1.

-- ------------------------------------------------------------------- env
-- Java/Swing apps (ghidra, burp) need X11 + avoid reparenting under XWayland.
hl.env("_JAVA_AWT_WM_NONREPARENTING", "1")
hl.env("DISPLAY", ":0")

-- -------------------------------------------------------------------- input
hl.config({
  input = {
    kb_layout = "us",
    follow_mouse = 1,

    touchpad = {
      natural_scroll = true,
    },
  },
})

-- ---------------------------------------------------------------- general
local active_border = { colors = { "rgba(89b4faee)", "rgba(a6e3a1ee)" }, angle = 45 }

hl.config({
  general = {
    gaps_in = 5,
    gaps_out = 10,
    border_size = 2,

    col = {
      active_border = active_border,
      inactive_border = "rgba(45475aaa)",
    },

    layout = "dwindle",
  },

  decoration = {
    rounding = 8,
  },

  animations = {
    enabled = true,
  },
})

-- ------------------------------------------------------------------ monitor
-- QEMU VM: 16:9 mode so it fits the window. Other outputs use preferred.
hl.monitor({ output = "Virtual-1", mode = "1360x768", position = "0x0", scale = 1 })
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = 1 })

-- ---------------------------------------------------------------- autostart
hl.on("hyprland.start", function()
  for i, cmd in ipairs({
    "waybar",
    "qs -c kimrity -d",
    "mako",
    "~/.local/bin/wallpaper",
    "hypridle",
    -- Not on PATH: Arch ships it under /usr/lib/hyprpolkitagent/.
    "/usr/lib/hyprpolkitagent/hyprpolkitagent",
    "wl-paste --type text --watch cliphist store",
    "wl-paste --type image --watch cliphist store",
  }) do
    hl.exec_cmd(("sh -c %q"):format(cmd))
  end
end)

-- ---------------------------------------------------------------- bindings
-- Small helper so bindings stay one short line each, like the old .conf.
-- Commands become exec dispatchers; table dispatchers are used as-is.
local function bind(keys, description, dispatcher, options)
  local opts = options or {}
  opts.description = description

  if type(dispatcher) == "string" then
    dispatcher = hl.dsp.exec_cmd(dispatcher)
  end

  hl.bind(keys, dispatcher, opts)
end

-- --- core ---
bind("SUPER + RETURN", "Terminal", "kitty")
bind("SUPER + D", "Menu", "~/.local/bin/menu-toggle")
bind("SUPER + Q", "Close window", hl.dsp.window.close())
bind("SUPER + SHIFT + E", "Exit Hyprland", "hyprctl dispatch exit")
bind("SUPER + SHIFT + V", "Toggle floating", hl.dsp.window.float({ action = "toggle" }))

-- --- apps ---
bind("SUPER + E", "File manager", "kitty yazi")
bind("SUPER + B", "Browser", "firefox")
bind("SUPER + N", "Editor", "kitty -e nvim")

-- --- workspace presets (F1/F2/F3 macro via workspace-launch) ---
bind("SUPER + F1", "Preset F1", "~/.local/bin/workspace-launch F1")
bind("SUPER + F2", "Preset F2", "~/.local/bin/workspace-launch F2")
bind("SUPER + F3", "Preset F3", "~/.local/bin/workspace-launch F3")

-- --- windows ---
bind("SUPER + TAB", "Cycle windows", hl.dsp.window.cycle_next())
bind("SUPER + SHIFT + TAB", "Cycle windows back", hl.dsp.window.cycle_next({ next = false }))
bind("SUPER + P", "Pseudo window", hl.dsp.window.pseudo())
bind("SUPER + J", "Toggle split", hl.dsp.layout("togglesplit"))

-- --- window resize ---
bind("SUPER + CTRL + LEFT", "Shrink width", hl.dsp.window.resize({ x = -40, y = 0, relative = true }))
bind("SUPER + CTRL + RIGHT", "Grow width", hl.dsp.window.resize({ x = 40, y = 0, relative = true }))
bind("SUPER + CTRL + UP", "Shrink height", hl.dsp.window.resize({ x = 0, y = -40, relative = true }))
bind("SUPER + CTRL + DOWN", "Grow height", hl.dsp.window.resize({ x = 0, y = 40, relative = true }))

-- --- scratchpad + system ---
bind("SUPER + GRAVE", "Scratchpad", hl.dsp.workspace.toggle_special("magic"))
bind(
  "SUPER + SHIFT + GRAVE",
  "Move to scratchpad",
  hl.dsp.window.move({ workspace = "special:magic", follow = false })
)
bind("SUPER + L", "Lock screen", "hyprlock")
bind("SUPER + SHIFT + Q", "Power menu", "~/.local/bin/powermenu")
bind("PRINT", "Screenshot (fullscreen)", "~/.local/bin/screenshot full")
bind("SUPER + SHIFT + S", "Screenshot (region)", "~/.local/bin/screenshot region")
bind("SUPER + V", "Clipboard menu", "~/.local/bin/cliphist-menu")

-- --- media keys ---
bind(
  "XF86AudioRaiseVolume",
  "Volume up",
  "wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+",
  { locked = true, repeating = true }
)
bind(
  "XF86AudioLowerVolume",
  "Volume down",
  "wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-",
  { locked = true, repeating = true }
)
bind("XF86AudioMute", "Mute", "wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle", { locked = true })
bind("XF86AudioPlay", "Play/Pause", "playerctl play-pause", { locked = true })
bind("XF86AudioNext", "Next track", "playerctl next", { locked = true })
bind("XF86AudioPrev", "Previous track", "playerctl previous", { locked = true })

bind("SUPER + F", "Fullscreen", hl.dsp.window.fullscreen({ mode = "fullscreen" }))

-- --- focus ---
bind("SUPER + LEFT", "Focus left", hl.dsp.focus({ direction = "l" }))
bind("SUPER + RIGHT", "Focus right", hl.dsp.focus({ direction = "r" }))
bind("SUPER + UP", "Focus up", hl.dsp.focus({ direction = "u" }))
bind("SUPER + DOWN", "Focus down", hl.dsp.focus({ direction = "d" }))

-- --- workspaces 1-5 ---
for workspace = 1, 5 do
  bind(
    "SUPER + " .. workspace,
    "Switch to workspace " .. workspace,
    hl.dsp.focus({ workspace = tostring(workspace) })
  )
  bind(
    "SUPER + SHIFT + " .. workspace,
    "Move to workspace " .. workspace,
    hl.dsp.window.move({ workspace = tostring(workspace), follow = false })
  )
end

-- --- mouse wheel workspaces ---
bind("SUPER + mouse_down", "Next workspace", hl.dsp.focus({ workspace = "e+1" }))
bind("SUPER + mouse_up", "Previous workspace", hl.dsp.focus({ workspace = "e-1" }))

-- --- mouse drag ---
bind("SUPER + mouse:272", "Move window", hl.dsp.window.drag(), { mouse = true })
bind("SUPER + mouse:273", "Resize window", hl.dsp.window.resize(), { mouse = true })
