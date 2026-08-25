# App Store Connect 上架資料

複製貼上用。每個欄位都已驗算過長度限制。

> ⚠️ 標示 `【要改】` 的地方需要你填入實際值。

---

## App Information（App 層級，只填一次）

| 欄位 | 值 |
|---|---|
| **Name** | `白白的廁所` <br>（5 字元／上限 30。App Store 全域唯一，幾乎不可能撞名） |
| **Subtitle** | `寵物尿盆自動沖水與行為紀錄` <br>（13 字元／上限 30） |
| **Primary Language** | 繁體中文 |
| **Bundle ID** | `com.agwill.PetToilet` |
| **SKU** | `PETTOILET001`（內部編號，不公開） |
| **Primary Category** | Utilities（工具程式） |
| **Secondary Category** | Lifestyle（生活風格）— 選填 |
| **Content Rights** | 不含第三方內容 |
| **Age Rating** | 4+（問卷全選 NONE / NO，見下方） |

### ⚠️ Developer Name（不可逆）

個人帳號的開發者名稱**強制為法定姓名**，且**只能在建立第一個 App 時設定，之後永遠不能改**。
你的會顯示為 `FU WEI YUAN`。若不能接受，唯一解法是改用公司帳號（需 D-U-N-S 編號）。

---

## Version Information（每個版本都要填）

### Description（上限 4000 字元）

> 第一段就寫明需要自製硬體 —— 這對應審核指南對「需要額外設備」的揭露要求，
> 也避免使用者下載後才發現不能用而給一星。

```
⚠️ 本 App 需要搭配自製硬體才能實際控制裝置。若沒有硬體，App 會自動進入內建的模擬模式，可完整體驗所有功能。

「白白的廁所」是自製寵物尿盆自動沖水裝置的遙控 App。

裝置以震動感測器判斷狗狗的如廁行為，等狗狗完全離開後才啟動水泵沖水，避免沖水聲驚嚇到牠。這支 App 讓你在任何地方查看狀態、調整參數、手動沖水，並回顧最近兩週的使用紀錄。

■ 即時狀態
以清楚的圖示與文字顯示裝置目前的狀態：等待中、狗狗使用中、沖水中、靜置中。

■ 手動沖水
一鍵沖水。只有在「等待中」狀態才會接受指令，避免打斷正在進行的流程。

■ 行為判斷參數
・站上判斷：持續偵測到震動多久，才認定狗狗真的站上去了（1–30 秒）
・離開判斷：沒有震動多久，才認定狗狗已經離開（5–60 秒）
・沖水時間：水泵運轉的持續時間（10 秒–2 分鐘）

■ 定時清洗
每天最多可設定 6 個時段自動清洗，每次 10 秒至 5 分鐘。排程由裝置本身執行，手機關機或不在身邊也會照常運作。清洗時間到但狗狗正在使用時會自動延後，不會在牠身上沖水。

■ 活動紀錄
保留最近兩週的使用與沖水紀錄，並標示每次沖水的觸發來源（自動／手動／排程）。可隨時清除。

■ 裝置診斷
韌體版本、WiFi 訊號、運行時間、記憶體狀態一目瞭然，也可以遠端讓裝置進入韌體更新模式。

■ 隱私
沒有帳號系統、沒有分析工具、沒有廣告、沒有第三方 SDK。開發者沒有任何伺服器，也拿不到你的任何資料。你的 Adafruit IO 金鑰只存放在裝置的 Keychain 中，不會同步到 iCloud。

■ 硬體需求
・NodeMCU（ESP8266）開發板
・SW-420 震動感測器
・IRF520 MOSFET 模組與水泵
・免費的 Adafruit IO 帳號
韌體與接線說明為開放原始碼，見下方支援網址。
```

### Promotional Text（上限 170 字元，可隨時改不用送審）

```
新增定時清洗排程與兩週活動紀錄。所有時間改為 24 小時制，並依手機所在時區自動換算。
```

### Keywords（⚠️ 上限 **100 bytes** 不是字元）

```
寵物,狗,尿盆,沖水,自動化,遙控,智慧家庭,MQTT,IoT,ESP8266
```

**71 bytes** ✅（中文一字約 3 bytes）

規則：逗號分隔、**不要加空格**、不要放 App 名稱或公司名（搜尋已自動涵蓋）、不要放他人商標。

### URLs

| 欄位 | 值 |
|---|---|
| **Support URL**（實務上必填） | `https://github.com/agwillfu/PetToilet` |
| **Privacy Policy URL**（必填） | `https://agwillfu.github.io/PetToilet/privacy.html` |
| Marketing URL（選填） | 留空 |

---

## App Privacy

**選「No, we do not collect data from this app」** → Save → Publish。之後不需回答其他問題。

依據 Apple 對 collect 的定義（「傳出裝置且讓你或你的合作夥伴能夠存取」），
使用者輸入的 Adafruit IO 憑證**不算收集** —— 開發者沒有伺服器、拿不到那把金鑰，
它只送往使用者自己的 Adafruit IO 帳號。

---

## Age Rating 問卷（預期結果 4+）

