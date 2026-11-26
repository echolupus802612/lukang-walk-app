"""Generate the offline iPhone credits page from the published photo records."""

import argparse
import json
from html import escape
from pathlib import Path
from urllib.parse import urlsplit


GOV_LICENSE = "政府資料開放授權條款第 1 版"
LICENSE_URLS = {
    GOV_LICENSE: "https://data.gov.tw/license",
    "CC BY 2.0": "https://creativecommons.org/licenses/by/2.0/",
    "CC BY 3.0": "https://creativecommons.org/licenses/by/3.0/",
    "CC BY-SA 4.0": "https://creativecommons.org/licenses/by-sa/4.0/",
}
GOV_PROVIDERS = {"文化部文化資產局", "交通部觀光署觀光資訊資料庫"}


def link(url, label):
    parsed = urlsplit(url)
    if parsed.scheme not in {"https", "http"} or not parsed.hostname:
        raise ValueError(f"Expected a public source URL for {label!r}")
    return f'<a href="{escape(url, quote=True)}">{escape(label)}</a>'


def photo_item(place, record):
    provider = record["credit"]
    authorship = " · ".join(filter(None, [record.get("author"), provider]))
    terms = record.get("license")
    if terms is None and provider in GOV_PROVIDERS:
        terms = GOV_LICENSE
    if terms not in LICENSE_URLS:
        raise ValueError(f"Check the license for photo {place['id']}: {terms!r}")
    url = record.get("page") or record["url"]
    original_title = record.get("matched", "")
    label = original_title.removeprefix("File:") if original_title.startswith("File:") else "原始照片"
    return (
        f'<li data-photo="{place["id"]}"><strong>{escape(place["name"])}</strong>'
        f'<p>{escape(authorship)} · {link(LICENSE_URLS[terms], terms)}</p>'
        f'<p>{link(url, label)}</p></li>'
    )


def font_credit(root, family, directory, license_file):
    url = f"https://github.com/google/fonts/tree/main/ofl/{directory}"
    terms = (root / "docs/fonts" / license_file).read_text(encoding="utf-8").strip()
    return (f'<p>{link(url, family)}</p>'
            f'<details><summary>{escape(family)} 授權全文</summary>'
            f'<pre lang="en">{escape(terms)}</pre></details>')


