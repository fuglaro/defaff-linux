# Controls

**Press and hold, or double press, the WIN/CMD/META (⊞) key to activate the hub:**
*  ⊞ +     `Space` - **LAUNCH** a new windowed application.
*  ⊞ + `Backspace` - **CLOSE** the selected window.
*  ⊞ +      `Drag` - **MOVE**/resize/tab windows by dragging the left/right/top.
*  ⊞ +  `,.`/`1-9` - **WS**(workspace) change (also ⊞+Shift+Scroll).
*  ⊞ +      `hjkl` - **NAV**igate between windows and tabs (also ⊞+Scroll).
*  ⊞ +       `Tab` - **SWAP** between windows (raising them to the top).
*  ⊞ +     `Enter` - **MAX**imize to fullscreen (toggle).
*  ⊞ +         `;` - **TILE** or float the window.
*  ⊞ +         `:` - **SPLIT** tiling: span-right/new-column/stack-normally.
*  ⊞ +    `Escape` - **EXIT** and either lock the screen, or disconnect.
*  ⊞ +         `H` - **PIN** and hold the window above others.
*  ⊞ +        `<>` - **YANK** window across workspaces, moving with it.
*  ⊞ +        `JK` - **LIFT** the entire workspace to a new position.
*  ⊞ +         `L` - **CONTEXT** switch (between 3 different sessions).
* (⊞ +)    `Click` - **SEL**ect window or tab, and raise to top if floating.

* Hint: `⊞ + Spc-LAUNCH Bkspc-CLOSE Drag-MOVE ,.--WS hjkl-NAV Tab-SWAP Enter-MAX ;-TILE :-SPLIT Esc-EXIT <>-YANK JK-LIFT L-CONTEXT H-PIN`
* Meme: `⊞ + ⎵ LNCH ⌫ X ,.<>JK WS hjkl⇥ NAV ⏎ MAX ;: TILE Esc ⛝ L ↕ H PIN`

# Overview

* Stack of windows distributed across 10 workspaces and organised in layers.
* Window layering order:
  * Pinned
  * Hub (when active)
  * Selected
  * Hub
  * Floating (default state)
  * Tiled (and not fullscreen)
  * Fullscreen
* Navigating through windows will respect the layering of the stack.
* Navigating horizontally will jump through tabs, and then the columns of tiled mode.
* One pixel borders except when fullscreen (secondary color, or primary if selected).
* Pinning clears tiled and fullscreen states and vice versa.
* Displays attach to workspaces and can be moved across them.
* Workspaces adjust their resolution to the smallest attached display, and scales for larger displays.
* Displays are arranged and rotated as if in a 3x3 grid.
* Fullscreen windows that are also pinned are drawn across all displays.
* Layout constrints:
  * Windows smaller than their hinted minimum window size are scaled.
  * There is a minimum windows size across all windows.
  * Windows always stay within display boundaries (with configurable padding for curved edges and notches), even when moving.
  * Moving windows may resize them to fit but will only permanently resize them at the end of the move operation.
  * Windows may have their true position and size outside the display area, if the workspace size decreases, but those windows will still display within the workspace dimensions.
  * Windows will be moved to other workspaces when dragging, if the mouse travels to a new workspace. 
* Launching always opens a new process with windows on the current session and workspace.
* Restarting or loging out does not restore windows.
* Hub sits on each display in the bottom left position.
* Hub contents:
  * Launcher: >
  * Indicator: 1:[1]234567890 (clicking opens help)
  * Status Bar (User + Systems)
* Tech stach:
  * Zig
  * Linux: Wayland
* Tiling:
  * Windows stack vertically into columns.
  * Windows can split the layout in span or column modes.
  * Span makes windows extend to the right, shortening all subsequent columns.
  * Column make windows act as column headers for new columns.
  * Windows can be moved and resized, with tiling sizes adjusting to window sizes.
  * Arranging:
    * Move by dragging left side of windows when Hub activated.
    * Resize by dragging right side of windows when Hub activated.
    * Window auto arranges to new size but doesn't rearrange other windows until release.
    * Resizing to the very right activates spanning.
    * Moving to the very top activates column header.
    * Moving column header to the very bottom collapses the column.
* Tabs:
  * Tab by dragging to the top (100th of screen height) of another window.
  * Untab by dragging from the tab line.
* 3 contexts providing different sessions, each with their own independent stack of windows and workspaces. 
* Capslock is remapped to Click.
* Default colors:
  * Primary: #defaff
  * Secondary: #210a500
* Focus follows mouse mode:
  * Can be activated in the configs.
  * Mouse position decides which window recieves input events, which may not be the selected window.

# Configs

## hub.toml

```toml
[Launcher]
# Curved monitor offset
button="     >"
[Controls]
hub_keys="Ctrl+Alt"
launch="f"
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

* Integrate file browser for docs??? hmn :/
