"""
Pictures the assistant returns inline when the chat app can't show cards: the day on a map, and a
contact sheet of a visit's Before and After photos. JPEG bytes; the server base64-encodes them.
"""

import asyncio
import io
import math

import httpx
from PIL import Image, ImageDraw, ImageFont

TILES = "https://tile.openstreetmap.org/{z}/{x}/{y}.png"
TILE_PX = 256
FOREST = (31, 77, 58)
LEAF = (63, 143, 92)
INK = (22, 36, 29)
MUTED = (96, 112, 104)
LINE = (215, 225, 219)
FALLBACK_CENTER = (41.957, -88.081)


def _font(size: int, bold: bool = False):
    for name in (("Helvetica.ttc", 1 if bold else 0), ("Arial Bold.ttf" if bold else "Arial.ttf", 0)):
        try:
            return ImageFont.truetype(name[0], size, index=name[1])
        except OSError:
            continue
    return ImageFont.load_default(size)


def _world(lat: float, lon: float, zoom: int) -> tuple[float, float]:
    scale = TILE_PX * 2 ** zoom
    x = (lon + 180) / 360 * scale
    y = (1 - math.asinh(math.tan(math.radians(lat))) / math.pi) / 2 * scale
    return x, y


def _zoom_for(points, width: int, height: int, pad_x: int, pad_y: int) -> int:
    if len(points) < 2:
        return 14
    for zoom in range(16, 3, -1):
        xs, ys = zip(*(_world(lat, lon, zoom) for lat, lon in points))
        if max(xs) - min(xs) <= width - 2 * pad_x and max(ys) - min(ys) <= height - 2 * pad_y:
            return zoom
    return 4


