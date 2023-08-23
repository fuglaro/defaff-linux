# Overview

* A stack of windows per instance.
* 10 workspaces per instance.
* Windows sit on one workspace at a time (except for the pinned window) and can be moved across them within the same instance.
* 3 separate instances.
* No border on windows but area around selected window is highlighted, potentially offscreen, and underneath the pinned window.
* Window layering is in stack order within:
  * Pinned
  * Hub (when in Hub mode)
  * Selected
  * Hub (when not in Hub mode)
  * Floating (default state)
  * Tiled (and not fullscreen)
  * Fullscreen
* Pinning clears tiled and fullscreen states and vice versa. Pinning also shows on all workstations within instance. Only one pinned window per instance.
* Screens attach to workspaces and can be moved across them.
* Workspaces adjust their resolution only when going from a detatched to an attached state.
* Screens can be arranged around the primary display as if in a 3x3 grid.
* Screens can be rotated.
* Windows smaller than the minimum window size are scaled.
* Hub that sits on each display in the bottom left position.
* Shortcut keys are configurable (for keyboard alternatives).
* Windows always stay within screen boundaries (with configurable padding for curved edges and notches), even when moving. Moving windows may resize them to fit but will only permanently resize them at the end of the move operation.
* Launching always opens a new process with windows on the current instance and workspace.
* Restarting or loging out does not restore windows.
* Hub contents:
  * Launcher: >
  * Status Bar (User + Systems)
  * Instance and Workspace indicator: 1:[1]234567890
* Tech stach:
  * Zig
  * Linux: Wayland

# Controls

* Capslock is swapped to LeftClick.
* Click: Select (and Raise if Floating).
* MovePointer: Focus follows mouse.
* Activate Hub: `[Meta (while held, or after double-press and until next press)]`
* Hub:
  * Open Launcher: `[Space]`, `[Click on Launcher or Status Bar]`
  * Open cheatsheet: `[Click on Hub Instance and Workspace indicator]`
  * Switch window through layers: `[j/k]`, `[Vertical scroll (or swipe 2 up/down)]`
  * Switch window through tiled columns: `[h/l]`
  * Switch workspace: `[,/.]`, `[1234567890]`, `[Shift + Vertical scroll (or swipe 2 up/down)]`
  * Move window to workspace: `[Shift + 1234567890]`
  * Switch workspace with window: `[Shift + ,/.]`
  * Reorder workspaces: `[-/=]`
  * Move / Resize window: `[Drag top-left/bottom-right section]`
  * Raise / Switch window: `[Tab]`
  * Fullscreen window: `[Enter]`
  * Tile window: `[;]`
  * Pin window: `[p]`
  * Close window: `[q]`
  * Lock screen: `[Escape]`
  * Switch instance: `[<up>/<down>]`

# Configs

## hub.toml

```toml
[Launcher]
# Curved monitor offset
button="     >"
```

## Status Bar

* Taken as a list of executables from inside: `~/.config/defaff/desktop/statusbar/` and `/etc/config/defaff/desktop/statusbar/`
* They are sorted by name, and then each is launched, and each time a new line is output, it is updated in the status bar.
* Each one is separated by a blank space.

# Launcher

* Respects keyword search flavor of:  https://specifications.freedesktop.org/menu-spec/menu-spec-latest.html (see: https://wiki.archlinux.org/title/Desktop_entries).
* Search based (all case insensitive, keywords include command etc):
  * Start `typing` keywords or the command.
  * Matches shown above in order:
    * Name that matches last word exactly.
    * Weightings of:
      * Name that begins with the last word +10.
      * Keyword matches +10.
      * Keyword beginning with word +1.
      * Fuzzy word association +1 (may not be implemented).
* Options are shown with <Name> - <Comment> (Categories).
* First match is selected by default.
* `[Up/down arrows]` change selection, and `typing` resets.
* `[Enter]` launches selection.
