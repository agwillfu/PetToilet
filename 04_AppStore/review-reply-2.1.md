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

```
Thank you for the review. Please find the requested information below.

1. SCREEN RECORDING
Two recordings captured on a physical iPhone 14 Pro running iOS 26.6.1:

App walkthrough (screen recording, 41s):
https://agwillfu.github.io/PetToilet/demo-app.mp4

The same app driving the actual hardware (22s):
https://agwillfu.github.io/PetToilet/demo-hardware.mp4

The first recording begins with launching the app from the Home Screen and
shows the typical user flow through the core features: live device status,
manual flush, the three behaviour threshold sliders, scheduled cleaning
setup, the activity log, and device diagnostics. The second recording shows
the physical pet toilet responding to a flush command sent from the app.

The app has no account registration, login, or deletion flows; no paid
content, purchases, or subscriptions; no user-generated content; and it
requests no sensitive data or device permissions of any kind. There are
therefore no such flows to include in the recordings.

2. DEVICES AND OPERATING SYSTEMS TESTED
- iPhone 14 Pro running iOS 26.6.1 (physical device)
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