async def _tiles(client: httpx.AsyncClient, zoom: int, x0: float, y0: float, width: int, height: int) -> Image.Image:
    canvas = Image.new("RGB", (width, height), (238, 242, 239))
    first_x, first_y = int(x0 // TILE_PX), int(y0 // TILE_PX)
    last_x, last_y = int((x0 + width) // TILE_PX), int((y0 + height) // TILE_PX)

    async def fetch(tx: int, ty: int):
        url = TILES.format(z=zoom, x=tx % 2 ** zoom, y=ty)
        try:
            response = await client.get(url)
            response.raise_for_status()
            tile = Image.open(io.BytesIO(response.content)).convert("RGB")
            canvas.paste(tile, (int(tx * TILE_PX - x0), int(ty * TILE_PX - y0)))
        except (httpx.HTTPError, OSError):
            pass

    await asyncio.gather(*(fetch(tx, ty) for tx in range(first_x, last_x + 1) for ty in range(first_y, last_y + 1)))
    return canvas


def _dashed(draw: ImageDraw.ImageDraw, a, b, dash: int = 10, gap: int = 7):
    length = math.dist(a, b)
    if not length:
        return
    step = 0.0
    while step < length:
        end = min(step + dash, length)
        draw.line([(a[0] + (b[0] - a[0]) * step / length, a[1] + (b[1] - a[1]) * step / length),
                   (a[0] + (b[0] - a[0]) * end / length, a[1] + (b[1] - a[1]) * end / length)], fill=FOREST, width=4)
        step = end + gap


async def day_map(visits: list[dict], width: int = 960, height: int = 540) -> bytes | None:
    """The day's visits as numbered pins on an OpenStreetMap map, in visit order, with the route between them."""
    stops = [v for v in visits if v.get("latitude") is not None and v.get("longitude") is not None]
    if not stops:
        return None
    points = [(float(v["latitude"]), float(v["longitude"])) for v in stops]
    zoom = _zoom_for(points, width, height, pad_x=170, pad_y=60)
    xs, ys = zip(*(_world(lat, lon, zoom) for lat, lon in points))
    x0 = (max(xs) + min(xs)) / 2 - width / 2 + 90  # room for the labels right of each pin
    y0 = (max(ys) + min(ys)) / 2 - height / 2
    async with httpx.AsyncClient(timeout=10, headers={"User-Agent": "verdant-field-assistant demo"}) as client:
        image = await _tiles(client, zoom, x0, y0, width, height)

    draw = ImageDraw.Draw(image)
    pins = [(x - x0, y - y0) for x, y in zip(xs, ys)]
    for a, b in zip(pins, pins[1:]):
        _dashed(draw, a, b)
    number_font, label_font = _font(17, bold=True), _font(15, bold=True)
    for index, ((x, y), visit) in enumerate(zip(pins, stops), start=1):
        draw.ellipse([x - 16, y - 16, x + 16, y + 16], fill=FOREST, outline="white", width=3)
        draw.text((x, y), str(index), fill="white", font=number_font, anchor="mm")
        label = f"{_short_time(visit.get('startTimeLocal'))}  {visit.get('accountName', '')}"
        box = draw.textbbox((x + 22, y), label, font=label_font, anchor="lm")
        draw.rounded_rectangle([box[0] - 6, box[1] - 4, box[2] + 6, box[3] + 4], radius=6, fill="white", outline=LINE)
        draw.text((x + 22, y), label, fill=INK, font=label_font, anchor="lm")
    credit = "© OpenStreetMap contributors"
    small = _font(11)
    box = draw.textbbox((width - 6, height - 4), credit, font=small, anchor="rd")
    draw.rectangle([box[0] - 4, box[1] - 2, width, height], fill=(255, 255, 255))
    draw.text((width - 6, height - 4), credit, fill=MUTED, font=small, anchor="rd")
    return _jpeg(image)


def _short_time(local: str | None) -> str:
    # "Wed Nov 18, 9:00 AM Central" -> "9:00 AM"
    if not local:
        return ""
    parts = local.split(", ", 1)[-1].split(" ")
    return " ".join(parts[:2])


def contact_sheet(title: str, findings: list[dict]) -> bytes | None:
    """One row per finding with photos: what was found, then its Before and After photos (JPEG bytes each)."""
    rows = [f for f in findings if f.get("before") or f.get("after")]
    if not rows:
        return None
    thumb, label_width, gap, per_side = 200, 250, 12, 2
    width = label_width + 2 * (per_side * (thumb + gap)) + 3 * gap
    header = 76
    height = header + len(rows) * (thumb + gap) + gap
    image = Image.new("RGB", (width, height), (247, 250, 248))
    draw = ImageDraw.Draw(image)
    draw.rectangle([0, 0, width, 48], fill=FOREST)
    draw.text((gap, 24), title, fill="white", font=_font(19, bold=True), anchor="lm")
    before_x = label_width + gap
    after_x = before_x + per_side * (thumb + gap) + gap
    heading = _font(14, bold=True)
    draw.text((before_x, 62), "BEFORE", fill=MUTED, font=heading, anchor="lm")
    draw.text((after_x, 62), "AFTER", fill=MUTED, font=heading, anchor="lm")
    name_font, detail_font = _font(17, bold=True), _font(14)
    for index, finding in enumerate(rows):
        top = header + index * (thumb + gap)
        draw.rounded_rectangle([gap // 2, top - 4, width - gap // 2, top + thumb + 4], radius=10, fill="white", outline=LINE)
        draw.text((gap + 4, top + 14), finding.get("zone") or "", fill=INK, font=name_font)
        detail = " · ".join(x for x in (finding.get("pest"), finding.get("severity")) if x)
        draw.text((gap + 4, top + 40), detail, fill=MUTED, font=detail_font)
        if finding.get("treatmentStatus"):
            draw.text((gap + 4, top + 62), finding["treatmentStatus"], fill=LEAF, font=detail_font)
        for start, photos in ((before_x, finding.get("before") or []), (after_x, finding.get("after") or [])):
            for slot, data in enumerate(photos[-per_side:]):
                with Image.open(io.BytesIO(data)) as photo:
                    photo = photo.convert("RGB")
                    photo.thumbnail((thumb, thumb))
                    x = start + slot * (thumb + gap) + (thumb - photo.width) // 2
                    image.paste(photo, (x, top + (thumb - photo.height) // 2))
            if not photos:
                draw.text((start + 4, top + thumb // 2), "No photo yet", fill=LINE, font=detail_font, anchor="lm")
    return _jpeg(image)


def _jpeg(image: Image.Image) -> bytes:
    buffer = io.BytesIO()
    image.save(buffer, "JPEG", quality=82)
    return buffer.getvalue()
