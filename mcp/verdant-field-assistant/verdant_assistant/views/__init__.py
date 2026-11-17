"""
Inline cards (MCP Apps views) the assistant shows in the chat: the day's map, the quote with its
proposal and Sign & Pay, and the findings with their photos.

Each card is one self-contained HTML page: the MCP Apps client (vendor/ext-apps.js), Leaflet for the
map, and the shared Verdant styles and helpers are inlined, so nothing loads from a CDN. Only map
tiles come from the network.
"""

import functools
import json
import re
from pathlib import Path

HERE = Path(__file__).resolve().parent
VENDOR = HERE / "vendor"
CARDS = ("day_map", "quote", "findings")


@functools.cache
def _apps_sdk() -> str:
    """The ext-apps bundle with its ES module export turned into window.McpApps, so it can be inlined."""
    source = (VENDOR / "ext-apps.js").read_text()
    start = source.rindex("export{")
    names = source[start + len("export{"):source.index("}", start)]
    pairs = [part.split(" as ") for part in names.split(",")]
    exports = ",".join(f"{alias.strip()}:{local.strip()}" for local, alias in pairs)
    return source[:start] + f"window.McpApps={{{exports}}};"


def page(name: str, client: str | None = None) -> str:
    """The card as one HTML page. `client` replaces the MCP Apps client script (see browser_page)."""
    html = (HERE / f"{name}.html").read_text()
    parts = {
        "<!--VERDANT-->": f"<style>{(HERE / 'verdant.css').read_text()}</style>"
                          f"<script type=\"module\">{client or _apps_sdk()}</script>"
                          f"<script type=\"module\">{(HERE / 'verdant.js').read_text()}</script>",
        "<!--LEAFLET-->": f"<style>{(VENDOR / 'leaflet.css').read_text()}</style>"
                          f"<script>{(VENDOR / 'leaflet.js').read_text()}</script>",
    }
    return re.sub("|".join(map(re.escape, parts)), lambda m: parts[m.group(0)], html)


def browser_page(name: str, args: dict, token: str, result: dict | None = None) -> str:
    """The card as a standalone browser page: the tool arguments, its result (if the card renders one
    directly) and the page token are baked in."""
    data = json.dumps({"args": args, "token": token, "result": result}, default=str).replace("<", "\\u003c")
    setup = f"<script>const __v = {data}; window.VERDANT_ARGS = __v.args; window.VERDANT_TOKEN = __v.token; window.VERDANT_RESULT = __v.result;</script>"
    html = page(name, client=(HERE / "browser.js").read_text())
    return html.replace("<head>", f"<head><title>Verdant</title>{setup}", 1)
