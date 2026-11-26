"""以 Android SDK 35 與 JDK 17 建置、縮減並簽署散步吧 APK。預設為線上版。"""
import argparse
from hashlib import sha256
import os
from pathlib import Path
import secrets
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from zipfile import ZIP_DEFLATED, ZIP_STORED, ZipFile

ROOT = Path(__file__).resolve().parents[1]
ANDROID = ROOT / "android"
ANDROID_ATTR = "{http://schemas.android.com/apk/res/android}"
KEY_ALIAS = "lukangwalk"
PASSWORD_ENV = "LUKANGWALK_APK_STORE_PASS"


def run(args, *, env=None, cwd=None):
    subprocess.run([str(arg) for arg in args], env=env, cwd=cwd, check=True)


def native_assets(work, content_revision):
    from android_content import BUNDLED_REVISION, prepare_content

    try:
        from fontTools.ttLib.woff2 import decompress, haveBrotli
    except ImportError:
        haveBrotli = False
    if not haveBrotli:
        raise ValueError("建置字型需要 fontTools 與 Brotli。請在執行建置的 Python 環境安裝 fonttools[woff]。")

    docs = ROOT / "docs"
    revision = BUNDLED_REVISION if content_revision is None else content_revision
    assets, index = prepare_content(ROOT, work / "content", revision)
    assets["content-index.json"] = index
    if "<script" in assets["credits.html"].read_text(encoding="utf-8").lower():
        raise ValueError("離線授權頁含有指令碼。")
    for path in sorted((docs / "sprites").glob("*.webp")):
        assets["sprites/" + path.name] = path
    for family in ("walk-kai", "walk-kai-bold", "walk-sans", "walk-sans-bold"):
        font = work / f"{family}.ttf"
        decompress(docs / "fonts" / f"{family}.woff2", font)
        assets[f"fonts/{font.name}"] = font
    for name in ("WenKai-OFL.txt", "Noto-OFL.txt"):
        assets[f"fonts/{name}"] = docs / "fonts" / name
    return assets


def signing_key(keytool, env):
    parent = Path.home() / ".android"
    directory = parent / "lukangwalk-signing"
    key_name = "lukangwalk.p12"
    password_name = "password.txt"
    if not directory.exists():
        parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        # 將完整的金鑰與密碼一併放入固定位置，並行建置時沿用先完成的一組。
        with tempfile.TemporaryDirectory(prefix="lukang-sign-", dir=parent) as temporary:
            candidate = Path(temporary) / "key"
            candidate.mkdir(mode=0o700)
            password = secrets.token_urlsafe(36)
            password_file = candidate / password_name
            password_file.touch(mode=0o600)
            password_file.write_text(password, encoding="ascii")
            run([keytool, "-genkeypair", "-alias", KEY_ALIAS, "-keyalg", "RSA",
                 "-keysize", "3072", "-sigalg", "SHA256withRSA", "-validity", "10000",
                 "-dname", "CN=Lukang Walk Android", "-storetype", "PKCS12",
                 "-keystore", candidate / key_name, "-storepass:env", PASSWORD_ENV,
                 "-keypass:env", PASSWORD_ENV], env={**env, PASSWORD_ENV: password})
            (candidate / key_name).chmod(0o600)
            try:
                candidate.rename(directory)
            except OSError:
                if not directory.is_dir():
                    raise
    keystore = directory / key_name
    password_file = directory / password_name
    if not keystore.is_file() or not password_file.is_file():
        raise ValueError(f"簽章檔案不完整，請從備份還原：{directory}")
    return keystore, password_file.read_text(encoding="ascii").strip()


