"""
Inline cards (MCP Apps views) the assistant shows in the chat: the day's map, the quote with its
proposal and Sign & Pay, and the findings with their photos.

Each card is one self-contained HTML page: the MCP Apps client (vendor/ext-apps.js), Leaflet for the
map, and the shared Verdant styles and helpers are inlined, so nothing loads from a CDN. Only map
tiles come from the network.
"""

import functools
import re
from pathlib import Path

HERE = Path(__file__).resolve().parent
VENDOR = HERE / "vendor"


@functools.cache
def _apps_sdk() -> str:
    """The ext-apps bundle with its ES module export turned into window.McpApps, so it can be inlined."""
    source = (VENDOR / "ext-apps.js").read_text()
    start = source.rindex("export{")
    names = source[start + len("export{"):source.index("}", start)]
    pairs = [part.split(" as ") for part in names.split(",")]
    exports = ",".join(f"{alias.strip()}:{local.strip()}" for local, alias in pairs)
    return source[:start] + f"window.McpApps={{{exports}}};"


def page(name: str) -> str:
    html = (HERE / f"{name}.html").read_text()
    parts = {
        "<!--VERDANT-->": f"<style>{(HERE / 'verdant.css').read_text()}</style>"
                          f"<script type=\"module\">{_apps_sdk()}</script>"
                          f"<script type=\"module\">{(HERE / 'verdant.js').read_text()}</script>",
        "<!--LEAFLET-->": f"<style>{(VENDOR / 'leaflet.css').read_text()}</style>"
                          f"<script>{(VENDOR / 'leaflet.js').read_text()}</script>",
    }
    return re.sub("|".join(map(re.escape, parts)), lambda m: parts[m.group(0)], html)
