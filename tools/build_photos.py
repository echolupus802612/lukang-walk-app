"""替地點找官方照片 → docs/photos/<id>.webp，出處記在 data/photos.json

用法：python -I -B tools/build_photos.py <專案根目錄> <觀光署 AttractionList.json>

來源優先順序：
  0. data/photos.json 的 "manual"：人工挑的其他 CC 授權照片（網址、作者、授權手填）
     data/photos.json 的 "commons"：人工挑的維基共享資源（Wikimedia Commons）檔名，作者與授權從 API 取得
  1. 文化部文化資產局 開放資料的代表圖（data/raw/boch_*.json 的 representImage）
  2. 交通部觀光署 觀光資訊資料庫的景點圖片（第一張）
每張裁成 16:10、寬 720，存 WebP。原圖下載到 art/photos/raw/（不進版控）。
data/photos.json 裡 "skip" 列出的編號不配照片（人工看過覺得不對的）。
"""
import hashlib, json, math, re, sys, time, urllib.parse, urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from photo_files import build_lock, cached_webp, encode_webp, other_ids, PhotoUpdates

W, H = 720, 450
CENTER = (24.0565, 120.4335)
UA = {"User-Agent": "lukang-walk-prototype/0.1 (photo build script)"}


def hv(a, b):
    R = 6371000
    p1, p2 = math.radians(a[0]), math.radians(b[0])
    dp, dl = p2 - p1, math.radians(b[1] - a[1])
    h = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * R * math.atan2(math.sqrt(h), math.sqrt(1 - h))


def norm(n):
    return re.sub(r"[\s()（）・·]|^彰化縣?|^鹿港", "", n or "")


def same(a, b):
    a, b = norm(a), norm(b)
    return bool(a and b) and (a == b or a in b or b in a)


def candidates(root, attr_path):
    boch = []
    for f in ("boch_1.1.json", "boch_1.2.json", "boch_3.1.json"):
        for x in json.loads((root / "data" / "raw" / f).read_text(encoding="utf-8")):
            img = x.get("representImage") or {}
            try:
                la, lo = float(x["latitude"]), float(x["longitude"])
            except (KeyError, TypeError, ValueError):
                continue
            if img.get("original") and hv(CENTER, (la, lo)) < 6000:
                boch.append((x["caseName"], (la, lo), img["original"]))
    attr = []
    for x in json.loads(Path(attr_path).read_text(encoding="utf-8-sig"))["Attractions"]:
        if not x.get("Images") or not x.get("PositionLat"):
            continue
        ll = (float(x["PositionLat"]), float(x["PositionLon"]))
        if hv(CENTER, ll) < 6000:
            attr.append((x["AttractionName"], ll, x["Images"][0]["URL"]))
    return boch, attr


def commons_info(title):
    """維基共享資源檔案 → (縮圖網址, 作者, 授權, 檔案頁網址)"""
    q = urllib.parse.urlencode({"action": "query", "titles": title, "prop": "imageinfo", "format": "json",
                                "iiprop": "url|extmetadata", "iiurlwidth": 1280})
    for attempt in range(5):
        try:
            r = json.load(urllib.request.urlopen(urllib.request.Request(
                "https://commons.wikimedia.org/w/api.php?" + q, headers=UA), timeout=60))
            break
        except urllib.error.HTTPError as e:
            if e.code != 429 or attempt == 4:
                raise
            time.sleep(10 * (attempt + 1))
    ii = list(r["query"]["pages"].values())[0]["imageinfo"][0]
    m = ii.get("extmetadata", {})
    artist = re.sub(r"<[^>]+>", "", m.get("Artist", {}).get("value", "")).strip()
    return ii["thumburl"], artist, m.get("LicenseShortName", {}).get("value", ""), ii["descriptionurl"]


def fetch(url):
    q = urllib.request.Request(urllib.parse.quote(url, safe=":/?=&%()"), headers=UA)
    with urllib.request.urlopen(q, timeout=60) as response:
        return response.read()


