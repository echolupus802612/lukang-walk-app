"""重建 App 與網頁共用的離線字型。需要 fontTools 與 Brotli，日常建置不需要執行。"""
import json
from pathlib import Path
from tempfile import TemporaryDirectory
from urllib.parse import quote
from urllib.request import urlretrieve

from fontTools import subset
from fontTools.ttLib import TTFont
from fontTools.varLib.instancer import instantiateVariableFont


ROOT = Path(__file__).resolve().parents[1]
DEST = ROOT / "docs" / "fonts"
WENKAI = "4e5f06dbb274a27ebe71ed54ea706b3ee40eabd9/ofl/lxgwwenkaitc"
NOTO = "3be1884c48c3e45b52ecc725676a08f87776373e/ofl/notosanstc"
FONTS = [
    (WENKAI, "LXGWWenKaiTC-Regular.ttf", "walk-kai.woff2"),
    (WENKAI, "LXGWWenKaiTC-Bold.ttf", "walk-kai-bold.woff2"),
    (NOTO, "NotoSansTC[wght].ttf", "walk-sans.woff2"),
]


def build():
    DEST.mkdir(parents=True, exist_ok=True)
    text = (ROOT / "src/app.html").read_text(encoding="utf-8")
    for path in ("data/lukang.json", "data/taiwan.json", "art/voice/jobs.json"):
        records = json.loads((ROOT / path).read_text(encoding="utf-8"))
        text += "".join(str(item.get(key) or "") for item in records
                        for key in ("name", "desc", "tag", "text"))
    # iPhone 原生畫面也用文楷，把 Swift 裡的字串一併收進子集。
    for source in sorted((ROOT / "ios/LukangWalk").glob("*.swift")):
        text += source.read_text(encoding="utf-8")
    characters = set(range(32, 127)) | {ord(c) for c in text}
    with TemporaryDirectory() as tmp:
        for version, filename, output in FONTS:
            base = f"https://raw.githubusercontent.com/google/fonts/{version}"
            source = Path(tmp) / filename
            urlretrieve(f"{base}/{quote(filename)}", source)
            options = subset.Options()
            options.name_IDs = ["*"]  # Preserve the upstream copyright and license records.
            options.layout_features = ["*"]
            with TTFont(source, recalcTimestamp=False) as font:
                cutter = subset.Subsetter(options=options)
                cutter.populate(unicodes=characters)
                cutter.subset(font)
                if version == NOTO:
                    for weight, name in ((500, output), (700, "walk-sans-bold.woff2")):
                        instance = instantiateVariableFont(font, {"wght": weight})
                        instance.flavor = "woff2"
                        instance.save(DEST / name)
                    continue
                font.flavor = "woff2"
                font.save(DEST / output)
            print(output, (DEST / output).stat().st_size)
        for family, version in (("WenKai", WENKAI), ("Noto", NOTO)):
            urlretrieve(f"https://raw.githubusercontent.com/google/fonts/{version}/OFL.txt",
                        DEST / f"{family}-OFL.txt")


if __name__ == "__main__":
    build()
