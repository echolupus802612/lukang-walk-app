"""照片建置的資料保留、來源替換及失敗重試。所有檔案均建立在暫存目錄。"""
import hashlib
import io
import json
import sys
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch

from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_photos
import build_photos_tw
import photo_files


class PhotoBuildTests(unittest.TestCase):
    def setUp(self):
        temporary = TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.photos = self.root / "docs/photos"
        self.photos.mkdir(parents=True)
        (self.root / "data/raw").mkdir(parents=True)
        for name in ("boch_1.1", "boch_1.2", "boch_3.1"):
            self.write_json("data/raw/" + name + ".json", [])
        self.write_json("attractions.json", {"Attractions": []})

    def write_json(self, name, data):
        (self.root / name).write_text(json.dumps(data), encoding="utf-8")

    def read_json(self, name):
        return json.loads((self.root / name).read_text(encoding="utf-8"))

    def build_local(self):
        with patch.object(sys, "argv", ["build_photos", str(self.root), str(self.root / "attractions.json")]):
            build_photos.main()

    def test_local_cleanup_only_removes_retired_or_excluded_owned_photos(self):
        self.write_json("data/lukang.json", [{"id": 2}, {"id": 3, "name": "古井", "lat": 24, "lng": 120}])
        old = {str(i): {"credit": "舊出處"} for i in (1, 2, 3)}
        self.write_json("data/photos.json", {"photos": old, "skip": {"2": True}})
        self.write_json("data/photos_tw.json", {"1001": {"credit": "全臺來源"}})
        for pid in (1, 2, 3, 1001, 9999):
            (self.photos / f"{pid}.webp").write_bytes(str(pid).encode())
        self.build_local()
        self.build_local()
        self.assertEqual({f.name:f.read_bytes() for f in self.photos.iterdir()},
                         {"3.webp": b"3", "1001.webp": b"1001", "9999.webp": b"9999"})
        self.assertEqual(self.read_json("data/photos.json")["photos"], {"3": old["3"]})

    def test_failed_local_download_preserves_bytes_and_credit(self):
        self.write_json("data/lukang.json", [{"id": 3, "name": "古井", "lat": 24, "lng": 120}])
        record = {"url": "original.jpg", "credit": "舊出處"}
        self.write_json("data/photos.json", {"photos": {"3": record}, "commons": {"3": "File:New.jpg"}})
        target = self.photos / "3.webp"
        target.write_bytes(b"original")
        with patch.object(build_photos, "commons_info", side_effect=OSError("offline")), self.assertRaises(SystemExit):
            self.build_local()
        self.assertEqual(target.read_bytes(), b"original")
        self.assertEqual(self.read_json("data/photos.json")["photos"]["3"], record)

    def test_taiwan_source_change_retries_without_losing_the_previous_image(self):
        target = self.photos / "1001.webp"
        target.write_bytes(b"original")
        old = {"url": "https://example.org/old.jpg", "credit": "舊出處"}
        new = "https://data.boch.gov.tw/new.jpg"
        self.write_json("data/photos_tw.json", {"1001": old})
        self.write_json("data/raw/tw_photo_urls.json", {"1001": [new]})
        image = io.BytesIO()
        Image.new("RGB", (48, 30), (0, 220, 0)).save(image, "PNG")
        with patch.object(sys, "argv", ["build_photos_tw", str(self.root)]):
            with patch.object(build_photos_tw, "fetch", side_effect=OSError("offline")), self.assertRaises(SystemExit):
                build_photos_tw.main()
            self.assertEqual(target.read_bytes(), b"original")
            self.assertEqual(self.read_json("data/photos_tw.json")["1001"], old)
            self.write_json("data/raw/tw_photo_urls.json", {"1001": [new, old["url"]]})
            with patch.object(build_photos_tw, "fetch", return_value=image.getvalue()) as fetch:
                build_photos_tw.main()
                build_photos_tw.main()
                self.assertEqual(fetch.call_count, 1)
            with Image.open(target) as result:
                self.assertEqual(result.size, (480, 300))
                self.assertGreater(result.getpixel((240, 150))[1], 200)
            self.assertEqual(self.read_json("data/photos_tw.json")["1001"],
                             {"url": new, "credit": "文化部文化資產局"})



    @staticmethod
    def png(color):
        image = io.BytesIO()
        Image.new("RGB", (48, 30), color).save(image, "PNG")
        return image.getvalue()

    def build_tw(self):
        with patch.object(sys, "argv", ["build_photos_tw", str(self.root)]):
            build_photos_tw.main()

    def interrupt_write(self, stop_at):
        write = photo_files.replace_bytes

        def interrupted(path, data):
            if path == stop_at:
                raise OSError("模擬建置中斷")
            write(path, data)

        return patch.object(photo_files, "replace_bytes", side_effect=interrupted)

    def test_bad_download_does_not_poison_cache_and_old_bad_cache_is_repaired(self):
        cache = self.root / "raw.jpg"
        valid = self.png("green")
        with self.assertRaises(OSError):
            photo_files.cached_webp(cache, lambda: b"<html>offline</html>", (48, 30), 60)
        self.assertFalse(cache.exists())
        cache.write_bytes(b"<html>previous error</html>")
        original = photo_files.cached_webp(cache, lambda: valid, (48, 30), 60)
        self.assertEqual(cache.read_bytes(), valid)
        self.assertEqual(photo_files.cached_webp(cache, lambda: self.fail("重複下載"), (48, 30), 60), original)

    def test_taiwan_source_reverts_after_interrupted_metadata_commit(self):
        a, b = "https://example.org/a.jpg", "https://data.boch.gov.tw/b.jpg"
        urls = "data/raw/tw_photo_urls.json"
        metadata = "data/photos_tw.json"
        target = self.photos / "1001.webp"
        images = {a: self.png("red"), b: self.png("blue")}
        with patch.object(build_photos_tw, "fetch", side_effect=images.__getitem__):
            self.write_json(urls, {"1001": [a]})
            self.build_tw()
            red = target.read_bytes()
            self.write_json(urls, {"1001": [b]})
            with self.interrupt_write(self.root / metadata), self.assertRaises(OSError):
                self.build_tw()
        self.assertNotEqual(target.read_bytes(), red)
        self.assertEqual(self.read_json(metadata)["1001"]["url"], a)
        self.write_json(urls, {"1001": [a]})
        with patch.object(build_photos_tw, "fetch", side_effect=AssertionError("已經有 A 的快取")):
            self.build_tw()
            self.build_tw()
        self.assertEqual(target.read_bytes(), red)
        self.assertEqual(self.read_json(metadata)["1001"], {"url": a, "credit": build_photos_tw.credit(a)})
        self.assertFalse(list((self.root / "data/photos_tw.pending").glob("*.json")))

    def test_local_recovery_distinguishes_both_sides_of_image_replacement(self):
        metadata = "data/photos.json"
        target = self.photos / "3.webp"
        self.write_json("data/lukang.json", [{"id": 3, "name": "古井", "lat": 24, "lng": 120}])
        user = self.root / "art/photos/raw/user"
        user.mkdir(parents=True)
        for color in ["red", "blue"]:
            (user / (color + ".png")).write_bytes(self.png(color))
        def select(color):
            meta = self.read_json(metadata) if (self.root / metadata).exists() else {}
            meta["manual"] = {"3": {"file": color + ".png", "credit": color}} if color else {}
            self.write_json(metadata, meta)

        select("red")
        self.build_local()
        red = target.read_bytes()
        for fail_at, expected_credit in [(target, "red"), (self.root / metadata, "blue")]:
            with self.subTest(expected_credit=expected_credit):
                select("blue")
                with self.interrupt_write(fail_at), self.assertRaises(OSError):
                    self.build_local()
                # 沒有可再次下載的來源，恢復程序仍須依實際留下的圖補齊署名。
                select(None)
                self.build_local()
                self.assertEqual(self.read_json(metadata)["photos"]["3"]["credit"], expected_credit)
                self.assertEqual(target.read_bytes() == red, expected_credit == "red")

    def test_interrupted_marker_cleanup_is_idempotent(self):
        data = self.png("blue")
        metadata = "data/photos_tw.json"
        url = "https://example.org/accepted.jpg"
        self.write_json("data/raw/tw_photo_urls.json", {"1001": [url]})
        marker = self.root / "data/photos_tw.pending/1001.json"
        unlink = Path.unlink

        def stop_at_cleanup(path, *args, **kwargs):
            if path == marker:
                raise OSError("模擬清單已寫入時中斷")
            return unlink(path, *args, **kwargs)

        with patch.object(build_photos_tw, "fetch", return_value=data):
            with patch.object(Path, "unlink", stop_at_cleanup), self.assertRaises(OSError):
                self.build_tw()
        self.assertTrue(marker.is_file())
        committed = (self.photos / "1001.webp").read_bytes()
        self.assertEqual(self.read_json(metadata)["1001"]["url"], url)
        with patch.object(build_photos_tw, "fetch", side_effect=AssertionError("已核對的照片不應再下載")):
            self.build_tw()
        self.assertFalse(marker.exists())
        self.assertEqual((self.photos / "1001.webp").read_bytes(), committed)

    def test_retired_pending_id_cannot_change_another_regions_photo(self):
        self.write_json("data/lukang.json", [])
        self.write_json("data/taiwan.json", [{"id": 1001}])
        self.write_json("data/photos.json", {"photos": {"1001": {"credit": "舊版本"}}})
        ledger = self.root / "data/photos.pending"
        ledger.mkdir()
        national = b"national photo"
        self.write_json("data/photos.pending/1001.json", {
            "sha256": hashlib.sha256(national).hexdigest(), "record": {"credit": "舊版本"}
        })
        target = self.photos / "1001.webp"
        target.write_bytes(national)
        self.build_local()
        self.assertEqual(target.read_bytes(), national)
        self.assertEqual(self.read_json("data/photos.json")["photos"], {})
        self.assertFalse((ledger / "1001.json").exists())


if __name__ == "__main__":
    unittest.main()
