# 發布散步吧 App 內容

Android 線上版向 App 專用網站取得畫面和素材。公開成品版本庫為 [lukang-walk-app-content](https://github.com/echolupus802612/lukang-walk-app-content)，GitHub Pages 從 `main` 分支的 `/docs` 發布。App 原始碼與 Android 內附下載清單留在本專案。

Android 1.9.1 從同一個成品庫的 `android-1.9` 分支取得提交，再依該提交驗證畫面及素材。Android 1.6 繼續讀取原本的 Pages 網站。兩者在手機上沿用相同的網頁來源，以便升級時接回足跡。

更新 1.9 系列時，使用 `android-1.9` 分支的獨立工作目錄。以下命令中的 `$mobile` 為該目錄。先提交成品並產生清單，推送後再建置 APK。

```powershell
python -B tools/publish_app_content.py --branch android-1.9 prepare "$mobile"
git -C "$mobile" add -- .gitattributes docs
git -C "$mobile" diff --cached --stat
git -C "$mobile" commit -m "更新 Android 1.9 散步內容"
python -B tools/publish_app_content.py --branch android-1.9 seed "$mobile"
git -C "$mobile" push origin android-1.9
```

## 第一次發布

以下指令在 App 專案根目錄執行。本機已備妥下方的成品工作目錄，往後發布從「準備與發布」開始，沿用同一個 `$content` 路徑。在新電腦上可複製既有成品版本庫；建立全新空庫時才需要初始化。

```powershell
$content = Join-Path (Split-Path -Parent $PWD.Path) 'outputs/散步吧-Android發布'
git init -b main "$content"
git -C "$content" remote add origin https://github.com/echolupus802612/lukang-walk-app-content.git
```

已有公開版本時，可用 `git clone --branch main https://github.com/echolupus802612/lukang-walk-app-content.git "$content"` 建立新的工作副本。先設定同一個 `$content` 路徑。

## Android 1.6 的準備與發布

以下流程適用於 1.6 的原始碼工作目錄。若在新版工作目錄核對舊分支清單，請用 `--output` 指定暫存路徑；新版 APK 的預設清單對應 `android-1.9`。

1. 重建 App 首頁及授權頁，執行繁體中文檢查。

   ```powershell
   python -B tools/build_page.py .
   python -B tools/build_ios_credits.py
   python -B tools/check_zh_tw.py
   ```

2. 第二次起先在乾淨的成品工作目錄執行 `git -C "$content" pull --ff-only origin main`。同步最新成品，檢查變更。

   ```powershell
   python -B tools/publish_app_content.py prepare "$content"
   git -C "$content" add -A -- .gitattributes docs
   git -C "$content" diff --cached --stat
   ```

   `docs/` 收錄首頁、授權頁、景點與角色 WebP 圖片、MP3 語音、四款 WOFF2 字型，以及兩份字型授權。工具會同步移除已退出成品的檔案。版本庫根目錄的 `.gitattributes` 保留成品原始位元組。Android 會依 Git 雜湊逐檔驗證，換行也會影響結果。

3. 有變更時提交成品。產生 Android 下載清單，成功後推送這個成品分支。任何指令失敗時，先處理錯誤再繼續。成品內容相同時可直接使用原提交產生清單。

   ```powershell
   git -C "$content" commit -m "更新散步吧 App 內容"
   python -B tools/publish_app_content.py seed "$content"
   git -C "$content" push -u origin main
   ```

4. 首次推送後，在成品版本庫的 Settings → Pages 選擇 Deploy from a branch、`main` 和 `/docs`。確認對應提交的 Pages 部署成功，[App 首頁](https://echolupus802612.github.io/lukang-walk-app-content/)與[資料來源與授權](https://echolupus802612.github.io/lukang-walk-app-content/credits.html)均可開啟，再建置給首次安裝者使用的新 APK。既有 Android 線上版使用所指定的成品網站檢查內容更新。

`seed` 會核對 App 目錄的成品與已提交的 Git 物件。清單位於 `android/web-assets/offline-seed.tsv`，第一行是成品提交的完整 Git 版本，後續各行依序為檔案的 Git blob SHA-1、位元組數和相對於 `docs/` 的路徑，以定位字元分隔。只做查核時可加上 `--output` 指定暫存檔。
