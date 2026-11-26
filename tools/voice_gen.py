"""Generate and verify the walk prototype's Breeze Blue voice assets."""

import array
import hashlib
import http.client
import json
import msvcrt
import re
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from voice_jobs import voice_jobs


ROOT = Path(__file__).resolve().parents[1]
ART = ROOT / "art/voice"
RAW = ART / "raw"
WEB = ROOT / "docs/voice"
MANIFEST = ART / "manifest.json"
BIN = Path("C:/Program Files/FFMPEG/bin")
VOICE = "voc_cfnf6vu2sp2p"
QUERY = "output_format=mp3_24000_128&delivery=sync"
RATE = 24000
THRESHOLD = 10 ** (-45 / 20)
TRIM = "silenceremove=start_periods=1:start_threshold=-45dB:detection=peak:window=0"


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8-sig"))


def checkpoint(manifest):
    pending = MANIFEST.with_suffix(".tmp")
    pending.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
                       encoding="utf-8")
    pending.replace(MANIFEST)


def request(key, method, path, body=None):
    conn = http.client.HTTPSConnection("api.breeze.blue", timeout=180)
    headers = {"xi-api-key": key}
    payload = None
    if body is not None:
        headers["Content-Type"] = "application/json"
        payload = json.dumps(body, ensure_ascii=False).encode("utf-8")
    try:
        conn.request(method, "/v1/" + path, payload, headers)
        response = conn.getresponse()
        return (response.status, {k.lower(): v for k, v in response.getheaders()},
                response.read())
    finally:
        conn.close()


def ffmpeg(*args, data=None):
    return subprocess.run([BIN / "ffmpeg.exe", "-hide_banner", "-nostdin",
                           "-loglevel", "error", "-xerror", *args],
                          input=data, capture_output=True, check=True).stdout


def inspect(path):
    pcm = ffmpeg("-i", path, "-map", "0:a:0", "-ac", "1", "-ar", str(RATE),
                 "-f", "f32le", "-")
    if not pcm:
        raise ValueError("Empty decoded audio")
    info = json.loads(subprocess.check_output([
        BIN / "ffprobe.exe", "-v", "error", "-select_streams", "a:0",
        "-show_entries", "stream=codec_name,channels,sample_rate,bit_rate",
        "-of", "json", path]))["streams"][0]
    return dict(info, duration_seconds=len(pcm) / (4 * RATE),
                bytes=path.stat().st_size,
                sha256=hashlib.sha256(path.read_bytes()).hexdigest()), pcm


