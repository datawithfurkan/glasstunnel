# dmgbuild settings for the Glasstunnel installer window.
# scripts/dmg/build-dmg.sh passes app, background, and icon with -D.
# Icon positions must match the artwork drawn by scripts/dmg/background.py.
import os.path

application = defines["app"]  # noqa: F821 (provided by dmgbuild)
app_name = os.path.basename(application)

format = "UDZO"
filesystem = "HFS+"
files = [application]
symlinks = {"Applications": "/Applications"}
icon = defines["icon"]  # noqa: F821

background = defines["background"]  # noqa: F821
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
# 400 points of artwork plus the title bar.
window_rect = ((200, 140), (660, 428))
default_view = "icon-view"
show_icon_preview = False
include_icon_view_settings = True
include_list_view_settings = False

arrange_by = None
grid_spacing = 100
label_pos = "bottom"
text_size = 13
icon_size = 112
icon_locations = {
    app_name: (180, 172),
    "Applications": (480, 172),
}
