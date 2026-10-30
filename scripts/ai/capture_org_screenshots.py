#!/usr/bin/env python3
"""Capture Lightning page screenshots from an org with headless Chrome.

Each page gets a one-time login link from `sf org open --url-only` that redirects to the
page; the link is passed straight to Chrome and never printed. Uses Chrome's own
--screenshot mode because Selenium-driven headless Chrome crashes in some environments.

    python scripts/ai/capture_org_screenshots.py --target-org <username> --out-dir /tmp/shots \
        quote=/lightning/r/Quote/0Q0.../view wo=/lightning/r/WorkOrder/0WO.../view

The default 1024x704 window at scale 1.5625 gives 1600x1100 images, matching the demo deck's
screenshot slots. If a side panel is still loading in the image, run that page again or
change --budget (both shorter and longer budgets have fixed it).
"""
import argparse
import json
import os
import subprocess
import sys
import tempfile

CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"


def login_url(target_org, path):
    out = subprocess.run(
        ["sf", "org", "open", "--url-only", "--json", "--target-org", target_org, "-p", path],
        capture_output=True, text=True,
    )
    try:
        return json.loads(out.stdout)["result"]["url"]
    except (ValueError, KeyError):
        sys.exit(f"Could not get a login link for {path}; check that {target_org} is authorized.")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--target-org", required=True, help="sf CLI username or alias")
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--window", default="1024,704", help="Chrome window size in CSS pixels")
    ap.add_argument("--scale", default="1.5625", help="Device scale factor (image size = window x scale)")
    ap.add_argument("--budget", default="45000", help="Chrome --virtual-time-budget in ms")
    ap.add_argument("--chrome", default=CHROME)
    ap.add_argument("pages", nargs="+", help="name=/lightning/r/Object/Id/view")
    args = ap.parse_args()

    os.makedirs(args.out_dir, exist_ok=True)
    profile = tempfile.mkdtemp(prefix="chrome-shots-")
    failed = 0
    for spec in args.pages:
        name, _, path = spec.partition("=")
        if not path.startswith("/"):
            sys.exit(f"Expected name=/path, got {spec!r}")
        dest = os.path.join(args.out_dir, f"{name}.png")
        result = subprocess.run(
            [args.chrome, "--headless=new", "--disable-gpu", "--no-first-run", "--hide-scrollbars",
             f"--user-data-dir={profile}", f"--window-size={args.window}",
             f"--force-device-scale-factor={args.scale}",
             f"--virtual-time-budget={args.budget}", f"--screenshot={dest}",
             login_url(args.target_org, path)],
            capture_output=True, text=True, timeout=240,
        )
        ok = "bytes written" in (result.stdout + result.stderr)
        failed += not ok
        print(f"{name}: {dest if ok else 'FAILED'}")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
