"""Render dashboard.html to an e-ink-ready PNG on a timer and serve it over HTTP.

    uv run server/serve.py          # render loop + server
    uv run server/serve.py --once   # render a single frame and exit
"""
import json
import sys
import threading
import time
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from PIL import Image
from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "out"
PAGE = ROOT / "server" / "dashboard.html"


def load_config():
    return json.loads((ROOT / "config.json").read_text())


def render(cfg):
    OUT.mkdir(exist_ok=True)
    raw = OUT / "raw.png"
    with sync_playwright() as p:
        browser = p.chromium.launch()
        page = browser.new_page(viewport={"width": cfg["width"], "height": cfg["height"]})
        page.add_init_script(f"window.CONFIG = {json.dumps(cfg)};")
        page.goto(PAGE.as_uri())
        page.wait_for_function("window.READY === true", timeout=20000)
        page.screenshot(path=str(raw))
        browser.close()

    # The reMarkable panel shows 16 grays; snap to those levels so nothing gets dithered on-device.
    img = Image.open(raw).convert("L").point(lambda v: round(v / 17) * 17)
    # Rotate counter-clockwise into the panel's native portrait framing.
    # 90 = landscape with the tablet's spine (wide bezel) at the top.
    if cfg.get("rotate"):
        img = img.rotate(cfg["rotate"], expand=True)
    tmp = OUT / "dashboard.tmp.png"
    img.save(tmp, optimize=True)
    tmp.replace(OUT / "dashboard.png")  # atomic swap so the device never fetches a half-written file
    print(time.strftime("%H:%M:%S"), "rendered", OUT / "dashboard.png", flush=True)


def render_loop():
    while True:
        cfg = load_config()
        try:
            render(cfg)
        except Exception as e:
            print("render failed:", e, flush=True)
        time.sleep(cfg["refresh_minutes"] * 60)


if __name__ == "__main__":
    cfg = load_config()
    if "--once" in sys.argv:
        render(cfg)
        sys.exit()
    threading.Thread(target=render_loop, daemon=True).start()
    handler = partial(SimpleHTTPRequestHandler, directory=str(OUT))
    print(f"serving {OUT} on :{cfg['port']}", flush=True)
    ThreadingHTTPServer(("0.0.0.0", cfg["port"]), handler).serve_forever()
