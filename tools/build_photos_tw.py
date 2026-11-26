"""全台地點照片 → docs/photos/<id>.webp（縮小版），出處記在 data/photos_tw.json

用法：python -I -B tools/build_photos_tw.py <專案根目錄>
照片網址來自 build_taiwan.py 產生的 data/raw/tw_photo_urls.json（文資局代表圖優先，其次觀光署景點圖）。
每張裁成 16:10、480×300、WebP 品質 60。原圖快取在 art/photos/raw_tw/（不進版控）。
"""
import hashlib, json, sys, threading, time, urllib.parse, urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from photo_files import build_lock, cached_webp, other_ids, PhotoUpdates

W, H = 480, 300
UA = {"User-Agent": "sanpo-walk-prototype/0.1 (photo build script)"}


def credit(url):
    return "文化部文化資產局" if "boch.gov.tw" in url else "交通部觀光署觀光資訊資料庫"


def fetch(url):
    q = urllib.request.Request(urllib.parse.quote(url, safe=":/?=&%()~+,;@!$'*"), headers=UA)
    for attempt in range(2):
        try:
            with urllib.request.urlopen(q, timeout=40) as response:
                return response.read()
        except Exception:
            if attempt:
                raise
            time.sleep(3)


def build(root):
    urls = json.loads((root / "data" / "raw" / "tw_photo_urls.json").read_text(encoding="utf-8"))
    out, cache = root / "docs" / "photos", root / "art" / "photos" / "raw_tw"
    out.mkdir(parents=True, exist_ok=True)
    cache.mkdir(parents=True, exist_ok=True)
    meta_path = root / "data" / "photos_tw.json"
    meta = json.loads(meta_path.read_text(encoding="utf-8")) if meta_path.exists() else {}
    updates = PhotoUpdates(out, meta_path, meta, meta, meta_path.with_suffix(".pending"),
                           other_ids(root, "lukang.json", "photos.json"), indent=0)
    for pid in urls:
        updates.check_id(pid)
    updates.recover()
    lock, fails, done = threading.Lock(), {}, [0]

    def one(item):
        pid, cands = item
        dest = out / f"{pid}.webp"
        existing = meta.get(pid, {}).get("url") if dest.is_file() else None
        err = "沒有照片網址"
        for u in cands:
            if u == existing:
                break
            key = hashlib.md5(u.encode()).hexdigest()[:10]
            suffix = Path(urllib.parse.urlparse(u).path).suffix.lower()[:5] or ".jpg"
            try:
                image = cached_webp(cache / (key + suffix), lambda: fetch(u), (W, H), 60)
            except Exception as e:
                err = f"{type(e).__name__}: {e}"[:120]
                continue
            with lock:
                updates.install(pid, {"credit": credit(u), "url": u}, image)
            break
        else:
            with lock:
                fails[pid] = err
        with lock:
            done[0] += 1
            if done[0] % 200 == 0:
                print(done[0], "處", flush=True)
                updates.checkpoint()

    with ThreadPoolExecutor(6) as ex:
        list(ex.map(one, urls.items()))
    updates.checkpoint()
    (root / "art" / "photos" / "tw_failed.json").write_text(json.dumps(fails, ensure_ascii=False, indent=0), encoding="utf-8")
    kb = sum((out / f"{k}.webp").stat().st_size for k in meta if (out / f"{k}.webp").exists()) // 1024
    print(f"有照片 {len(meta)} 處，失敗 {len(fails)}，共 {kb} KB")
    if any(pid in meta for pid in fails):
        raise SystemExit("部分既有照片未能更新，已保留原圖與出處。")


def main():
    root = Path(sys.argv[1])
    with build_lock(root):
        build(root)


if __name__ == "__main__":
    main()