def build(root, attr_path):
    places = json.loads((root / "data" / "lukang.json").read_text(encoding="utf-8"))
    meta_path = root / "data" / "photos.json"
    meta = json.loads(meta_path.read_text(encoding="utf-8")) if meta_path.exists() else {}
    skip = {int(k) for k in meta.get("skip", {})}
    raw, out = root / "art" / "photos" / "raw", root / "docs" / "photos"
    raw.mkdir(parents=True, exist_ok=True)
    out.mkdir(parents=True, exist_ok=True)
    boch, attr = candidates(root, attr_path)
    photos = meta.setdefault("photos", {})
    protected = other_ids(root, "taiwan.json", "photos_tw.json")
    updates = PhotoUpdates(out, meta_path, meta, photos, meta_path.with_suffix(".pending"), protected, indent=1)
    active_ids = {str(p["id"]) for p in places if p["id"] not in skip}
    for pid in active_ids:
        updates.check_id(pid)
    updates.recover()
    previous_ids = set(photos)
    for pid in previous_ids:
        if pid not in active_ids or not (out / f"{pid}.webp").is_file():
            del photos[pid]
    failures = []
    for p in places:
        if p["id"] in skip:
            continue
        ll = (p["lat"], p["lng"])
        pick, extra = None, {}
        title = meta.get("commons", {}).get(str(p["id"]))
        man = meta.get("manual", {}).get(str(p["id"]))   # 人工指定的其他 CC 授權照片（例如 Flickr），作者授權手填
        if man and man.get("file"):   # 本機檔案（使用者提供的照片），放在 art/photos/raw/user/，不進版控
            pick = (man["credit"], None, man["file"])
            extra = {k: man[k] for k in ("source", "note") if k in man}
        elif man:
            pick = (man["credit"], man["url"], man["page"])
            extra = {k: man[k] for k in ("author", "license", "page")}
        elif title:
            try:
                url, artist, lic, page = commons_info(title)
            except (OSError, ValueError, KeyError, IndexError) as e:
                failures.append(p["id"])
                print(f"{p['id']:3d} {p['name']} 取得照片來源失敗：{e}")
                continue
            pick = ("Wikimedia Commons", url, title)
            extra = {"author": artist, "license": lic, "page": page}
            time.sleep(1)
        for name, at, url in ([] if pick else boch):
            if same(name, p["name"]) and hv(at, ll) < 300:
                pick = ("文化部文化資產局", url, name)
                break
        if not pick:
            for name, at, url in attr:
                if same(name, p["name"]) and hv(at, ll) < 300:
                    pick = ("交通部觀光署觀光資訊資料庫", url, name)
                    break
        if not pick:
            continue
        credit, url, matched = pick
        try:
            if url is None:
                image = encode_webp((raw / "user" / matched).read_bytes(), (W, H), 72)
            else:
                key = hashlib.md5(url.encode()).hexdigest()[:8]   # 換了來源就重新下載，不會拿到舊圖
                cache = raw / f"{p['id']}_{key}{Path(urllib.parse.urlparse(url).path).suffix.lower() or '.jpg'}"
                image = cached_webp(cache, lambda: fetch(url), (W, H), 72)
        except Exception as e:
            failures.append(p["id"])
            print(f"{p['id']:3d} {p['name']} 下載失敗：{e}")
            continue
        updates.install(str(p["id"]), {"credit": credit, "url": url, "matched": matched, **extra}, image)
        print(f"{p['id']:3d} {p['name']} ← {credit}（{matched}）")
    # 只清理由鹿港清單管理且已下架或明確排除的編號。全臺照片共用這個目錄。
    for pid in previous_ids - active_ids - protected:
        if re.fullmatch(r"[0-9]+", pid):
            (out / f"{pid}.webp").unlink(missing_ok=True)
    meta.setdefault("_note", "地點照片出處（build_photos.py 產生）；skip＝人工排除、不配照片的編號")
    updates.checkpoint()
    kb = sum((out / f"{pid}.webp").stat().st_size for pid in photos) // 1024
    print(f"共 {len(photos)} 張，{kb} KB")
    if failures:
        raise SystemExit(f"{len(failures)} 處照片未能更新；既有照片與出處已保留。")


def main():
    root = Path(sys.argv[1])
    with build_lock(root):
        build(root, sys.argv[2])


if __name__ == "__main__":
    main()
