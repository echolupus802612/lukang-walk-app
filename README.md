# 散步吧 App

出門散步吧：狼耳小嚮導替你挑一個附近的地方、替你指路，到達後才揭曉是哪裡。全台約 5,200 個地點，鹿港老街一帶是人工整理的試辦地區。

iPhone 與 Android 在此私有儲存庫維護，各自使用本庫的程式、景點與素材。Android 內容發布步驟見 [發布說明](RELEASE.md)。

- Android 專用內容站：https://echolupus802612.github.io/lukang-walk-app-content/
- 模擬模式：網址加 `#sim`，按住「▲ 往目的地走」前進

## Android App

Android 1.6 支援 Android 8.0 以上版本。首次開啟時請連上 Wi-Fi，App 會下載 App 專用內容站的全台地點、照片、角色圖、字型與語音。目前完整內容包約 123 MB。下載期間可以選「先連線散步」，也可以等候下載完成。畫面顯示「可離線遊玩」後，即使關閉網路並重新開啟 App，也能實地或模擬散步。地點照片以 240 像素寬儲存在手機。

目前內容共有 4,962 張地點照片。先前 1.5 版在 Android 15 模擬器上的下載結果為 38.8 MB 的內容，包含檔案系統配置空間後，離線資料夾實際占用約 70 MB。不同手機的占用空間可能略有差異。

連網開啟 App 或恢復連線時，App 會檢查已發布的網站版本，只下載有變動的內容。新版本準備完成前會保留上一份可玩的版本。散步途中有更新時，可以收工後再套用，也可以下次開啟時使用新版。

從 Android 1.5 直接覆蓋安裝 1.6 即切換到 App 專用內容站。沿用同一套件識別碼、原簽章與同一網站來源的足跡。舊版 1.5 仍從原網站取得內容。從 1.1 或 1.4 升級會沿用網頁足跡。從 1.2 或 1.3 升級則會在手機上把實走與模擬足跡、最近到訪地點及語音偏好匯入網頁儲存空間。

建置需要 Python、JDK 17、Android SDK Platform 35 與 Build Tools 35.0.0。設定 `JAVA_HOME` 與 `ANDROID_HOME`，再執行 `python -X utf8 -B tools/build_android.py`。安裝檔位於 `android/build/Walk-1.6-web.apk`。APK 內有一份已發布版本的檔案清單。首次安裝若遇到版本查詢服務暫時無法使用，App 可依這份清單連網下載並核對內容。

### 舊版 Android 1.3 離線建置

Android 1.3 支援 Android 8.0 以上版本。APK 內建全台 5,212 個地點及目前收錄的 4,962 張地點照片。照片統一縮為 240 × 150 像素，可在離線時顯示。選點、定位、方向提示、角色動畫與抵達判定都在手機上執行，配音、字型及授權頁也隨 App 提供。從 1.2 覆蓋升級會沿用手機上的足跡與語音設定；從 1.1 升級會匯入舊 App 的紀錄。

第一次按「出門散步吧」時，選擇「使用應用程式時」與「精確位置」即可實地散步。略過定位也能選擇「模擬散步」。之後可在手機的「設定 → 應用程式 → 散步吧 → 權限」調整位置權限。實走與模擬足跡分開保存在這支手機的 App 內，清除 App 資料或解除安裝會清除足跡。

Android 原始碼、兩套版本的建置設定及下載清單皆在本儲存庫。從原始碼建置需要此目錄、JDK 17、Android SDK Platform 35、Build Tools 35.0.0，以及 Python 的字型和影像工具。本版使用 Python 3.11、fontTools 4.59.2、Brotli 1.1.0、Pillow 11.3.0 與其 WebP 1.5.0 編碼器。APK 和後續發布的照片檔使用相同設定（Lanczos 縮圖、WebP 品質 48）。設定 `JAVA_HOME`、`ANDROID_HOME` 後，在專案根目錄執行：

```sh
python -X utf8 -B tools/build_android.py --variant native
```

