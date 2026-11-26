"""產生配音任務清單 art/voice/jobs.json（台詞、表演指令、輸出檔名）。頁面的 LINES 也以此為準，兩邊要一起改。

用法：python -I -B tools/voice_jobs.py <專案根目錄>
到達一律說同一句「到啦～就是這裡！」（voice/arrived.mp3），地名只顯示在地點卡上，全台地點都通用。
"""
import json, sys
from pathlib import Path

ROLE = "你是一個活潑、有點黏人又很貼心的狼耳少年嚮導，正陪著對方出門散步，像熟朋友在身邊說話，自然口語，不要像在朗讀。"
LINES = {
    "greet":  (["走吧，出門散步吧！跟著我。", "今天想去哪走走？跟我來。"], "語氣雀躍、帶著期待，像拉著朋友出門。"),
    "far":    (["還有一段路，慢慢來。", "不急，我們慢慢走。"], "輕鬆、陪伴感，語速稍慢。"),
    "half":   (["走一半了。", "過半了，你走得不錯。"], "輕快地鼓勵對方，帶一點笑意。"),
    "near":   (["快到了，抬頭看看。", "就在這附近了。"], "興奮但壓低聲音，有點神秘，像要揭曉驚喜。"),
    "behind": (["在你後面啦，轉個身。", "方向反了，往回一點。"], "有點著急、帶點撒嬌地嘟嘴，像拉著對方的袖子往回拖。"),
    "idle":   (["停下來了？歇一下也好。", "我在這，等你。"], "溫柔、關心，聲音放軟。"),
    "weak":   (["訊號不太好，先站一下。"], "關心、輕聲提醒，不慌張。"),
    "bye":    (["今天就走到這吧。", "下次再一起出門散步吧。"], "依依不捨，聲音軟、語速慢，句尾輕輕收住。"),
}
ARRIVED = ("到啦～就是這裡！", "非常開心地歡呼，像跳起來宣布答案。")


def voice_jobs():
    jobs = []
    for ev, (texts, mood) in LINES.items():
        for i, t in enumerate(texts):
            jobs.append({"file": f"{ev}_{i}.mp3", "event": ev, "text": t, "instructions": ROLE + mood})
    jobs.append({"file": "arrived.mp3", "event": "arrived", "text": ARRIVED[0], "instructions": ROLE + ARRIVED[1]})
    return jobs


def main(root):
    jobs = voice_jobs()
    out = root / "art" / "voice" / "jobs.json"
    out.write_text(json.dumps(jobs, ensure_ascii=False, indent=1), encoding="utf-8")
    print(len(jobs), "句 →", out)


if __name__ == "__main__":
    main(Path(sys.argv[1]))
