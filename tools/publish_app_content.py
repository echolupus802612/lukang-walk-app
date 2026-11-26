"""準備 App 專用的公開成品，並依成品版本產生 Android 首次下載清單。"""
import argparse
import hashlib
from pathlib import Path
import re
import stat
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
REPO = "echolupus802612/lukang-walk-app-content"
ORIGINS = {f"https://github.com/{REPO}", f"git@github.com:{REPO}", f"ssh://git@github.com/{REPO}"}
ATTRIBUTES = b"/.gitattributes text eol=lf\n/docs/** -text -filter -ident -working-tree-encoding\n"
ASSET = re.compile(r"(?:photos/[0-9]+\.webp|sprites/[a-z][a-z0-9_-]*\.webp|voice/[a-z][a-z0-9_-]*\.mp3|fonts/walk-(?:kai|sans)(?:-bold)?\.woff2)")
REQUIRED = {"index.html", "credits.html", "fonts/Noto-OFL.txt", "fonts/WenKai-OFL.txt"}
FONTS = {f"fonts/walk-{family}{weight}.woff2" for family in ("kai", "sans") for weight in ("", "-bold")}
DEFAULT_SEED = ROOT / "android/web-assets/offline-seed.tsv"


def allowed(name):
    return name in REQUIRED or (len(name) <= 512 and ASSET.fullmatch(name) is not None)


def git(repo, *args, check=True):
    return subprocess.run(["git", "-C", str(repo), *args], stdout=subprocess.PIPE, check=check)


def checkout(path):
    repo = path.resolve(strict=True)
    if repo == ROOT or ROOT in repo.parents or repo in ROOT.parents:
        raise ValueError("請指定 App 專案以外的獨立成品版本庫。")
    actual = Path(git(repo, "rev-parse", "--show-toplevel").stdout.decode().strip()).resolve()
    if actual != repo or git(repo, "symbolic-ref", "--short", "HEAD").stdout.strip() != b"main":
        raise ValueError("請指定成品版本庫的根目錄，並切換至 main 分支。")
    for direction in ([], ["--push"]):
        urls = git(repo, "remote", "get-url", *direction, "--all", "origin").stdout.decode().splitlines()
        if not urls or any(url.removesuffix(".git") not in ORIGINS for url in urls):
            raise ValueError("origin 必須指向指定的公開成品版本庫。")
    for item in repo.iterdir():
        if item.name not in {".git", ".gitattributes", "docs"}:
            raise ValueError(f"成品目錄含有額外項目：{item.name}")
        if item.name != ".git":
            reject_link(item)
    names = git(repo, "ls-files", "-z").stdout
    if git(repo, "rev-parse", "--verify", "--quiet", "HEAD", check=False).returncode == 0:
        history = git(repo, "log", "--format=", "--name-only", "--no-renames", "-z", "HEAD").stdout
        names += history
    for raw in filter(None, names.split(b"\0")):
        name = raw.decode()
        if name != ".gitattributes" and not (name.startswith("docs/") and allowed(name[5:])):
            raise ValueError(f"成品的暫存區或版本紀錄含有額外路徑：{name}")
    return repo


def reject_link(path):
    info = path.lstat()
    if stat.S_ISLNK(info.st_mode) or getattr(info, "st_file_attributes", 0) & stat.FILE_ATTRIBUTE_REPARSE_POINT:
        raise ValueError(f"成品不能使用連結：{path}")


def inventory(folder):
    result = {}
    if folder.exists():
        reject_link(folder)
        for path in folder.rglob("*"):
            reject_link(path)
            name = path.relative_to(folder).as_posix()
            if path.is_dir() and name in {"fonts", "sprites", "photos", "voice"}:
                continue
            if not path.is_file() or not allowed(name):
                raise ValueError(f"成品清單未包含此路徑：{path}")
            size = path.stat().st_size
            if not 0 < size <= 32 << 20:
                raise ValueError(f"檔案大小不符合 Android 離線快取限制：{path}")
            result[name] = path
    return result