簽署後的安裝檔位於 `android/build/Walk-1.3-native.apk`。正式建置使用 R8 縮減與混淆程式碼，當機分析所需的對照表放在 `android/build/mappings/`。首次建置會將專用簽署金鑰及密碼存入使用者家目錄的 `.android/lukangwalk-signing/`。請私下備份整個資料夾，後續發行使用同一把金鑰，玩家才能直接更新並保留足跡。

**更新地點、照片及語音**。APK 隨附第 2 版內容。準備發布下一版時，先依現有流程更新素材及授權頁，再執行以下命令產生資料檔。每次發布請提高 `--revision`。

```sh
python -B tools/android_content.py --revision 3 --output android/build/content-site
```

將產生的 `content-site/android-content/` 整個子目錄發布至既有網站的 `/lukang-walk/android-content/`，最後發布該目錄下的 `android-content.json`。這個目錄供 1.3 離線版下載。玩家在首頁按「更新地點資料」即可下載變更的檔案，所有內容通過雜湊校驗後，下次開啟 App 套用。更新時不會傳送足跡或目前位置。

## iPhone App

在 Mac 用裝有 iOS 17 或更新 SDK 的 Xcode 開啟 `ios/LukangWalk.xcodeproj`，選擇 **LukangWalk** 方案和一台 iPhone 模擬器，按 **⌘R**。專案已附字型、地點、照片、語音與授權頁。從原始碼建置 App 可直接使用這些檔案。