現行級別為 4+ / 9+ / 13+ / 16+ / 18+（舊的 12+、17+ 已廢除）。

| 問題類別 | 回答 |
|---|---|
| 暴力、恐怖、性、粗俗幽默、酒精菸草毒品、賭博、模擬賭博 | 全部 **NONE** |
| **Health or Wellness Topics** | **NO** —— 紀錄的是狗的排泄行為，不是人類健康資訊 |
| **User-Generated Content** / **Messaging and Chat** | **NO** —— MQTT 是機器對機器的控制指令，不是使用者間通訊 |
| Unrestricted Web Access | **NO** |
| In-App Controls（家長控制等） | **NO** |

---

## ⚠️ DSA Trader Status（歐盟數位服務法，容易漏）

即使不在歐盟上架也**必須宣告**。

**選 `not a trader`** —— 這是免費、無營利意圖的個人興趣專案。

**為什麼重要**：若勾 trader，Apple 會把你的**地址與電話公開顯示**在 27 個歐盟國家的
App Store 產品頁上。勾 not a trader 的唯一代價是歐盟使用者會看到「消費者保護法規不適用」的提示。

（若完全不想處理，也可以在 Availability 直接排除歐盟。）

---

## App Review Information

| 欄位 | 值 |
|---|---|
| Contact First / Last Name | `【要改】` |
| Contact Email | `【要改】`（要真的有人看） |
| Contact Phone | `【要改】` ⚠️ **必須國際格式含 `+`**，台灣是 `+886...`；只填數字會被擋 |
| Sign-in required | **關閉** —— 本 App 沒有帳號系統 |

### Notes（⚠️ 上限 **4000 bytes**，請用英文）

> 中文一字約 3 bytes，用英文可以寫進更多內容，而且審查員讀英文。
> ⚠️ 措辭上說 **built-in simulation mode**，不要說 "demo version" ——
> 審核指南 2.2 規定「Demos, betas, and trial versions don't belong on the App Store」，
> 用錯詞可能讓審查員誤以為整個 App 是試用版。

```
WHAT THIS APP DOES
This is a companion app for a self-built pet toilet device based on an
ESP8266 microcontroller. The device detects when a dog uses the toilet
via a vibration sensor and automatically flushes after the dog leaves.
The app and the device communicate over MQTT through Adafruit IO
(wss://io.adafruit.com/mqtt).

NO HARDWARE OR ACCOUNT NEEDED TO REVIEW THIS APP
The app launches directly into a built-in simulation mode when no
credentials are configured, which is exactly what you will see on first
launch. This mode runs the complete device state machine locally and
generates simulated pet-visit events on a timer, so every feature can be
exercised without any hardware, account, or network connection:

  - Live status display cycling through idle / in-use / flushing / cooldown
  - Manual flush button
  - All three behaviour threshold sliders
  - Scheduled cleaning (add, edit, delete time entries)
  - Activity log
  - Device diagnostics

The first simulated event occurs about 12 seconds after launch, then
repeats every 45-110 seconds. Simply open the app and wait.

If you would also like to see the app driving the real hardware, a video
recorded on a physical iPhone is available here:
https://agwillfu.github.io/PetToilet/demo.mp4

PRIVACY
No accounts, no analytics, no advertising, no third-party SDKs, no
in-app purchases. The developer operates no server and receives no user
data whatsoever.

Users may optionally enter their OWN Adafruit IO credentials to connect
to their OWN device. The API key is stored only in the device Keychain
with kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly and is never
synced to iCloud. It is transmitted only to Adafruit IO to authenticate
to the user's own account. This is why the App Privacy section declares
that no data is collected.

OPEN SOURCE
The device firmware, wiring diagram and build instructions are published
at: https://github.com/agwillfu/PetToilet
```

---

## 螢幕截圖

已產生於 `04_AppStore/screenshots/`，皆為 **1320×2868、無 alpha 通道**（iPhone 6.9"）：

| 檔案 | 內容 |
|---|---|
| `1_status.png` | 即時狀態與手動沖水 |
| `2_settings.png` | 行為判斷參數 |
| `3_schedule.png` | 定時清洗排程 |
| `4_activity.png` | 活動紀錄 |

只需要上傳這一組。Apple 會自動縮放到較小的機型：

> "If your app's user interface is the same across multiple device sizes and localizations,
> provide only the highest resolution screenshots required. They automatically scale down
> to smaller device sizes."

因為 App 已設定為**只支援 iPhone**，不需要 iPad 截圖。

重新產生：`bash 02_Tools/make_screenshots.sh`

---

## 版本號規則（被退件時最常犯的錯）

| | Build Setting | 說明 |
|---|---|---|
| 行銷版本 | `MARKETING_VERSION` = `1.0.0` | 使用者可見，必須大於前一個已上架版本 |
| 建置編號 | `CURRENT_PROJECT_VERSION` = `1` | **同一個行銷版本內每次上傳都必須遞增** |

⚠️ 被退件重傳時，**行銷版本不用改，但建置編號一定要 +1**，否則 App Store Connect 直接拒收。
