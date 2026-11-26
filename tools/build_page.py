"""把地點資料嵌進 src/app.html → docs/index.html（App 專用；iPhone 隨附此頁，Android 由獨立內容站下載）

用法：python -I -B tools/build_page.py <專案根目錄>
地點 = data/lukang.json（鹿港一帶，人工整理）＋ data/taiwan.json（全台其他地方，build_taiwan.py 產生）。
資料直接嵌在頁面裡，不另外載入：離線的 iPhone App 從本機檔案開頁面，讀不到另外的 JSON 檔。
"""
import json, sys
from pathlib import Path

root = Path(sys.argv[1])
places = json.loads((root / "data" / "lukang.json").read_text(encoding="utf-8"))
tw_path = root / "data" / "taiwan.json"
if tw_path.exists():
    places += json.loads(tw_path.read_text(encoding="utf-8"))
ids = [p["id"] for p in places]
assert len(ids) == len(set(ids)), "地點編號重複"
slim = [{k: p[k] for k in ("id", "name", "lat", "lng", "cat", "tag", "desc") if p.get(k) or k in ("id", "lat", "lng")}
        for p in places]
# 分享透卡上寫的所在地：全台地點用「鄉鎮・縣市」；鹿港資料沒有記鄉鎮（含部分福興鄉），寫「鹿港一帶・彰化縣」
for x, p in zip(slim, places):
    x["area"] = "・".join(v for v in (p.get("town"), p.get("city")) if v) or "鹿港一帶・彰化縣"
# 有照片的地點標上出處代號（文＝文資局、觀＝觀光署、共＝創用 CC 照片：維基共享資源、Flickr），照片在 docs/photos/<id>.webp
ph = {}
for f in ("photos.json", "photos_tw.json"):
    path = root / "data" / f
    if path.exists():
        meta = json.loads(path.read_text(encoding="utf-8"))
        ph.update(meta.get("photos", meta) if f == "photos.json" else meta)
for x in slim:
    c = ph.get(str(x["id"]), {}).get("credit", "")
    if c and (root / "docs" / "photos" / f"{x['id']}.webp").exists():
        x["ph"] = "文" if "文化資產" in c else "觀" if "觀光" in c else "共"
blob = json.dumps(slim, ensure_ascii=False, separators=(",", ":")).replace("</", "<\\/")
html = (root / "src" / "app.html").read_text(encoding="utf-8")
assert "/*DATA*/[]" in html and "/*SHARE_CARD*/" in html
# 分享透卡的繪製程式直接嵌進頁面（單一檔案，離線也能用）
card_js = (root / "src" / "share_card.js").read_text(encoding="utf-8")
assert "</script" not in card_js.lower()
html = html.replace("/*SHARE_CARD*/", card_js)
out = root / "docs" / "index.html"
out.parent.mkdir(exist_ok=True)
out.write_bytes(html.replace("/*DATA*/[]", blob).encode("utf-8"))
print(f"{len(slim)} 個地點（有照片 {sum(1 for x in slim if x.get('ph'))}、有簡介 {sum(1 for x in slim if x.get('desc'))}）→ {out}（{out.stat().st_size // 1024} KB）")