工程以 iOS 17.0 為最低部署版本。雲端編譯使用 Xcode 26.3。若 Xcode 16.4 的 iOS 18.5 模擬器啟動時回報 `libswiftWebKit.dylib` 遺失，請選擇更新的模擬器執行環境。[WebKit 問題紀錄](https://bugs.webkit.org/show_bug.cgi?id=293831)

要在自己的 iPhone 上試走，在 target 的 **Signing & Capabilities → Team** 選擇自己的開發團隊，接上手機後按 **⌘R**。預設 Bundle ID 為 `io.github.echolupus802612.lukangwalk`，若簽署時顯示識別碼已被註冊，請改成團隊可用的識別碼。

- **在桌前試玩**。在 **Product → Scheme → Edit Scheme → Run → Arguments** 新增 `-simulate-walk`，用 Debug 組態執行。選「近」並按「出門散步吧」，按住「▲ 往目的地走」直到地點卡出現，按「再走一趟」即可繼續。移除參數後，下一次啟動會使用手機定位。
- **實地試走**。出發時允許「使用 App 期間」與「準確位置」。實走用 iPhone 的定位與指南針，方向不可靠時改顯示絕對方位。到達後或按「收工」會關閉感測器與螢幕常亮。實走與模擬的足跡分開存在 App。
- **鎖定螢幕後接收到站提醒**。iPhone 1.2 在選好實走目的地時會詢問是否允許通知。允許後即可鎖定螢幕或切換 App，抵達時會收到本機通知，點一下可揭曉地點。拒絕通知仍可散步，稍後可到 iPhone 設定開啟通知。實走期間請保留定位權限；若從 App 切換器強制關閉散步吧，這趟定位會結束。通知的提示方式依 iPhone 的通知及專注模式設定而定。
- **散步日誌**。iPhone 1.4 從選定目的地起保存每趟實走或模擬散步。途中按「記一筆」，或事後從首頁的「散步日誌」開啟某一趟，即可寫筆記、拍照或從相簿選照片。日誌可依地名或筆記搜尋、標記收藏，實走到站後可以在地圖上回看該地點。到站卡也可直接拍照並分享小嚮導透卡。
- **從舊版升級**。1.3 已保存的相片足跡會沿用原來的日期、照片與透卡。更早的足跡如果只有到訪地點編號，日誌會列為舊版已到訪地點。舊版沒有逐趟保存的日期及重遊次數無法還原。照片和筆記都保存在這支 iPhone。
- **更新內容**。改動畫面或地點後執行 `python -B tools/build_page.py .`。改動照片、署名或字型授權後，執行 `python -B tools/build_ios_credits.py`。若新增介面用字或地點簡介，可用 `tools/build_fonts.py` 更新離線字型所收錄的字元。

Mac 可在專案根目錄用以下命令檢查模擬器建置。

```sh
xcodebuild -project ios/LukangWalk.xcodeproj -scheme LukangWalk \
  -configuration Debug -destination 'generic/platform=iOS Simulator' build
```

## 結構

| 路徑 | 內容 |
|---|---|
| `src/app.html` | 頁面原始碼（以 `/*DATA*/[]` 預留地點資料的插入位置） |
| `data/lukang.json` | 鹿港一帶 68 個地點（WGS-84，人工整理） |
| `data/taiwan.json` | 全台其他地方的地點（鹿港老街 4.5 公里外），`tools/build_taiwan.py` 產生 |
| `tools/list_taiwan.py` | 全台選點規則：以景點、觀光地點、公園為主，逐筆標出收或不收與理由 → `survey/全台地點列表.csv` |
| `tools/build_taiwan.py` | 依上面的規則取「收」的地點 → `data/taiwan.json`；編號登記在 `data/place_ids_tw.json`（從 1001 起，只增不刪） |
| `data/desc_tw.json` | 全台地點簡介：依文資局、觀光署的來源原文濃縮成 2～3 句（Codex 依 `art/prompts/desc_tw.txt` 撰寫） |
| `tools/build_photos_tw.py` | 全台地點照片：文資局代表圖優先，其次觀光署景點圖，縮成 480×300 WebP → `docs/photos/<id>.webp`；出處記在 `data/photos_tw.json` |
| `survey/` | 全台資料試算報告、地點清單與統計 |
| `tools/build_data.py` | 合併文資局、OSM、維基 → `data/lukang.json`（原始下載不進版控） |
| `data/place_overrides.json` | 人工整理：地點簡介（附出處）、移出的地點；`build_data.py` 重跑時套用。草稿與審閱見 `data/desc_draft.md` |
| `data/place_ids.json` | 鹿港地點永久編號登記（只增不刪）；足跡認這個號碼，重跑資料不會換號 |
| `tools/build_photos.py` | 抓地點照片（人工指定的創用 CC 照片優先，其次文資局代表圖、觀光署景點圖），裁成 16:10 → `docs/photos/<id>.webp`；每張出處記在 `data/photos.json` |
| `tools/build_page.py` | 把資料嵌入頁面 → `docs/index.html`（iPhone 隨附此頁，Android 由專用內容站下載） |
| `art/prompts/` | 角色動作的生圖提示詞（Codex image_gen） |
| `tools/build_sprites.py` | 把 `art/gen/` 的 2×2 動作表切成橫排精靈圖 → `docs/sprites/*.webp`（原圖不進版控） |
| `tools/voice_jobs.py` | 產生配音任務清單 `art/voice/jobs.json`（台詞、表演指令） |
| `tools/voice_gen.py` | 用 BreezeBlue `breeze-tts-2` 合成中文語音 → `docs/voice/*.mp3`（金鑰在本機讀取，不進版控） |

語音共 16 段：15 段固定台詞，加上所有地點共用的到達台詞「到啦～就是這裡！」（`voice/arrived.mp3`）。音色為 BreezeBlue Sparks（`voc_cfnf6vu2sp2p`），`language_code=zh`。音檔載不到時退回系統語音。

角色動作：idle 停著、walk 走動、point 指側邊（朝左時水平翻轉）、pointup 指前方、pull 拉扯（目標在背後）、care 關心（停太久／訊號差）、cheer 歡呼（到達）、bye 不捨（收工）。

```
python -I -B tools/build_page.py .
```

## 資料來源與授權

- 文化部文化資產局 開放資料（古蹟、歷史建築、文化景觀），政府資料開放授權條款
- © OpenStreetMap contributors，ODbL：本 repo 內的派生資料 `data/lukang.json` 同樣以 ODbL 提供
- 維基百科 地理座標查詢（條目名稱與座標）；部分地點簡介依維基條目內容改寫，CC BY-SA 4.0
- 交通部觀光署「景點 - 觀光資訊資料庫」（全台地點、簡介來源）、內政部「全國宗教資訊系統資料-寺廟」，政府資料開放授權條款（鹿港簡介見 `data/place_overrides.json`；全台簡介依文資局與觀光署原文濃縮，見 `data/desc_tw.json`）
- 地點照片（`docs/photos/`）：文化部文化資產局 開放資料代表圖、交通部觀光署 觀光資訊資料庫景點圖片、維基共享資源與 Flickr 的創用 CC 照片（見下表），每張的原始網址見 `data/photos.json`（鹿港）與 `data/photos_tw.json`（全台，縮小後使用，未逐張人工核對）
- 角色（狼耳少年）為作者自有 VTuber 形象，`docs/sprites/` 圖檔保留所有權利，不在上述開放授權內

### 創用 CC 授權照片

以下照片取自 Wikimedia Commons 與 Flickr，經裁切、縮小後使用；改作後的檔案沿用原授權（CC BY-SA 者同樣以 CC BY-SA 提供）。

| 檔案 | 地點 | 原始檔案 | 作者 | 授權 |
|---|---|---|---|---|
| `6.webp` | 真耶穌教會 | Wikimedia Commons：[202607 真耶穌教會鹿港教會 01.jpg](https://commons.wikimedia.org/wiki/File:202607_%E7%9C%9F%E8%80%B6%E7%A9%8C%E6%95%99%E6%9C%83%E9%B9%BF%E6%B8%AF%E6%95%99%E6%9C%83_01.jpg) | Jonashtand | CC BY-SA 4.0 |
| `13.webp` | 鹿港天主教堂 | Flickr：[Flickr 照片](https://www.flickr.com/photos/120532743@N04/14162484637) | 古攝古香 | CC BY 2.0 |
| `18.webp` | 鹿港牛墟頭景靈宮 | Wikimedia Commons：[鹿港景靈宮門殿.jpg](https://commons.wikimedia.org/wiki/File:%E9%B9%BF%E6%B8%AF%E6%99%AF%E9%9D%88%E5%AE%AE%E9%96%80%E6%AE%BF.jpg) | Outlookxp | CC BY-SA 4.0 |
| `20.webp` | 鹿港福靈宮 | Wikimedia Commons：[鹿港福靈宮正面照.jpg](https://commons.wikimedia.org/wiki/File:%E9%B9%BF%E6%B8%AF%E7%A6%8F%E9%9D%88%E5%AE%AE%E6%AD%A3%E9%9D%A2%E7%85%A7.jpg) | Outlookxp | CC BY-SA 4.0 |
| `21.webp` | 后宅闔港潤澤宮李殿王 | Flickr：[Flickr 照片](https://www.flickr.com/photos/120532743@N04/14169722267) | 古攝古香 | CC BY 2.0 |
| `25.webp` | 泊仔寮洽義堂 | Wikimedia Commons：[泊仔寮洽義堂門殿.jpg](https://commons.wikimedia.org/wiki/File:%E6%B3%8A%E4%BB%94%E5%AF%AE%E6%B4%BD%E7%BE%A9%E5%A0%82%E9%96%80%E6%AE%BF.jpg) | Outlookxp | CC BY-SA 4.0 |
| `27.webp` | 施姓宗祠 | Flickr：[Flickr 照片](https://www.flickr.com/photos/120532743@N04/14169584228) | 古攝古香 | CC BY 2.0 |
| `29.webp` | 玉渠宮 | Wikimedia Commons：[鹿港玉渠宮一景.jpg](https://commons.wikimedia.org/wiki/File:%E9%B9%BF%E6%B8%AF%E7%8E%89%E6%B8%A0%E5%AE%AE%E4%B8%80%E6%99%AF.jpg) | Outlookxp | CC BY-SA 4.0 |
| `30.webp` | 鹿港辜宅 | Wikimedia Commons：[鹿港民俗文物館 Lugang Folk Arts Museum - panoramio.jpg](https://commons.wikimedia.org/wiki/File:%E9%B9%BF%E6%B8%AF%E6%B0%91%E4%BF%97%E6%96%87%E7%89%A9%E9%A4%A8_Lugang_Folk_Arts_Museum_-_panoramio.jpg) | lienyuan lee | CC BY 3.0 |
| `35.webp` | 威靈廟(鹿港大將爺) | Wikimedia Commons：[鹿港威靈廟斜照.jpg](https://commons.wikimedia.org/wiki/File:%E9%B9%BF%E6%B8%AF%E5%A8%81%E9%9D%88%E5%BB%9F%E6%96%9C%E7%85%A7.jpg) | Outlookxp | CC BY-SA 4.0 |
| `36.webp` | 鹿港陸濟堂 | Flickr：[Flickr 照片](https://www.flickr.com/photos/120532743@N04/14361224102) | 古攝古香 | CC BY 2.0 |
| `37.webp` | 集英宮 | Wikimedia Commons：[鐵皮屋遮雨棚下的鹿港集英宮.jpg](https://commons.wikimedia.org/wiki/File:%E9%90%B5%E7%9A%AE%E5%B1%8B%E9%81%AE%E9%9B%A8%E6%A3%9A%E4%B8%8B%E7%9A%84%E9%B9%BF%E6%B8%AF%E9%9B%86%E8%8B%B1%E5%AE%AE.jpg) | Outlookxp | CC BY-SA 4.0 |
| `49.webp` | 郭厝保安宮 | Wikimedia Commons：[鹿港郭厝保安宮.jpg](https://commons.wikimedia.org/wiki/File:%E9%B9%BF%E6%B8%AF%E9%83%AD%E5%8E%9D%E4%BF%9D%E5%AE%89%E5%AE%AE.jpg) | Sean Chiu | CC BY-SA 4.0 |
| `51.webp` | 鹿港紫極殿 | Wikimedia Commons：[鹿港紫極殿正面照.jpg](https://commons.wikimedia.org/wiki/File:%E9%B9%BF%E6%B8%AF%E7%B4%AB%E6%A5%B5%E6%AE%BF%E6%AD%A3%E9%9D%A2%E7%85%A7.jpg) | Outlookxp | CC BY-SA 4.0 |
| `55.webp` | 文德宮 | Wikimedia Commons：[鹿港文德宮斜照.jpg](https://commons.wikimedia.org/wiki/File:%E9%B9%BF%E6%B8%AF%E6%96%87%E5%BE%B7%E5%AE%AE%E6%96%9C%E7%85%A7.jpg) | Outlookxp | CC BY-SA 4.0 |
| `57.webp` | 台灣基督長老教會鹿港教會 | Flickr：[Flickr 照片](https://www.flickr.com/photos/120532743@N04/14325847146) | 古攝古香 | CC BY 2.0 |
| `60.webp` | 文開書院 | Wikimedia Commons：[文開書院三川門.jpg](https://commons.wikimedia.org/wiki/File:%E6%96%87%E9%96%8B%E6%9B%B8%E9%99%A2%E4%B8%89%E5%B7%9D%E9%96%80.jpg) | Outlookxp | CC BY-SA 4.0 |
| `65.webp` | 鹿港護安宮 | Wikimedia Commons：[鹿港護安宮正面照.jpg](https://commons.wikimedia.org/wiki/File:%E9%B9%BF%E6%B8%AF%E8%AD%B7%E5%AE%89%E5%AE%AE%E6%AD%A3%E9%9D%A2%E7%85%A7.jpg) | Outlookxp | CC BY-SA 4.0 |