def write_file(path, data):
    if path.is_file() and path.read_bytes() == data:
        return False
    path.parent.mkdir(parents=True, exist_ok=True)
    handle = tempfile.NamedTemporaryFile(dir=path.parent, delete=False)
    temporary = Path(handle.name)
    try:
        with handle:
            handle.write(data)
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)
    return True


def prepare(repo, files):
    destination = repo / "docs"
    old = inventory(destination)
    stale = sorted(old.keys() - files.keys())
    tracked = set(git(repo, "ls-files", "-z", "--", "docs").stdout.decode().split("\0"))
    if any(f"docs/{name}" not in tracked for name in stale):
        raise ValueError("目標目錄有未納入版本管理且將被移除的檔案，請先檢查。")
    write_file(repo / ".gitattributes", ATTRIBUTES)
    modified = sum(write_file(destination / name, path.read_bytes()) for name, path in files.items())
    for name in stale:
        old[name].unlink()
    print(f"成品共 {len(files)} 個檔案，寫入 {modified} 個，移除 {len(stale)} 個。")


def seed(repo, files, output):
    if repo in output.resolve().parents or (ROOT / "docs") in output.resolve().parents:
        raise ValueError("下載清單應放在 App 建置資源或暫存目錄。")
    commit = git(repo, "rev-parse", "--verify", "HEAD^{commit}").stdout.decode().strip()
    if not re.fullmatch(r"[a-f0-9]{40}", commit):
        raise ValueError("Android 清單需要 40 碼的 Git 版本。")
    if git(repo, "show", f"{commit}:.gitattributes").stdout != ATTRIBUTES:
        raise ValueError("請先提交成品使用的 Git 檔案屬性。")
    tree = git(repo, "ls-tree", "-rlz", commit, "--", "docs").stdout
    entries = {}
    for record in filter(None, tree.split(b"\0")):
        metadata, raw = record.split(b"\t", 1)
        mode, kind, oid, length = metadata.decode().split()
        name = raw.decode().removeprefix("docs/")
        if mode not in {"100644", "100755"} or kind != "blob" or not allowed(name):
            raise ValueError(f"版本庫內的成品格式不符：{name}")
        entries[name] = oid, int(length)
    if files.keys() != entries.keys():
        raise ValueError("App 成品的檔案清單與指定版本不一致，請先準備並提交成品。")
    lines = [commit]
    for name in sorted(entries):
        oid, size = entries[name]
        content = files[name].read_bytes()
        digest = hashlib.sha1(f"blob {len(content)}\0".encode() + content).hexdigest()
        if (digest, len(content)) != (oid, size):
            raise ValueError(f"App 本機檔案與成品版本的位元組不一致：{name}")
        lines.append(f"{oid}\t{size}\t{name}")
    write_file(output, ("\n".join(lines) + "\n").encode())
    print(f"版本 {commit}，共 {len(entries)} 個檔案。下載清單：{output}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("prepare", help="同步成品到獨立的本機版本庫").add_argument("checkout", type=Path)
    make_seed = commands.add_parser("seed", help="用已提交的成品產生 Android 下載清單")
    make_seed.add_argument("checkout", type=Path)
    make_seed.add_argument("--output", type=Path, default=DEFAULT_SEED)
    args = parser.parse_args()
    try:
        repo = checkout(args.checkout)
        files = inventory(ROOT / "docs")
        if not (REQUIRED | FONTS).issubset(files) or any(not any(n.startswith(f"{directory}/") for n in files)
                                                         for directory in ("photos", "sprites", "voice")):
            raise ValueError("App 成品缺少首頁、授權頁、字型授權或必要素材。")
        if sum(p.stat().st_size for p in files.values()) > 512 << 20:
            raise ValueError("成品總大小超出 Android 離線封存檔限制。")
        if args.command == "prepare":
            prepare(repo, files)
        else:
            seed(repo, files, args.output)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"{error}\n")


if __name__ == "__main__":
    main()