def build(sdk, java_home, output, content_revision=None, *, variant="web"):
    if variant not in ("web", "native"):
        raise ValueError(f"無法辨識的建置版本：{variant}")
    if content_revision is not None:
        if variant != "native":
            raise ValueError("只有原生版會內附地點資料，請搭配 --variant native 指定內容版號。")
        if content_revision < 1:
            raise ValueError("內容版號必須大於零。")
    suffix = ".exe" if os.name == "nt" else ""
    build_tools = sdk / "build-tools" / "35.0.0"
    platform = sdk / "platforms" / "android-35" / "android.jar"
    aapt = build_tools / ("aapt2" + suffix)
    align = build_tools / ("zipalign" + suffix)
    java = java_home / "bin" / ("java" + suffix)
    javac = java_home / "bin" / ("javac" + suffix)
    keytool = java_home / "bin" / ("keytool" + suffix)
    r8 = build_tools / "lib" / "d8.jar"
    lambda_stubs = build_tools / "core-lambda-stubs.jar"
    signer = build_tools / "lib" / "apksigner.jar"
    for path in (platform, aapt, align, java, javac, keytool, r8, lambda_stubs, signer):
        if not path.is_file():
            raise ValueError(f"找不到建置工具：{path}")
    env = {**os.environ, "JAVA_HOME": str(java_home), "PYTHONUTF8": "1"}
    run([sys.executable, "-B", ROOT / "tools" / "check_zh_tw.py"], env=env, cwd=ROOT)
    if variant == "native":
        run([sys.executable, "-B", ROOT / "tools" / "build_ios_credits.py", "--check"], env=env, cwd=ROOT)

    manifest_path = ANDROID / ("AndroidManifest.xml" if variant == "web" else "native-AndroidManifest.xml")
    source_path = ANDROID / ("web-src" if variant == "web" else "src")
    manifest = ET.parse(manifest_path).getroot()
    if manifest.find("application").get(ANDROID_ATTR + "debuggable", "false") != "false":
        raise ValueError("請關閉應用程式的偵錯模式後再建置。")
    min_sdk = manifest.find("uses-sdk").attrib[ANDROID_ATTR + "minSdkVersion"]
    if output is None:
        version = manifest.attrib[ANDROID_ATTR + "versionName"]
        output = ANDROID / "build" / f"Walk-{version}-{variant}.apk"
    output = output.resolve()
    if output.suffix.lower() != ".apk":
        raise ValueError("輸出檔名必須以 .apk 結尾。")

    with tempfile.TemporaryDirectory(prefix="lukang-apk-") as temporary:
        work = Path(temporary)
        # 所有工具均以工作目錄的相對路徑存取專案，以支援包含中文的原始路徑。
        shutil.copytree(source_path, work / "src")
        shutil.copytree(ANDROID / "res", work / "res")
        shutil.copyfile(manifest_path, work / "AndroidManifest.xml")
        for name in ("generated", "classes", "dex"):
            (work / name).mkdir()
        run([aapt, "compile", "--dir", "res", "-o", "res.zip"], cwd=work, env=env)
        run([aapt, "link", "-o", "app.apk", "-I", platform, "--manifest",
             "AndroidManifest.xml", "--java", "generated", "--proguard", "manifest.pro",
             "res.zip"], cwd=work, env=env)
        sources = [p.relative_to(work) for directory in ("src", "generated")
                   for p in sorted((work / directory).rglob("*.java"))]
        run([javac, "-encoding", "UTF-8", "-source", "8", "-target", "8",
             "-bootclasspath", os.pathsep.join(map(str, (platform, lambda_stubs))),
             "-d", "classes", *sources], cwd=work, env=env)
        with ZipFile(work / "classes.jar", "w") as archive:
            for path in sorted((work / "classes").rglob("*.class")):
                archive.write(path, path.relative_to(work / "classes"))
        run([java, "-cp", r8, "com.android.tools.r8.R8", "--release", "--min-api", min_sdk,
             "--lib", platform, "--pg-conf", "manifest.pro", "--pg-map-output", "mapping.txt",
             "--output", "dex", "classes.jar"], cwd=work, env=env)
        if variant == "native":
            assets = native_assets(work, content_revision)
        else:
            assets = {"offline-seed.tsv": ANDROID / "web-assets" / "offline-seed.tsv"}
        with ZipFile(work / "app.apk", "a") as archive:
            for path in sorted((work / "dex").glob("classes*.dex")):
                archive.write(path, path.name, ZIP_STORED)
            for name, path in assets.items():
                # 角色圖、照片與語音已經壓縮。MediaPlayer 可直接使用語音的檔案描述元。
                compression = ZIP_STORED if path.suffix in (".mp3", ".webp") else ZIP_DEFLATED
                archive.write(path, "assets/" + name, compression)
        run([align, "-f", "4", "app.apk", "aligned.apk"], cwd=work, env=env)
        key, password = signing_key(keytool, env)
        run([java, "-jar", signer, "sign", "--ks", key, "--ks-key-alias", KEY_ALIAS,
             "--ks-pass", "env:" + PASSWORD_ENV, "--key-pass", "env:" + PASSWORD_ENV,
             "--v4-signing-enabled", "false", "--out", "signed.apk", "aligned.apk"],
            env={**env, PASSWORD_ENV: password}, cwd=work)
        run([java, "-jar", signer, "verify", "--verbose", "--print-certs", "signed.apk"],
            cwd=work, env=env)
        run([align, "-c", "4", "signed.apk"], cwd=work, env=env)
        with ZipFile(work / "signed.apk") as archive:
            names = set(archive.namelist())
            expected = {"assets/" + name for name in assets}
            if "classes.dex" not in names or expected != {n for n in names if n.startswith("assets/")}:
                raise ValueError("APK 的程式或素材與選擇的版本不符。")
            if any(n.lower().endswith((".html", ".htm", ".js", ".mjs", ".java", ".map"))
                   and n != "assets/credits.html" for n in names):
                raise ValueError("APK 含有未預期的網頁程式或原始碼。")

        output.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix=".lukang-apk-", dir=output.parent) as delivery:
            ready = Path(delivery) / "signed.apk"
            shutil.copyfile(work / "signed.apk", ready)
            # 依 APK 指紋保留混淆對照表，供日後還原當機紀錄；對照表不隨 APK 散布。
            digest = sha256()
            with ready.open("rb") as stream:
                for block in iter(lambda: stream.read(1024 * 1024), b""):
                    digest.update(block)
            mapping = ANDROID / "build" / "mappings" / digest.hexdigest()
            mapping.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(work / "mapping.txt", mapping / "mapping.txt")
            os.replace(ready, output)
    print(f"已建置並驗證 APK：{output}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sdk", type=Path, default=os.getenv("ANDROID_HOME") or
                        os.getenv("ANDROID_SDK_ROOT"), help="Android SDK 目錄")
    parser.add_argument("--java-home", type=Path, default=os.getenv("JAVA_HOME"), help="JDK 17 目錄")
    parser.add_argument("--output", type=Path, help="輸出 APK 路徑")
    parser.add_argument("--variant", choices=("web", "native"), default="web", help="線上版（web）或原生版（native）")
    parser.add_argument("--content-revision", type=int, help="原生版內附的內容版號")
    args = parser.parse_args()
    if args.sdk is None or args.java_home is None:
        parser.error("請指定 --sdk 與 --java-home，或設定 ANDROID_HOME 與 JAVA_HOME。")
    try:
        build(args.sdk.resolve(), args.java_home.resolve(), args.output, args.content_revision, variant=args.variant)
    except (ValueError, OSError, ImportError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"無法完成建置：{error}\n")


if __name__ == "__main__":
    main()
