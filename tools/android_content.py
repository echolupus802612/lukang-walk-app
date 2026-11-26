"""產生原生 Android App 使用的地點資料，以及可選擇發布到網站的內容索引。"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import shutil
import tempfile

from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
BUNDLED_REVISION = 2
PHOTO_WIDTH = 240


def encode(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def catalog_bytes(root):
    def read(name):
        return json.loads((root / "data" / name).read_text(encoding="utf-8"))

    photos = {**read("photos.json")["photos"], **read("photos_tw.json")}
    result = []
    ids = set()
    for place in read("lukang.json") + read("taiwan.json"):
        point = {k: place[k] for k in ("id", "name", "lat", "lng", "cat", "tag", "desc")
                 if k in ("id", "lat", "lng") or place.get(k)}
        number = point["id"]
        if number in ids:
            raise ValueError(f"地點編號重複：{number}")
        ids.add(number)
        credit = photos.get(str(number), {}).get("credit")
        if credit and (root / "docs" / "photos" / f"{number}.webp").is_file():
            point["ph"] = "文" if "文化資產" in credit else "觀" if "觀光" in credit else "共"
        result.append(point)
    return encode(result)


def resize_photo(source, target):
    with Image.open(source) as original:
        height = max(1, round(original.height * PHOTO_WIDTH / original.width))
        image = original.convert("RGB").resize((PHOTO_WIDTH, height), Image.Resampling.LANCZOS)
        image.save(target, format="WEBP", quality=48, method=4)


def prepare_content(root, destination, revision):
    if revision < 1:
        raise ValueError("內容版號必須大於零。")
    docs = root / "docs"
    photos = destination / "photos"
    if photos.resolve() == (docs / "photos").resolve():
        raise ValueError("Android 縮圖需要獨立的輸出目錄。")
    photos.mkdir(parents=True, exist_ok=True)
    places = destination / "places.json"
    places.write_bytes(catalog_bytes(root))
    files = {"places.json": places, "credits.html": root / "ios/LukangWalk/Credits/credits.html"}
    for path in sorted((docs / "voice").glob("*.mp3")):
        files["voice/" + path.name] = path

    def make_photo(source):
        target = photos / source.name
        resize_photo(source, target)
        return "photos/" + source.name, target

    with ThreadPoolExecutor(max_workers=min(8, os.cpu_count() or 1)) as workers:
        files.update(workers.map(make_photo, sorted((docs / "photos").glob("*.webp"))))

    # 更新索引與 APK 使用同一批輸出，校驗值對應玩家實際取得的縮圖。
    hashes = {name: hashlib.sha256(path.read_bytes()).hexdigest() for name, path in files.items()}
    index = destination / "android-content.json"
    index.write_bytes(encode({"format": 1, "revision": revision, "files": hashes}))
    return files, index


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--revision", type=int, required=True, help="高於前一次發布的內容版號")
    parser.add_argument("--output", type=Path, required=True, help="內容網站的根目錄")
    args = parser.parse_args()
    # Android 的更新放在專用子目錄，保留網站和 iPhone App 使用的原始素材。
    output = args.output / "android-content"
    with tempfile.TemporaryDirectory(prefix="walk-content-") as temporary:
        files, index = prepare_content(ROOT, Path(temporary), args.revision)
        for name, source in files.items():
            target = output / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, target)
        shutil.copyfile(index, output / index.name)
    print(f"已產生第 {args.revision} 版內容：{output}")
