#!/usr/bin/env python3
"""nanobanana - generate an image with Google's Gemini image models.

  nanobanana.py "prompt" out.png [--aspect 16:9] [--model gemini-3-pro-image]

Reads the API key from GEMINI_API_KEY (or GEMINI_KEY); the key is sent only
in the request header to generativelanguage.googleapis.com.  Standard
library only.  Writes whatever image format the model returns (usually
PNG or JPEG) to the given path.
"""

import argparse
import base64
import json
import os
import sys
import urllib.error
import urllib.request

API = "https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent"


def generate(prompt, aspect="16:9", model="gemini-3-pro-image", timeout=300):
    key = os.environ.get("GEMINI_API_KEY") or os.environ.get("GEMINI_KEY")
    if not key:
        raise SystemExit("set GEMINI_API_KEY")
    body = {
        "contents": [{"parts": [{"text": prompt}]}],
        "generationConfig": {"responseModalities": ["IMAGE"], "imageConfig": {"aspectRatio": aspect}},
    }
    req = urllib.request.Request(API.format(model=model), data=json.dumps(body).encode(),
                                 headers={"x-goog-api-key": key, "Content-Type": "application/json"})
    try:
        data = json.load(urllib.request.urlopen(req, timeout=timeout))
    except urllib.error.HTTPError as e:
        raise SystemExit(f"API error {e.code}: {e.read().decode(errors='replace')[:500]}")
    for cand in data.get("candidates", []):
        for part in cand.get("content", {}).get("parts", []):
            inline = part.get("inlineData") or part.get("inline_data")
            if inline:
                return base64.b64decode(inline["data"]), inline.get("mimeType", "")
    raise SystemExit("no image in the response: " + json.dumps(data)[:500])


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("prompt")
    ap.add_argument("out")
    ap.add_argument("--aspect", default="16:9")
    ap.add_argument("--model", default="gemini-3-pro-image")
    args = ap.parse_args()
    img, mime = generate(args.prompt, args.aspect, args.model)
    with open(args.out, "wb") as fh:
        fh.write(img)
    print(f"{args.out}: {len(img)} bytes, {mime}")


if __name__ == "__main__":
    main()
