#!/usr/bin/env python3
"""Build a SELF-CONTAINED offline copy of the hosted flow for the iOS SDK.

Why this exists: on iOS, WKWebView cannot intercept `https://` sub-resource requests
(URLSchemeHandler only handles custom schemes), so — unlike Android's
shouldInterceptRequest — we can't serve `/sdk/*.js` from the bundle at request time.
Instead we INLINE the SDK module graph as a `data:` URL so the page has no external
module fetch and loads fully offline via `loadHTMLString(_:baseURL:)`.

The page's only remaining network calls are the `/v1/*` API (which legitimately needs
the server — offline they fail and the capture is queued) and cosmetic assets
(fonts/poster) that degrade gracefully. iOS uses native Vision detection, not the
MediaPipe WASM, so no engine bundling is needed.

Output: sdk/ios/Sources/FacededupLiveness/Resources/flow-offline.html

Usage:  LICENSE=fdk_xxx python3 scripts/bundle-offline-flow.py [--base https://facededup.ai]
"""
import base64, os, re, sys, urllib.request

BASE = "https://facededup.ai"
LICENSE = os.environ.get("LICENSE", "")
for i, a in enumerate(sys.argv):
    if a == "--base" and i + 1 < len(sys.argv):
        BASE = sys.argv[i + 1].rstrip("/")
if not LICENSE:
    sys.exit("set LICENSE=fdk_... (needed to fetch the license-gated page + modules)")

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(HERE, "sdk/ios/Sources/FacededupLiveness/Resources/flow-offline.html")


def fetch(path):
    url = f"{BASE}{path}{'&' if '?' in path else '?'}license={LICENSE}"
    req = urllib.request.Request(url, headers={"X-License-Key": LICENSE})
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.read().decode("utf-8")


def main():
    html = fetch("/demo/?flow=liveness")
    # Bundle the ES module graph (index re-exports client/signals/capture) into ONE
    # self-contained module. Dependency order: signals -> client; capture standalone.
    signals = fetch("/sdk/signals.js")
    client = fetch("/sdk/client.js")
    capture = fetch("/sdk/capture.js")
    # client imports collectDeviceContext from ./signals.js — now in the same module,
    # so strip that relative import line.
    client = re.sub(r'^\s*import\s+\{[^}]*\}\s+from\s+["\']\./signals\.js["\'];?\s*$',
                    '', client, flags=re.M)
    bundle = (
        "// --- bundled offline SDK (signals + client + capture) ---\n"
        + signals + "\n" + client + "\n" + capture + "\n"
    )
    # sanity: the two symbols the page imports must be exported by the bundle
    for sym in ("LivenessClient", "collectDeviceContext"):
        if f"export class {sym}" not in bundle and f"export async function {sym}" not in bundle \
           and f"export function {sym}" not in bundle:
            sys.exit(f"bundle is missing export: {sym}")

    data_url = "data:text/javascript;base64," + base64.b64encode(bundle.encode("utf-8")).decode("ascii")
    # Repoint the page's module import at the inlined bundle (no network).
    new_html, n = re.subn(r'from\s+["\']/sdk/index\.js["\']', f'from "{data_url}"', html)
    if n != 1:
        sys.exit(f"expected exactly one `/sdk/index.js` import, found {n}")

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w") as f:
        f.write(new_html)
    print(f"wrote {OUT}  ({len(new_html)} bytes; bundle {len(bundle)} bytes inlined)")


if __name__ == "__main__":
    main()
