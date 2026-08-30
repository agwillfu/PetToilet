# 回覆 Guideline 2.1 — Information Needed（2026-08-29 退件）

Apple 要的七項資料，逐項備妥。**只需在 Resolution Center 回覆，不用重新上傳 build。**

---

## ⚠️ 只有第 1 項需要你動手：螢幕錄影

Apple 的原文要求：

> A screen recording captured on **a physical device**, running the latest operating system,
> demonstrating the app's functionality. The recording **must begin with launching the app**
> and show the typical user flow through its core features.

他們列的四種必拍情境（帳號註冊/登入/刪除、付費內容、使用者生成內容、權限請求提示）
**你的 App 一項都沒有**，所以不用額外處理。

### 建議腳本（1.5～2 分鐘，一鏡到底不剪接）

| 秒數 | 畫面 |
|---|---|
| 0:00 | **從主畫面點開 App**（一定要拍到啟動這一刻，這是明文要求） |
| 0:05 | 狀態卡片顯示「等待中」與連線狀態 |
| 0:15 | 按「立即沖水」→ **鏡頭帶到實體尿盆，拍到水泵真的在運轉** |
| 0:35 | 回到 App，狀態變成「沖水中」→「靜置中」→「等待中」，上次沖水時間更新 |
| 0:50 | 往下捲，拖動三個參數滑桿 |
| 1:05 | 定時清洗：開關、時間長度、新增/修改一個時間點 |
| 1:20 | 活動紀錄：顯示歷史事件與觸發來源 |
| 1:30 | 右上角扳手 → 裝置診斷；左上角齒輪 → 設定畫面與隱私權政策連結 |

**錄製方式**：iPhone 內建螢幕錄影（設定 → 控制中心 → 加入「螢幕錄製」）。
拍實體硬體的段落可以用另一支手機或請人幫忙拍，或把 iPhone 架著、手動操作尿盆。

**⚠️ 一定要用實體 iPhone，不能用模擬器。** Apple 對此有明確立場。

### 上傳影片

放到 `docs/demo.mp4` 推上 GitHub，取得直連：

```
https://agwillfu.github.io/PetToilet/demo.mp4
```

Apple 明確偏好**直接的檔案連結**，不要用 YouTube / Google Drive / Dropbox 的分享連結（廣泛回報會失敗）。

⚠️ GitHub 單檔上限 100MB。錄完先看大小，太大的話用這行壓縮：

```bash
ffmpeg -i demo.mov -vf "scale=-2:1280" -c:v libx264 -crf 28 -preset slow -an docs/demo.mp4
```

（`-an` 去掉音訊，審查不需要聲音。）

---

## 第 2～7 項：直接複製下面整段貼進 Resolution Center

> ⚠️ 貼之前把 `[要填]` 換成你實際測試的機型與 iOS 版本。

```
Thank you for the review. Please find the requested information below.

1. SCREEN RECORDING
A screen recording captured on a physical iPhone running the latest iOS is
available here:
https://agwillfu.github.io/PetToilet/demo.mp4

The recording begins with launching the app from the Home Screen and shows
the complete user flow: live device status, manual flush (including the
physical hardware responding), the three behaviour threshold sliders,
scheduled cleaning setup, the activity log, and device diagnostics.

The app has no account registration, login, or deletion flows; no paid
content, purchases, or subscriptions; no user-generated content; and it
requests no sensitive data or device permissions of any kind. There are
therefore no such flows to include in the recording.

2. DEVICES AND OPERATING SYSTEMS TESTED
- [要填，例如 iPhone 15 Pro] running iOS [要填，例如 26.5] — physical device
- iPhone 17 Pro and iPhone 17 Pro Max simulators, iOS 26.5

3. APP FUNCTION AND TARGET AUDIENCE
"白白的廁所" (PetToilet) is a companion app for a self-built pet toilet
device based on an ESP8266 microcontroller.

Problem it solves: a dog owner cannot flush the pet toilet while away from
home, and has no record of when or how often the dog used it. Flushing
while the dog is still on the pad also startles the animal.

How it works: a vibration sensor in the pet toilet detects when the dog
steps on and off the pad. The device waits until the dog has completely
left, then runs a water pump to flush. The app lets the owner see the live
status, flush manually, tune the detection thresholds, configure scheduled
cleaning cycles, and review the last two weeks of activity.

Target audience: owners of this self-built device — primarily the developer
and family members. The firmware, wiring diagram, and build instructions are
published as open source so that other makers can build the same device:
https://github.com/agwillfu/PetToilet

4. SETUP AND ACCESS INSTRUCTIONS
No login credentials, account, or sample files are required.

The app opens directly into a built-in simulation mode whenever no device
credentials are configured, which is what happens on a fresh install. This
mode runs the same state machine as the physical device entirely on-device
and generates simulated pet-visit events on a timer, so every feature is
fully exercisable without any hardware, account, or network connection:

  - Live status display cycling through idle / in-use / flushing / cooldown
  - Manual flush button
  - All three behaviour threshold sliders
  - Scheduled cleaning (add, edit, delete time entries)
  - Activity log
  - Device diagnostics

The first simulated event occurs about 12 seconds after launch, then repeats
every 45-110 seconds. No action is needed - simply open the app and wait.

This is not a trial or a feature-limited version of the app. It is a
built-in offline mode, and the full feature set is available for review at
all times.

To connect to real hardware (optional, not needed for review), a user enters
their own Adafruit IO username and API key via the gear icon in the top left.

5. EXTERNAL SERVICES USED
Adafruit IO (https://io.adafruit.com) is the only external service. It is a
general-purpose IoT data platform operated by Adafruit Industries, used here
as an MQTT message broker so the phone and the microcontroller can exchange
messages while both are behind consumer NAT:

  - wss://io.adafruit.com/mqtt  - MQTT over WebSocket (TLS) for live status
                                  and control commands
  - https://io.adafruit.com/api/v2/...  - REST API to read the user's own
                                          historical device data

Each user connects with their own Adafruit IO account. The developer
operates no server of any kind and has no access to any user's data or
credentials.

There are no analytics providers, advertising networks, payment processors,
AI services, authentication services, or any third-party SDKs. The MQTT
client is implemented directly in the app; the app has zero third-party
dependencies.

6. REGIONAL DIFFERENCES
None. The app functions identically in all regions. There is no
region-specific content, pricing, or feature gating. The interface is
localized in Traditional Chinese only; all times are displayed in the
device's own time zone using a 24-hour clock.

7. REGULATED INDUSTRY / THIRD-PARTY MATERIAL
The app does not operate in a regulated industry. It contains no protected
third-party material: the app icon and all interface graphics are original
work, interface symbols are Apple's SF Symbols, and all displayed data is
either generated by the simulation mode or produced by the user's own
device.

Please let me know if any further information would be helpful.
```

---

## 送出流程

1. 在退件頁面按 **「回覆 App 審查」**
2. 貼上整段
3. 送出後，Apple 會用**同一份 build** 繼續審查 —— 不需要重新上傳，build number 也不用 +1

## 之後記得做的事

Apple 特別交代：

> Include this information in the Notes field of the App Review Information
> section in App Store Connect **for future submissions**.

所以下一版送審前，要把第 3～7 項濃縮後放進 **App 審查資訊的「備註」欄位**（上限 4000 bytes）。
這樣就不會再因為同樣理由被退。
