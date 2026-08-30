# 回覆 Guideline 2.1 — Information Needed（2026-08-29 退件）

**不用重新編譯、不用新 build、build number 不用 +1。**
在退件頁面按「回覆 App 審查」貼上下面整段即可，Apple 會用同一份 build 繼續審。

---

## 影片

兩支影片已轉成 H.264 放在 `docs/`，推上 GitHub 後的直連：

| 檔案 | 內容 | 網址 |
|---|---|---|
| `docs/demo-app.mp4` | iPhone 螢幕錄影，41 秒 | `https://agwillfu.github.io/PetToilet/demo-app.mp4` |
| `docs/demo-hardware.mp4` | 實體裝置運作，22 秒 | `https://agwillfu.github.io/PetToilet/demo-hardware.mp4` |

> **為什麼要轉檔**：原始錄影是 HEVC（H.265）。Safari 播得動，但**桌機版 Chrome 與
> Firefox 通常播不了 HEVC** —— 審查員用什麼瀏覽器無法控制，影片打不開等於沒交。
> H.264 是到處都能播的格式。
>
> 轉檔指令（macOS 內建，不需 ffmpeg）：
> ```bash
> avconvert --source 原始檔.MOV --preset Preset1280x720 --output docs/輸出.mp4 --replace
> ```

---

## 回覆全文（直接複製貼上，已填入實際機型）

⚠️ **回覆欄位上限 4000 字元。** 下面這版是 **3919 字元**，剛好放得進去。
初版寫了 4743 字被擋下，七項內容都在，只是敘述壓縮過。

```
Thank you for the review. Please find the requested information below.

1. SCREEN RECORDING
Recorded on a physical iPhone 14 Pro running iOS 26.6.1:

App walkthrough (41s):
https://agwillfu.github.io/PetToilet/demo-app.mp4
The same app driving the actual hardware (22s):
https://agwillfu.github.io/PetToilet/demo-hardware.mp4

The first recording begins with launching the app from the Home Screen and
shows the typical user flow: live device status, manual flush, the three
behaviour threshold sliders, scheduled cleaning, the activity log, and
device diagnostics. The second shows the physical pet toilet responding to
a flush command sent from the app.

The app has no account registration, login, or deletion flows; no purchases
or subscriptions; no user-generated content; and it requests no sensitive
data or device permissions. There are no such flows to record.

2. DEVICES AND OS TESTED
- iPhone 14 Pro, iOS 26.6.1 (physical device)
- iPhone 17 Pro / 17 Pro Max simulators, iOS 26.5

3. FUNCTION AND TARGET AUDIENCE
PetToilet is a companion app for a self-built pet toilet device based on an
ESP8266 microcontroller.

Problem solved: a dog owner cannot flush the pet toilet while away from
home and has no record of when the dog used it. Flushing while the dog is
still on the pad also startles the animal.

A vibration sensor detects when the dog steps on and off the pad. The
device waits until the dog has fully left, then runs a water pump. The app
shows live status, flushes manually, tunes detection thresholds, configures
scheduled cleaning, and shows two weeks of activity.

Audience: owners of this self-built device. Firmware, wiring diagram and
build instructions are open source:
https://github.com/agwillfu/PetToilet

4. SETUP AND ACCESS
No credentials, account or sample files are required.

On a fresh install the app opens directly into a built-in simulation mode.
It runs the same state machine as the physical device entirely on-device
and generates simulated pet-visit events on a timer, so every feature is
exercisable without hardware, account or network: live status (idle /
in-use / flushing / cooldown), manual flush, all three threshold sliders,
scheduled cleaning, activity log, and diagnostics.

The first simulated event occurs about 12 seconds after launch, then
repeats every 45-110 seconds. Just open the app and wait.

This is not a trial or feature-limited build. It is an offline mode; the
full feature set is available for review at all times.

To connect real hardware (not needed for review), the user enters their own
Adafruit IO credentials via the gear icon.

5. EXTERNAL SERVICES
Adafruit IO (https://io.adafruit.com) is the only external service, used as
an MQTT broker so the phone and the microcontroller can exchange messages
while both are behind consumer NAT:
- wss://io.adafruit.com/mqtt (TLS) for live status and commands
- https://io.adafruit.com/api/v2/... to read the user's own history

Each user connects with their own Adafruit IO account. The developer
operates no server and has no access to any user's data or credentials.

There are no analytics providers, advertising networks, payment processors,
AI services, authentication services, or third-party SDKs. The MQTT client
is implemented in the app itself; there are zero third-party dependencies.

6. REGIONAL DIFFERENCES
None. The app functions identically in all regions, with no region-specific
content, pricing or feature gating. The interface is Traditional Chinese
only; times use the device's own time zone and a 24-hour clock.

7. REGULATED INDUSTRY / THIRD-PARTY MATERIAL
Not a regulated industry. No protected third-party material: the app icon
and interface graphics are original work, interface symbols are Apple's SF
Symbols, and all displayed data is generated either by the simulation mode
or by the user's own device.

Please let me know if any further information would be helpful.
```

---

## 送出流程

1. **先 `git push`**，並確認兩個影片網址真的打得開（Pages 部署要一兩分鐘）
2. 在退件頁面按 **「回覆 App 審查」**
3. 貼上整段送出

⚠️ **一定要先確認影片連結可以播再送出。** 連結掛掉是這類回覆最常見的二次退件原因。

---

## 下一版記得

Apple 明確交代：

> Include this information in the Notes field of the App Review Information
> section in App Store Connect **for future submissions**.

第 3～7 項合計約 3800 bytes，**放得進 4000 bytes 的備註欄**。下次送審前先塞進去，
就不會再因同樣理由被退。
