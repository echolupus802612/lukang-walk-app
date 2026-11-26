"""建置照片、驗證原圖快取，並在中斷後補齊照片的出處紀錄。"""
from contextlib import contextmanager
import hashlib
from io import BytesIO
import json
import os
from pathlib import Path
import re
from tempfile import NamedTemporaryFile

from PIL import Image, ImageOps


def replace_bytes(path, data):
    with NamedTemporaryFile(dir=path.parent, delete=False) as handle:
        pending = Path(handle.name)
    try:
        pending.write_bytes(data)
        pending.replace(path)
    finally:
        pending.unlink(missing_ok=True)


def encode_webp(data, size, quality):
    with Image.open(BytesIO(data)) as source:
        image = ImageOps.exif_transpose(source).convert("RGB")
    cropped = ImageOps.fit(image, size, Image.Resampling.LANCZOS, centering=(0.5, 0.45))
    with BytesIO() as encoded:
        cropped.save(encoded, "WEBP", quality=quality, method=6)
        return encoded.getvalue()


def cached_webp(cache, download, size, quality):
    if cache.is_file():
        try:
            return encode_webp(cache.read_bytes(), size, quality)
        except (OSError, ValueError, SyntaxError):
            pass  # 舊快取可能是錯誤頁面，重新向同一個來源取得。
    raw = download()
    webp = encode_webp(raw, size, quality)
    replace_bytes(cache, raw)
    return webp


@contextmanager
def build_lock(root):
    # 兩個建置工具共用照片目錄。程序中斷時，作業系統會自動解除檔案鎖。
    lock_path = root / "art/photos/raw/.photo-build.lock"
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    with lock_path.open("a+b") as lock:
        lock.seek(0)
        if os.name == "nt":
            import msvcrt
            msvcrt.locking(lock.fileno(), msvcrt.LK_NBLCK, 1)
        else:
            import fcntl
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield


def other_ids(root, places_name, photos_name):
    places = root / "data" / places_name
    photos = root / "data" / photos_name
    ids = set()
    if places.is_file():
        ids.update(str(place["id"]) for place in json.loads(places.read_text(encoding="utf-8")))
    if photos.is_file():
        meta = json.loads(photos.read_text(encoding="utf-8"))
        ids.update(meta.get("photos", {}) if photos_name == "photos.json" else meta)
    return ids


class PhotoUpdates:
    def __init__(self, out, metadata_path, metadata, records, ledger, protected, indent):
        self.out = out
        self.metadata_path = metadata_path
        self.metadata = metadata
        self.records = records
        self.ledger = ledger
        self.protected = protected
        self.indent = indent
        self.pending = set()
        self.ledger.mkdir(parents=True, exist_ok=True)

    def check_id(self, pid):
        if not re.fullmatch(r"[0-9]+", pid) or pid in self.protected:
            raise ValueError(f"照片編號格式錯誤或與另一份地點清單重複：{pid}")

    def recover(self):
        # 圖片的原子替換在清單之前。比對雜湊可辨別中斷時留下的是新圖還是舊圖。
        for marker in self.ledger.glob("*.json"):
            pid = marker.stem
            if pid in self.protected:
                # 這一區已經退出該編號時，只清理自己的舊紀錄，保留另一區的圖片。
                self.records.pop(pid, None)
                self.pending.add(marker)
                continue
            self.check_id(pid)
            row = json.loads(marker.read_text(encoding="utf-8"))
            dest = self.out / f"{pid}.webp"
            if dest.is_file() and hashlib.sha256(dest.read_bytes()).hexdigest() == row["sha256"]:
                self.records[pid] = row["record"]
            self.pending.add(marker)
        if self.pending:
            self.checkpoint()

    def install(self, pid, record, image):
        self.check_id(pid)
        marker = self.ledger / f"{pid}.json"
        row = {"sha256": hashlib.sha256(image).hexdigest(), "record": record}
        replace_bytes(marker, json.dumps(row, ensure_ascii=False).encode("utf-8"))
        replace_bytes(self.out / f"{pid}.webp", image)
        self.records[pid] = record
        self.pending.add(marker)

    def checkpoint(self):
        data = json.dumps(self.metadata, ensure_ascii=False, indent=self.indent).encode("utf-8")
        replace_bytes(self.metadata_path, data)
        for marker in self.pending:
            marker.unlink(missing_ok=True)
        self.pending.clear()