def render(root):
    places = json.loads((root / "data/lukang.json").read_text(encoding="utf-8"))
    places += json.loads((root / "data/taiwan.json").read_text(encoding="utf-8"))
    photos = json.loads((root / "data/photos.json").read_text(encoding="utf-8"))["photos"]
    tw = json.loads((root / "data/photos_tw.json").read_text(encoding="utf-8"))
    assets = {p.stem for p in (root / "docs/photos").glob("*.webp")}
    places_by_id = {str(p["id"]): p for p in places}
    if assets != set(photos) | set(tw) or set(photos) & set(tw) or not assets.issubset(places_by_id):
        raise ValueError("The bundled photos, their credits and the active place IDs disagree.")
    # 鹿港一帶的照片逐張列出處；全台其他地方的照片都來自兩個政府開放資料，依來源合計
    items = "\n".join(photo_item(places_by_id[i], photos[i]) for i in sorted(photos, key=int))
    tw_count = {c: sum(1 for r in tw.values() if r["credit"] == c) for c in sorted(GOV_PROVIDERS)}
    return f"""<!doctype html>
<html lang="zh-Hant-TW">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="color-scheme" content="light dark">
<title>資料來源與授權 · 散步吧</title>
<style>
:root {{ color-scheme: light dark; --paper: #fbf3e6; --ink: #3a1a12; --link: #87331f; --line: #d8c7b6 }}
@media (prefers-color-scheme: dark) {{
  :root {{ --paper: #241310; --ink: #f6e9da; --link: #f3dccb; --line: #69483e }}
}}
* {{ box-sizing: border-box }}
body {{ margin: 0; background: var(--paper); color: var(--ink);
  font: -apple-system-body; line-height: 1.6; overflow-wrap: anywhere }}
main {{ max-width: 520px; margin: auto; padding: 1.25rem 1.25rem max(2rem, env(safe-area-inset-bottom)) }}
h1, h2 {{ font-family: "LXGW WenKai TC", "Songti TC", serif; line-height: 1.25 }}
h1 {{ font-size: 1.85rem; margin: 0 0 1.25rem }} h2 {{ font-size: 1.3rem; margin: 0 0 .5rem }}
section + section {{ border-top: 1px solid var(--line); padding-top: 1rem; margin-top: 1.25rem }}
p {{ margin: .4rem 0 }} a {{ color: var(--link); text-underline-offset: .18em }}
:focus-visible {{ outline: 3px solid currentColor; outline-offset: 2px }}
summary {{ cursor: pointer; padding: .75rem 0; font-weight: 600 }}
.photos {{ list-style: none; margin: 0; padding: 0 }}
.photos li {{ border-top: 1px solid var(--line); padding: .75rem 0 }} .photos p {{ margin: .15rem 0 }}
pre {{ white-space: pre-wrap; font: inherit; line-height: 1.45 }}
</style>
</head>
<body><main>
<h1>資料來源與授權</h1>
<section>
<h2>地點與文字</h2>
<p>地點名稱、座標及文資身分參考文化部文化資產局、交通部觀光署、OpenStreetMap 與中文維基百科。鹿港一帶的地點經人工合併整理；全台其他地方的地點取自文化部文化資產局與交通部觀光署的開放資料。</p>
<p>© OpenStreetMap contributors。鹿港一帶的地點資料經整理後依 ODbL 1.0 提供。{link("https://www.openstreetmap.org/copyright", "OpenStreetMap 著作權說明")} · {link("https://opendatacommons.org/licenses/odbl/1-0/", "ODbL 條款")} · {link("https://github.com/echolupus802612/lukang-walk/blob/main/data/lukang.json", "鹿港地點資料")}</p>
<p>政府資料來自文化部文化資產局、交通部觀光署及內政部。{link("https://nchdb.boch.gov.tw/", "國家文化資產網")} · {link("https://data.gov.tw/dataset/7777", "景點－觀光資訊資料庫")} · {link("https://data.gov.tw/dataset/8203", "全國宗教資訊系統資料－寺廟")} · {link(LICENSE_URLS[GOV_LICENSE], GOV_LICENSE)}</p>
<p>鹿港的部分地點簡介依中文維基百科貢獻者的條目改寫，依 {link(LICENSE_URLS["CC BY-SA 4.0"], "CC BY-SA 4.0")} 提供。{link("https://github.com/echolupus802612/lukang-walk/blob/main/data/place_overrides.json", "鹿港改寫簡介的來源紀錄")}</p>
<p>全台其他地方的地點簡介，依文化部文化資產局與交通部觀光署開放資料的內容濃縮改寫。{link("https://github.com/echolupus802612/lukang-walk/blob/main/data/taiwan.json", "全台其他地點資料")} · {link("https://github.com/echolupus802612/lukang-walk/blob/main/data/desc_tw.json", "全台其他地點的簡介文字")}</p>
</section>
<section>
<h2>地點照片</h2>
<p>照片經裁切、縮小後使用。創用 CC 照片的改作沿用各原作的授權。</p>
<details><summary>查看鹿港一帶 {len(photos)} 張照片的作者與出處</summary><ul class="photos">
{items}
</ul></details>
<p>全台其他地方的 {len(tw)} 張照片取自{"、".join(f"{c}（{k} 張）" for c, k in tw_count.items())}，縮小後使用，依 {link(LICENSE_URLS[GOV_LICENSE], GOV_LICENSE)}。{link("https://github.com/echolupus802612/lukang-walk/blob/main/data/photos_tw.json", "每張照片的原始網址")}</p>
</section>
<section>
<h2>小嚮導</h2>
<p>狼耳少年是作者自有的 VTuber 形象，角色圖像保留所有權利。語音使用 BreezeBlue 的 Sparks 音色製作。</p>
</section>
<section>
<h2>字體</h2>
<p>App 收錄霞鶩文楷 TC 與思源黑體 TC 的部分字元，兩套字體皆採用 SIL Open Font License 1.1。</p>
{font_credit(root, "LXGW WenKai TC", "lxgwwenkaitc", "WenKai-OFL.txt")}
{font_credit(root, "Noto Sans TC", "notosanstc", "Noto-OFL.txt")}
</section>
</main></body></html>
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", nargs="?", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--check", action="store_true", help="fail if the bundled page is stale")
    args = parser.parse_args()
    document = render(args.root)
    for relative in ("ios/LukangWalk/Credits/credits.html", "docs/credits.html"):
        output = args.root / relative
        if args.check:
            if not output.is_file() or output.read_text(encoding="utf-8") != document:
                parser.exit(1, f"Regenerate {relative} with tools/build_ios_credits.py\n")
        else:
            output.parent.mkdir(parents=True, exist_ok=True)
            output.write_bytes(document.encode("utf-8"))


if __name__ == "__main__":
    main()
