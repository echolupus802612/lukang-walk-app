"""在桌面 WebKit 用模擬的 iOS 訊息測試實際打包頁面。

測試依賴：pip install playwright==1.49.1，接著執行 playwright install webkit。
用法：python tools/test_ios_bridge.py
"""
import base64
import json
import unittest
from datetime import datetime, timezone
from math import degrees
from pathlib import Path
from uuid import UUID

from playwright.sync_api import sync_playwright


ROOT = Path(__file__).resolve().parents[1]
ENTRY = (ROOT / "docs/index.html").as_uri()
# 固定選點亂數為零。從資料第一處以北約 220 公尺選「近」，必定選到該處（鹿港資料排在全台資料前面）。
PLACE = json.loads((ROOT / "data/lukang.json").read_text(encoding="utf-8"))[0]
ORIGIN = (PLACE["lat"] + 0.002, PLACE["lng"])
DESTINATION = (PLACE["lat"], PLACE["lng"])
TAIWAN = json.loads((ROOT / "data/taiwan.json").read_text(encoding="utf-8"))
NANTOU = next(p for p in TAIWAN if p["id"] == 1001)
# 由資料最北點沿經線繼續往北，最近距離可獨立算出，不依賴選點程式。
NORTHERNMOST = max(TAIWAN, key=lambda p: p["lat"])


def north_of_edge(meters):
    return (NORTHERNMOST["lat"] + degrees(meters / 6_371_000), NORTHERNMOST["lng"])

BRIDGE = """
    window.nativeMessages = [];
    window.webkit = {messageHandlers: {lukangWalk: {
        postMessage(message) { window.nativeMessages.push(structuredClone(message)); }
    }}};
    window.lukangInitialStore = {ver: 2, voice: false, drawn: 4, sim_drawn: 7};
    Math.random = () => 0;
"""


class WalkBridgeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.playwright = sync_playwright().start()
        cls.addClassCleanup(cls.playwright.stop)
        cls.browser = cls.playwright.webkit.launch()
        cls.addClassCleanup(cls.browser.close)

    def setUp(self):
        self.page = self.browser.new_page(viewport={"width": 390, "height": 844})
        self.addCleanup(self.page.context.close)
        self.errors = []
        self.page.on("pageerror", lambda error: self.errors.append(str(error)))
        self.page.add_init_script(BRIDGE)
        self.page.clock.install(time=datetime(2026, 1, 1, tzinfo=timezone.utc))
        self.page.clock.pause_at(datetime(2026, 1, 1, 0, 1, tzinfo=timezone.utc))
        self.page.goto(ENTRY, wait_until="domcontentloaded")

    def tearDown(self):
        self.assertEqual(self.errors, [])

    def click(self, selector):
        button = self.page.locator(selector)
        self.assertTrue(button.is_visible() and button.is_enabled(), selector)
        button.click(force=True)

    def label(self, selector):
        return self.page.locator(selector).inner_text()

    def messages(self, action):
        return self.page.evaluate(
            "action => window.nativeMessages.filter(m => m.action === action)", action
        )

    def writes(self):
        return [m["values"] for m in self.messages("store")]

    def start(self):
        self.click('#bands [data-b="0"]')
        self.click("#go")
        return self.messages("start")[-1]["session"]

    def send(self, event, session, **fields):
        detail = dict(type=event, session=session, **fields)
        self.page.evaluate(
            "detail => dispatchEvent(new CustomEvent('lukangNative', {detail}))", detail
        )

    def fix(self, session, point, age=0, accuracy=5):
        timestamp = self.page.evaluate("Date.now()") - age
        self.send("position", session, timestamp=timestamp, coords={
            "latitude": point[0], "longitude": point[1], "accuracy": accuracy, "speed": 0
        })

    def assert_simulated(self, session, reason):
        self.assertEqual(self.label("#mode"), "模擬行走")
        self.assertIn(reason, self.label("#foot"))
        self.assertTrue(self.page.locator("#stepTo").is_visible())
        self.assertIn({"sim_drawn": 8}, self.writes())
        self.assertEqual(self.messages("stop"), [{"action": "stop", "session": session}])
        self.assertNotIn(PLACE["name"], self.label("body"))

    def enable_background_walk(self):
        self.page.add_init_script("window.lukangBackgroundWalk = true;")
        self.page.reload(wait_until="domcontentloaded")
        self.assertEqual(self.messages("ready"), [{"action": "ready"}])

    def enable_walk_photos(self):
        sprites = {}
        for name in ("cheer", "idle"):
            image = (ROOT / f"docs/sprites/{name}.webp").read_bytes()
            sprites[name] = "data:image/webp;base64," + base64.b64encode(image).decode("ascii")
        self.page.add_init_script("window.lukangWalkPhotos=true; window.lukangCardSprites=" + json.dumps(sprites))
        self.enable_background_walk()

    def enable_journal(self):
        self.page.add_init_script("window.lukangWalkJournal=true;")
        self.enable_walk_photos()

    def test_real_journal_reuses_trip_on_redraw_and_finishes_on_stop(self):
        self.enable_journal()
        self.assertEqual(self.label("#photoAlbum"), "散步日誌")
        self.click("#photoAlbum")
        self.assertEqual(self.messages("journal"), [{"action": "journal"}])
        self.assertFalse(self.page.locator("#journalNote").is_visible())
        places = self.page.evaluate("ids=>lukangJournalPlaces(ids)", [PLACE["id"], PLACE["id"], -1, 9999999])
        self.assertEqual(places, [{"placeID": PLACE["id"], "name": PLACE["name"],
                                   "latitude": PLACE["lat"], "longitude": PLACE["lng"]}])
        session = self.start()
        self.assertEqual(self.messages("target"), [])
        self.fix(session, ORIGIN, age=900)
        first = self.messages("target")[0]
        trip = first["id"]
        self.assertEqual(UUID(trip).version, 4)
        self.assertEqual((first["name"], first["placeID"], first["isSimulated"]), (PLACE["name"], PLACE["id"], False))
        self.assertEqual(self.messages("journalBegin"), [])
        self.assertNotIn(first["name"], self.label("body"))
        self.click("#journalNote")
        self.assertEqual(self.messages("journal")[-1], {"action":"journal", "id":trip})
        self.fix(session, (ORIGIN[0]+0.0001, ORIGIN[1]), age=700)
        self.click("#redraw")
        second = self.messages("target")[-1]
        self.assertEqual(second["id"], trip)
        self.assertNotEqual(second["placeID"], first["placeID"])
        self.fix(session, (ORIGIN[0]+0.0002, ORIGIN[1]), age=400)
        self.click("#stop")
        finished, = self.messages("journalFinish")
        self.assertEqual((finished["id"],finished["status"],finished["stop"]), (trip,"stopped",None))
        self.assertGreater(finished["walked"], 20)
        session = self.start()
        self.fix(session, ORIGIN, age=900)
        target = self.messages("target")[-1]
        self.assertNotEqual(target["id"], trip)
        self.page.evaluate("""() => {
            Object.defineProperty(document,'hidden',{configurable:true,value:true});
            document.dispatchEvent(new Event('visibilitychange'));
            delete document.hidden;
            document.dispatchEvent(new Event('visibilitychange'));
        }""")
        self.fix(session, (target["latitude"],target["longitude"]))
        self.send("arrival", session, token=target["id"], placeID=target["placeID"],
                  seen=[target["placeID"]], recent=[target["placeID"]])
        self.page.clock.fast_forward(1800)
        self.click("#snap")
        self.assertIsNone(self.messages("walkPhoto")[-1]["visit"]["walked"])

    def test_journal_omits_partial_distance_on_native_background_receipt(self):
        self.enable_journal()
        for interrupted in (False, True):
            session = self.start()
            self.fix(session, ORIGIN, age=1500)
            target = self.messages("target")[-1]
            for i in range(1, 5):
                progress = i / 4
                self.fix(session, (ORIGIN[0] + (target["latitude"] - ORIGIN[0]) * progress,
                                   ORIGIN[1] + (target["longitude"] - ORIGIN[1]) * progress), age=1500-i*300)
            self.send("arrival", session, token=target["id"], placeID=target["placeID"],
                      seen=[target["placeID"]], recent=[target["placeID"]], distanceIncomplete=interrupted)
            self.page.clock.fast_forward(1800)
            self.click("#snap")
            walked = self.messages("walkPhoto")[-1]["visit"]["walked"]
            if interrupted:
                self.assertIsNone(walked)
            else:
                self.assertGreater(walked, 150)
            self.click("#again")

    def test_journal_denied_real_walk_starts_a_separate_simulated_visit(self):
        self.enable_journal()
        session = self.start()
        self.fix(session, ORIGIN, age=800)
        real = self.messages("target")[0]["id"]
        self.send("error", session, reason="denied")
        simulation = self.messages("journalBegin")[0]
        self.assertNotEqual(real, simulation["id"])
        self.assertTrue(simulation["isSimulated"])
        self.assertEqual(self.messages("journalFinish")[0]["status"], "interrupted")
        self.assertEqual(self.messages("journalFinish")[0]["id"], real)
        self.click("#redraw")
        self.assertEqual(self.messages("journalBegin")[-1]["id"], simulation["id"])
        self.page.locator("#stepTo").dispatch_event("pointerdown")
        for _ in range(500):
            self.page.clock.fast_forward(100)
            if self.page.locator("#walkrow").is_hidden():
                break
        self.page.locator("#stepTo").dispatch_event("pointerup")
        self.page.clock.fast_forward(1800)
        arrived = self.messages("journalFinish")[-1]
        self.assertEqual((arrived["id"],arrived["status"],arrived["stop"]), (simulation["id"],"arrived",1))
        self.click("#visitNote")
        self.assertEqual(self.messages("journal")[-1]["id"], simulation["id"])
        self.click("#snap")
        self.assertEqual(self.messages("walkPhoto")[-1]["visit"]["id"], simulation["id"])
        self.click("#again")
        self.click("#go")
        self.assertNotEqual(self.messages("journalBegin")[-1]["id"], simulation["id"])

    def test_journal_waits_for_selection_and_resumes_native_trip_id(self):
        self.enable_journal()
        session = self.start()
        self.fix(session, north_of_edge(4999))
        self.assertEqual(self.label("#go"), "那就走遠一點")
        for action in ("target","journalBegin","journalFinish"):
            self.assertEqual(self.messages(action), [])
        self.page.reload(wait_until="domcontentloaded")
        trip = "2731b579-0eb9-4fba-a962-f95bd18c3926"
        self.send("resumeWalk", 41, placeID=PLACE["id"], id=trip)
        self.click("#journalNote")
        self.assertEqual(self.messages("journal"), [{"action":"journal","id":trip}])
        self.fix(41, ORIGIN)
        self.click("#redraw")
        target = self.messages("target")[-1]
        self.assertEqual(target["id"], trip)
        self.send("arrival", 41, token=trip, placeID=target["placeID"], seen=[target["placeID"]], recent=[target["placeID"]])
        self.page.clock.fast_forward(1800)
        self.assertEqual(self.messages("journalFinish"), [])
        self.assertFalse(self.page.locator("#journalNote").is_visible())
        self.click("#visitNote")
        self.assertEqual(self.messages("journal")[-1]["id"], trip)
        self.click("#snap")
        self.assertIsNone(self.messages("walkPhoto")[-1]["visit"]["walked"])

    def test_historical_journal_cards_hide_unrevealed_places_and_unknown_fields(self):
        self.enable_journal()
        results = self.page.evaluate("""async ()=>{
          const photo=document.createElement('canvas').toDataURL('image/jpeg').split(',')[1];
          const original=CanvasRenderingContext2D.prototype.fillText;
          let labels;
          CanvasRenderingContext2D.prototype.fillText=function(text,...args){
            labels.push(text); return original.call(this,text,...args);
          };
          try {
            const result={};
            for (const status of ['walking','stopped','interrupted','arrived','legacy']){
              labels=[];
              const trip={id:'saved',status,name:'保密地名',area:'保密地區',date:'2025.12.31',stop:3,walked:125};
              if (status==='legacy') Object.assign(trip,{area:null,date:null,stop:null,walked:null});
              const png=await lukangRenderJournalCard(photo,trip);
              result[status]={header:png.slice(0,8),labels};
            }
            return result;
          } finally {CanvasRenderingContext2D.prototype.fillText=original}
        }""")
        for record in results.values():
            self.assertEqual(record["header"], "iVBORw0K")
        for status in ("walking","stopped","interrupted"):
            text = " ".join(results[status]["labels"])
            self.assertNotIn("保密", text)
            self.assertNotIn("第 3 站", text)
        self.assertIn("保密地名・第 3 站", results["arrived"]["labels"])
        self.assertIn("保密地區　2025.12.31", results["arrived"]["labels"])
        legacy = " ".join(results["legacy"]["labels"])
        self.assertIn("保密地名", legacy)
        for missing in ("保密地區","走了","第 ","2025","null","undefined"):
            self.assertNotIn(missing, legacy)

    def test_native_photo_album_and_real_visit_render_offline(self):
        self.enable_walk_photos()
        self.click("#photoAlbum")
        self.assertEqual(self.messages("photoAlbum"), [{"action": "photoAlbum"}])
        visit_id = "79d4648a-3695-450d-a0e0-6c56fb73720f"
        event = dict(placeID=NANTOU["id"], date="2025.12.31", token=visit_id,
                     seen=[NANTOU["id"]], recent=[NANTOU["id"]])
        self.send("arrival", 18, **event)
        self.assertTrue(self.page.evaluate("id=>lukangRenderWalkCard('',id).then(()=>false,()=>true)", visit_id))
        self.page.clock.fast_forward(1800)
        self.click("#snap")
        self.send("arrival", 18, **event)
        self.click("#snap")
        expected = {"action": "walkPhoto", "visit": {"id": visit_id, "placeID": NANTOU["id"],
                    "name": NANTOU["name"], "date": "2025.12.31", "isSimulated": False, "stop": 1,
                    "walked": None, "area": f"{NANTOU['town']}・{NANTOU['city']}"}}
        self.assertEqual(self.messages("walkPhoto"), [expected, expected])
        self.assertFalse(self.page.locator("#photoAlbum").is_visible())
        self.assertTrue(self.page.evaluate("()=>lukangRenderWalkCard('','other').then(()=>false,()=>true)"))

        result = self.page.evaluate("""async id=>{
          const source=document.createElement('canvas'), ctx=source.getContext('2d');
          ctx.fillStyle='#13cc18';ctx.fillRect(0,0,source.width,source.height);
          const jpeg=source.toDataURL('image/jpeg').split(',')[1];
          const png=await lukangRenderWalkCard(jpeg,id);
          const image=new Image(); image.src='data:image/png;base64,'+png; await image.decode();
          ctx.drawImage(image,120,520,1,1,0,0,1,1);
          const pixel=Array.from(ctx.getImageData(0,0,1,1).data);
          const previous=lukangRenderWalkCard(jpeg,id);
          document.getElementById('again').click();
          return {header:png.slice(0,8),size:[image.naturalWidth,image.naturalHeight],pixel,
                  staleRejected:await previous.then(()=>false,()=>true)};
        }""", visit_id)
        self.assertEqual(result["size"], [1080, 1621])
        self.assertEqual(result["header"], "iVBORw0K")
        red, green, blue, alpha = result["pixel"]
        self.assertTrue(green > 180 and red < 70 and blue < 70 and alpha == 255, result["pixel"])
        self.assertTrue(result["staleRejected"])
        self.assertTrue(self.page.locator("#photoAlbum").is_visible())

    def test_native_capture_restores_card_only_on_a_freshly_reloaded_page(self):
        self.enable_walk_photos()
        session = self.start()
        self.fix(session, ORIGIN)
        visit_id = "ec373236-b924-42dc-ba97-57faf9a3d3c1"
        self.send("arrival", session, placeID=PLACE["id"], date="2025.12.31", token=visit_id,
                  seen=[PLACE["id"]], recent=[PLACE["id"]])
        self.page.clock.fast_forward(1800)
        self.click("#snap")
        visit = self.messages("walkPhoto")[0]["visit"]
        self.assertGreater(visit["walked"], 200)
        self.assertEqual(visit["area"], "鹿港一帶・彰化縣")
        self.page.reload(wait_until="domcontentloaded")
        result = self.page.evaluate("""async visit=>{
          const photo=document.createElement('canvas').toDataURL('image/jpeg').split(',')[1];
          const render=window.renderShareCard;
          let caption;
          window.renderShareCard=options=>{
            caption=[options.name,options.stop,options.line,options.place,options.date];
            return render(options);
          };
          const rejected=(id,snapshot)=>lukangRenderWalkCard(photo,id,snapshot).then(()=>false,()=>true);
          const mismatched=await rejected('another-visit',visit);
          const incomplete=await rejected(visit.id,{...visit,walked:undefined});
          const badStop=await rejected(visit.id,{...visit,stop:0});
          const png=await lukangRenderWalkCard(photo,visit.id,visit);
          const img=new Image(); img.src='data:image/png;base64,'+png; await img.decode();
          const pending=rejected(visit.id,visit);
          document.getElementById('go').click();
          return {mismatched,incomplete,badStop,interrupted:await pending,
                  header:png.slice(0,8),size:[img.width,img.height],caption};
        }""", visit)
        self.assertTrue(all(result[key] for key in ("mismatched", "incomplete", "badStop", "interrupted")))
        self.assertEqual(result["size"], [1080, 1621])
        self.assertEqual(result["header"], "iVBORw0K")
        self.assertEqual(result["caption"], [PLACE["name"], 1, f"走了 {round(visit['walked'])} 公尺",
                                             visit["area"], "2025.12.31"])
        session = self.messages("start")[-1]["session"]
        self.fix(session, ORIGIN)
        self.click("#stop")
        # 已經走過又回首頁，仍不得沿用捕捉相片時保留的舊資料。
        self.assertTrue(self.page.evaluate("""v=>{
          const photo=document.createElement('canvas').toDataURL('image/jpeg').split(',')[1];
          return lukangRenderWalkCard(photo,v.id,v).then(()=>false,()=>true);
        }""", visit))

    def test_each_simulated_arrival_has_one_new_photo_id(self):
        self.enable_walk_photos()
        session = self.start()
        self.send("error", session, reason="denied")
        step = self.page.locator("#stepTo")
        visits = []
        for _ in range(2):
            self.assertFalse(self.page.locator("#photoAlbum").is_visible())
            step.dispatch_event("pointerdown")
            for _ in range(500):
                self.page.clock.fast_forward(100)
                if self.page.locator("#walkrow").is_hidden():
                    break
            step.dispatch_event("pointerup")
            self.page.clock.fast_forward(1800)
            self.click("#snap")
            self.click("#snap")
            first, second = [m["visit"] for m in self.messages("walkPhoto")[-2:]]
            self.assertEqual(first, second)
            self.assertTrue(first["isSimulated"])
            self.assertEqual(UUID(first["id"]).version, 4)
            visits.append(first["id"])
            self.click("#again")
            if len(visits) == 1:
                self.click("#go")
        self.assertNotEqual(*visits)

    def test_photo_hooks_require_native_and_its_capability(self):
        self.assertFalse(self.page.locator("#photoAlbum").is_visible())
        self.assertEqual(self.page.evaluate("typeof window.lukangRenderWalkCard"), "undefined")
        self.assertEqual(self.page.evaluate("typeof window.lukangRenderJournalCard"), "undefined")
        self.assertEqual(self.page.evaluate("typeof window.lukangJournalPlaces"), "undefined")
        web = self.browser.new_page()
        self.addCleanup(web.context.close)
        web.add_init_script("window.lukangWalkPhotos=true")
        web.goto(ENTRY, wait_until="domcontentloaded")
        self.assertFalse(web.locator("#photoAlbum").is_visible())
        self.assertEqual(web.evaluate("typeof window.lukangRenderWalkCard"), "undefined")
        self.assertFalse(web.locator("#snap").evaluate("button => button.hidden"))

    def test_native_arrival_is_authoritative_even_during_redraw(self):
        self.enable_background_walk()
        session = self.start()
        self.fix(session, ORIGIN, age=1000)
        self.assertEqual(self.messages("target"), [{
            "action": "target", "session": session, "placeID": PLACE["id"],
            "latitude": PLACE["lat"], "longitude": PLACE["lng"],
        }])
        self.fix(session, DESTINATION, age=750)
        self.fix(session, DESTINATION, age=500)
        self.page.clock.fast_forward(2000)
        self.assertFalse(self.page.locator("#veil").is_visible())
        self.send("notificationUnavailable", session)
        self.assertTrue(self.page.locator("#notificationWarning").is_visible())
        self.click("#redraw")
        redrawn = self.messages("target")[-1]
        self.assertEqual(redrawn["session"], session)
        self.assertNotEqual(redrawn["placeID"], PLACE["id"])

        event = dict(placeID=PLACE["id"], token="first", seen=[90, PLACE["id"]], recent=[PLACE["id"], 90])
        self.send("arrival", session, **event)
        self.page.clock.fast_forward(1000)
        self.send("arrival", session, **event)
        self.page.clock.fast_forward(799)
        self.assertEqual(self.messages("arrivalShown"), [])
        self.page.clock.fast_forward(1)
        self.assertEqual(self.label("#cname"), PLACE["name"])
        self.assertEqual(self.label("#cno"), "第 2 站")
        self.assertEqual(self.messages("arrivalShown"), [{"action": "arrivalShown", "token": "first"}])
        self.assertEqual(self.writes(), [{"drawn": 5}, {"drawn": 6}])
        self.assertEqual(self.messages("arrived"), [])
        self.assertEqual(self.messages("stop"), [])
        self.assertFalse(self.page.locator("#notificationWarning").is_visible())
        self.click("#again")
        self.assertIn("到過 2 處", self.label("#sub"))
        next_session = self.start()
        self.fix(next_session, ORIGIN)
        self.send("arrival", session, **event)
        self.page.clock.fast_forward(2000)
        self.assertTrue(self.page.locator("#walkrow").is_visible())
        self.assertFalse(self.page.locator("#veil").is_visible())

    def test_cold_arrival_waits_for_visible_card_and_ignores_stale_resume(self):
        self.enable_background_walk()
        self.page.evaluate("Object.defineProperty(document,'hidden',{configurable:true,value:true})")
        event = dict(placeID=NANTOU["id"], token="restored", seen=[NANTOU["id"]], recent=[NANTOU["id"]])
        self.send("arrival", 73, **event)
        self.page.clock.fast_forward(1800)
        self.assertEqual(self.messages("arrivalShown"), [])
        self.page.evaluate("delete document.hidden; document.dispatchEvent(new Event('visibilitychange'))")
        self.assertTrue(self.page.locator("#veil").is_visible())
        self.assertEqual(self.label("#cname"), NANTOU["name"])
        self.assertEqual(self.label("#cdesc"), NANTOU["desc"])
        self.assertEqual(self.messages("arrivalShown"), [{"action": "arrivalShown", "token": "restored"}])
        self.send("resumeWalk", 73, placeID=NANTOU["id"])
        self.assertTrue(self.page.locator("#veil").is_visible())
        self.assertEqual(self.messages("start"), [])
        self.assertEqual(self.messages("target"), [])
        self.assertEqual(self.writes(), [])
        self.click("#again")
        self.send("arrival", 73, **event)
        self.assertFalse(self.page.locator("#veil").is_visible())
        self.assertGreater(self.start(), 73)

    def test_pending_arrival_from_an_older_session_interrupts_a_new_start(self):
        self.enable_background_walk()
        first = self.start()
        self.fix(first, ORIGIN)
        self.click("#stop")
        second = self.start()
        self.assertGreater(second, first)
        # 手機已入帳，點位可能在 App 更新時移除，仍須顯示並確認這筆足跡。
        self.send("arrival", first, token="pending", placeID=9999999, seen=[9999999], recent=[9999999])
        self.page.clock.fast_forward(15000)
        self.assertTrue(self.page.locator("#veil").is_visible())
        self.assertEqual(self.label("#cname"), "先前造訪的地點")
        self.assertEqual(self.messages("arrivalShown"), [{"action": "arrivalShown", "token": "pending"}])
        self.assertNotIn("sim_drawn", str(self.writes()))

    def test_resume_uses_existing_target_until_player_changes_it(self):
        self.enable_background_walk()
        self.send("resumeWalk", 41, placeID=PLACE["id"])
        self.assertTrue(self.page.locator("#walkrow").is_visible())
        self.assertFalse(self.page.locator("#redraw").is_enabled())
        self.send("heading", 41, degrees=90)
        self.fix(41, ORIGIN)
        self.assertEqual(self.label("#mode"), "GPS 實走")
        self.assertTrue(self.page.locator("#redraw").is_enabled())
        self.assertEqual(self.messages("start"), [])
        self.assertEqual(self.messages("target"), [])
        self.assertEqual(self.writes(), [])
        self.click("#redraw")
        self.assertNotEqual(self.messages("target")[-1]["placeID"], PLACE["id"])
        self.send("resumeWalk", 41, placeID=PLACE["id"])
        self.assertTrue(self.page.locator("#redraw").is_enabled())
        self.assertEqual(self.writes(), [{"drawn": 5}])
        self.click("#stop")
        self.send("resumeWalk", 41, placeID=PLACE["id"])
        self.assertFalse(self.page.locator("#walkrow").is_visible())
        session = self.start()
        self.assertGreater(session, 41)
        self.send("error", session, reason="denied")
        self.send("notificationUnavailable", session)
        self.assertEqual(self.label("#mode"), "模擬行走")
        self.assertFalse(self.page.locator("#notificationWarning").is_visible())
        self.assertEqual(len(self.messages("target")), 1)

    def test_ready_and_credits_do_not_request_sensors(self):
        self.page.clock.fast_forward(15000)
        self.assertEqual(self.messages("start"), [])
        self.assertFalse(self.page.locator("#walkrow").is_visible())
        self.assertIn("出發過 4 次", self.label("#sub"))
        self.click("#credits")
        self.assertEqual(self.messages("credits"), [{"action": "credits"}])
        self.assertEqual(self.page.url, ENTRY)
        self.assertEqual(self.messages("start"), [])

    def test_denied_and_stale_callbacks(self):
        session = self.start()
        self.send("error", session, reason="denied")
        self.assert_simulated(session, "未取得定位權限")
        self.fix(session, DESTINATION)
        self.send("heading", session, degrees=180)
        self.assertEqual(self.label("#mode"), "模擬行走")
        self.assertEqual(self.messages("arrived"), [])

    def test_approximate_location(self):
        session = self.start()
        self.send("error", session, reason="approximate")
        self.assert_simulated(session, "大概位置")

    def test_far_from_any_place(self):
        session = self.start()
        self.fix(session, (ORIGIN[0] + 1, ORIGIN[1]))
        self.assert_simulated(session, "5 公里內還沒有收錄")

    def test_nantou_real_walk_reveals_and_saves_national_place(self):
        session = self.start()
        destination = (NANTOU["lat"], NANTOU["lng"])
        self.fix(session, (NANTOU["lat"] + 0.002, NANTOU["lng"]), age=750)
        self.assertIn({"drawn": 5}, self.writes())
        self.assertEqual(self.label("#mode"), "GPS（無指南針）")
        self.assertFalse(self.page.locator("#stepTo").is_visible())
        self.assertNotIn(NANTOU["name"], self.label("body"))
        self.fix(session, destination, age=500)
        self.assertEqual(self.messages("arrived"), [])
        self.fix(session, destination)
        self.page.clock.fast_forward(1800)
        self.assertEqual(self.label("#cname"), NANTOU["name"])
        self.assertEqual(self.label("#cdesc"), NANTOU["desc"])
        photo = self.page.locator("#cph")
        self.assertTrue(photo.is_visible())
        self.assertEqual(photo.get_attribute("src"), f"photos/{NANTOU['id']}.webp")
        self.assertGreater(photo.evaluate("async image => { await image.decode(); return image.naturalWidth; }"), 0)
        self.assertIn({"seen": [NANTOU["id"]], "recent": [NANTOU["id"]]}, self.writes())
        self.assertFalse(any("sim_drawn" in v or "sim_seen" in v for v in self.writes()))

    def test_just_inside_5km_waits_for_consent_to_walk_farther(self):
        point = north_of_edge(4999)
        session = self.start()
        self.fix(session, point)
        self.assertEqual(self.label("#go"), "那就走遠一點")
        self.assertIn("5.0 公里", self.label("#hint"))
        self.assertEqual(self.writes(), [])
        self.assertEqual(self.messages("stop"), [{"action": "stop", "session": session}])
        self.assertFalse(self.messages("awake")[-1]["enabled"])
        self.assertFalse(self.page.locator("#stepTo").is_visible())
        self.click("#go")
        second = self.messages("start")[-1]["session"]
        self.assertNotEqual(second, session)
        self.fix(second, point)
        self.assertEqual(self.label("#mode"), "GPS（無指南針）")
        self.assertTrue(self.page.locator("#stop").is_visible())
        self.assertIn({"drawn": 5}, self.writes())

    def test_just_outside_5km_falls_back_to_lukang_simulation(self):
        session = self.start()
        self.fix(session, north_of_edge(5001))
        self.assert_simulated(session, "鹿港天后宮前模擬")
        self.assertFalse(any("drawn" in v for v in self.writes()))

    def test_permission_lost_while_walking_draws_in_separate_book(self):
        session = self.start()
        self.fix(session, ORIGIN)
        self.assertIn({"drawn": 5}, self.writes())
        self.send("error", session, reason="denied")
        self.assert_simulated(session, "定位中斷")
        self.assertFalse(any("seen" in v or "sim_seen" in v for v in self.writes()))
        self.click("#stop")
        second = self.start()
        self.fix(second, ORIGIN)
        self.assertIn({"drawn": 6}, self.writes())
        self.assertEqual(self.label("#mode"), "GPS（無指南針）")

    def test_timeout_after_twelve_seconds(self):
        session = self.start()
        self.page.clock.fast_forward(11999)
        self.assertFalse(self.page.locator("#stepTo").is_visible())
        self.assertEqual(self.writes(), [])
        self.page.clock.fast_forward(1)
        self.assert_simulated(session, "拿不到目前位置")

    def test_simulated_hold_and_arrival(self):
        session = self.start()
        self.send("error", session, reason="denied")
        step = self.page.locator("#stepTo")
        self.assertTrue(step.is_visible())
        before = self.label("#dist")
        step.dispatch_event("pointerdown")
        for _ in range(10):
            self.page.clock.fast_forward(100)
        step.dispatch_event("pointerup")
        after = self.label("#dist")
        self.assertNotEqual(before, after)
        self.page.clock.fast_forward(500)
        self.assertEqual(self.label("#dist"), after)

        step.dispatch_event("pointerdown")
        # 「近」至多 500 公尺；逐個計時器區間推進，保留長按的完整事件序列。
        for _ in range(25):
            for _ in range(20):
                self.page.clock.fast_forward(100)
            if self.messages("arrived"):
                break
        step.dispatch_event("pointerup")
        self.page.clock.fast_forward(1800)
        self.assertTrue(self.page.locator('#veil [role="dialog"]').is_visible())
        # 舊版 iPhone 橋接未提供相片功能，地點卡仍隱藏拍照按鈕。
        self.assertFalse(self.page.locator("#snap").is_visible())
        self.assertEqual(len(self.messages("arrived")), 1)
        saved, = [v for v in self.writes() if "sim_seen" in v]
        self.assertEqual(saved["sim_seen"], saved["sim_recent"])
        self.assertEqual(len(saved["sim_seen"]), 1)
        self.assertFalse(any("drawn" in v or "seen" in v for v in self.writes()))
        self.assertFalse(self.messages("awake")[-1]["enabled"])
        self.click("#again")
        self.assertTrue(self.page.locator("#go").is_visible())

    def test_real_arrival_requires_two_distinct_fresh_accurate_fixes(self):
        session = self.start()
        self.fix(session, ORIGIN, age=1000)
        self.assertEqual(self.label("#mode"), "GPS（無指南針）")
        self.assertIn("沒有指南針", self.label("#sub"))
        self.assertNotIn(PLACE["name"], self.label("body"))
        self.assertIn({"drawn": 5}, self.writes())
        self.send("heading", session, degrees=15)
        self.assertEqual(self.label("#mode"), "GPS 實走")
        self.send("heading", session, degrees=None)
        self.assertIn("沒有指南針", self.label("#sub"))
        self.page.clock.fast_forward(4000)  # 過期定位仍比上一筆新，獨立檢查兩秒門檻。
        self.fix(session, DESTINATION, age=3000)
        self.assertIn("沒有指南針", self.label("#sub"))
        self.fix(session, DESTINATION, age=850)
        self.assertIn("確認位置", self.label("#sub"))
        self.fix(session, DESTINATION, age=850)
        self.assertEqual(self.messages("arrived"), [])
        self.fix(session, DESTINATION, age=700, accuracy=65)
        self.assertIn("等定位準一點", self.label("#sub"))
        self.fix(session, DESTINATION, age=600)
        self.assertEqual(self.messages("arrived"), [])
        self.send("pause", session)
        self.fix(session, DESTINATION, age=500)
        self.assertEqual(self.messages("arrived"), [])
        self.fix(session, DESTINATION, age=400)
        self.assertEqual(len(self.messages("arrived")), 1)
        self.assertFalse(self.page.locator("#walkrow").is_visible())
        self.page.clock.fast_forward(1799)
        self.assertFalse(self.page.locator("#veil").is_visible())
        self.page.clock.fast_forward(1)
        self.assertEqual(self.label("#cname"), PLACE["name"])
        self.assertTrue(self.page.locator("#again").is_visible())
        self.assertIn({"seen": [PLACE["id"]], "recent": [PLACE["id"]]}, self.writes())
        self.assertEqual(self.messages("stop"), [{"action": "stop", "session": session}])
        self.assertFalse(self.messages("awake")[-1]["enabled"])
        self.fix(session, DESTINATION)
        self.assertEqual(len(self.messages("arrived")), 1)

        self.click("#again")
        second = self.start()
        self.assertNotEqual(second, session)
        self.send("error", session, reason="denied")
        self.fix(second, ORIGIN)
        self.assertTrue(self.page.locator("#redraw").is_visible())
        self.click("#redraw")
        self.assertIn({"drawn": 7}, self.writes())
        self.click("#voice")
        self.assertIn({"voice": True}, self.writes())
        self.click("#stop")
        self.assertEqual(self.label("#mode"), "已收工")
        self.assertEqual(self.messages("stop")[-1]["session"], second)
        self.assertFalse(self.messages("awake")[-1]["enabled"])
        self.send("error", second, reason="denied")
        self.assertEqual(self.label("#mode"), "已收工")
        self.send("storeError", None)
        self.assertIn("還沒存好", self.label("#storageWarning"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