def make_web(path, pcm):
    samples = array.array("f", pcm)
    first = next((i for i, s in enumerate(samples) if abs(s) > THRESHOLD), None)
    if first is None:
        raise ValueError("Entire recording is below -45 dB")
    tail = next(i for i, s in enumerate(reversed(samples)) if abs(s) > THRESHOLD)
    filters = []
    if first > RATE * 0.15:
        filters.append(TRIM)
    if tail > RATE * 0.15:
        filters.extend(["areverse", TRIM, "areverse"])
    stages = ["-af", ",".join(filters)] if filters else []
    pending = path.with_suffix(".part.mp3")
    try:
        ffmpeg("-y", "-f", "f32le", "-ar", str(RATE), "-ac", "1", "-i", "-",
               *stages, "-c:a", "libmp3lame", "-b:a", "48k", "-f", "mp3",
               pending, data=pcm)
        info, decoded = inspect(pending)
        expected = len(samples) - (first if first > RATE * 0.15 else 0)
        expected -= tail if tail > RATE * 0.15 else 0
        if (info["codec_name"], info["channels"], info["sample_rate"], info["bit_rate"]
                ) != ("mp3", 1, "24000", "48000") or abs(len(decoded)//4 - expected) > 2:
            raise ValueError("Web encoding or edge trim verification failed")
        pending.replace(path)
        return info
    finally:
        pending.unlink(missing_ok=True)


def generate(key, row, body, manifest, source):
    row.update(request_body=body, state="submitted", http_status=None)
    checkpoint(manifest)
    status, headers, data = request(key, "POST", f"text-to-speech/{VOICE}?{QUERY}", body)
    row["http_status"] = status
    row["response_metadata"] = {
        k: v for k, v in headers.items()
        if k in {"history-item-id", "request-id", "x-request-id", "x-history-item-id"}
        or (any(word in k for word in ("credit", "character", "usage", "cost", "billed"))
            and re.fullmatch(r"[\d.]+", v))}
    if status != 200 or not headers.get("content-type", "").startswith("audio/"):
        try:
            result = json.loads(data)
        except ValueError:
            result = {}
        safe = {k: str(result[k]).replace(key, "[redacted]")[:300]
                for k in ("code", "detail", "generation_job_id", "history_item_id")
                if k in result}
        row["api_result"] = safe
        raise ValueError(f"HTTP {status} {safe.get('code', 'unexpected response')}")
    pending = source.with_suffix(".part.mp3")
    pending.write_bytes(data)
    pending.replace(source)


def history_usage(key, row):
    history_id = row.get("response_metadata", {}).get("history-item-id")
    if not history_id or not re.fullmatch(r"[A-Za-z0-9_-]+", history_id):
        return None
    try:
        status, _, data = request(key, "GET", "history/" + history_id)
        if status != 200:
            return None
        item = json.loads(data)
        if (item.get("history_item_id"), item.get("voice_id"), item.get("text")) != (
                history_id, row["voice_id"], row["text"]):
            return None
        usage = {k: item.get(k) for k in ("billable_units", "cost_millicredits")}
        return usage if all(type(n) is int for n in usage.values()) else None
    except (ValueError, OSError, http.client.HTTPException):
        return None


def total_usage(key, manifest):
    rows = manifest["jobs"]
    with ThreadPoolExecutor(max_workers=3) as pool:
        for row, usage in zip(rows, pool.map(lambda r: history_usage(key, r), rows)):
            if usage is not None:
                row["usage"] = usage
    verified = [row["usage"] for row in rows if row.get("usage")]
    manifest["usage"] = dict(verified_history_items=len(verified),
                             billable_units=sum(x["billable_units"] for x in verified),
                             cost_millicredits=sum(x["cost_millicredits"] for x in verified))
    checkpoint(manifest)


def read_key():
    keys = set(re.findall(r"\bbrz_[A-Za-z0-9_-]+", Path(
        "C:/Users/leo80/Desktop/API.txt").read_text(encoding="utf-8-sig")))
    if len(keys) != 1:
        raise ValueError("Expected one Breeze Blue credential")
    return keys.pop()


def validate_jobs(jobs):
    names = [job["file"] for job in jobs]
    expected = {job["file"] for job in voice_jobs()}
    if len(names) != len(expected) or set(names) != expected:
        raise ValueError("配音清單有缺漏、重複或非預期的檔名。")


def run():
    jobs = read_json(ART / "jobs.json")
    validate_jobs(jobs)
    key = read_key()
    status, _, data = request(key, "GET", f"voices/{VOICE}")
    if status != 200:
        raise ValueError(f"Voice lookup HTTP {status}")
    voice = json.loads(data)
    if voice.get("voice_id") != VOICE:
        raise ValueError("Voice lookup ID mismatch")
    previous = read_json(MANIFEST) if MANIFEST.exists() else {}
    by_name = {r["file"]: r for r in previous.get("jobs", [])}
    manifest = {"voice_id": VOICE, "voice_name": voice["name"], "voice_lookup_http": status,
                "request_query": QUERY, "jobs": []}
    for job in jobs:
        row = by_name.get(job["file"], dict(file=job["file"], text=job["text"],
                          voice_id=VOICE, request_body=None, http_status=None,
                          raw=None, web=None, success=False, state="pending"))
        manifest["jobs"].append(row)
    RAW.mkdir(exist_ok=True)
    WEB.mkdir(parents=True, exist_ok=True)
    checkpoint(manifest)
    for i, (job, row) in enumerate(zip(jobs, manifest["jobs"]), 1):
        name = job["file"]
        source = RAW / name
        body = dict(text=job["text"], instructions=job["instructions"],
                    model_id="breeze-tts-2", language_code="zh",
                    voice_settings={"guidance_scale": 2.0})
        try:
            if row["request_body"] is not None and row["request_body"] != body:
                raise ValueError("Existing request differs from job")
            audio = None
            if source.exists():
                try:
                    audio = inspect(source)
                except (subprocess.CalledProcessError, ValueError):
                    pass
            if audio is None:
                if row["request_body"] is not None:
                    raise ValueError(row.get("error") or "Previously submitted without usable raw audio")
                generate(key, row, body, manifest, source)
                audio = inspect(source)
            row["raw"], pcm = audio
            row["web"] = make_web(WEB / name, pcm)
            row.update(success=True, state="complete")
            row.pop("error", None)
        except (ValueError, OSError, subprocess.CalledProcessError, http.client.HTTPException) as exc:
            reason = str(exc) if isinstance(exc, ValueError) else type(exc).__name__
            row.update(success=False, state="failed", error=reason.replace(key, "[redacted]"))
        checkpoint(manifest)
        print(i, name, row["state"], row.get("error", ""), flush=True)
        if row["http_status"] in (401, 402, 403, 404):
            break
    total_usage(key, manifest)


if __name__ == "__main__":
    # Windows releases the byte-range lock when the process exits, including on a crash.
    with open(ART / "jobs.json", "rb") as lock:
        lock.seek(1 << 30)
        msvcrt.locking(lock.fileno(), msvcrt.LK_NBLCK, 1)
        try:
            run()
        finally:
            lock.seek(1 << 30)
            msvcrt.locking(lock.fileno(), msvcrt.LK_UNLCK, 1)
