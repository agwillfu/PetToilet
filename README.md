# 🐾 PetToilet — 寵物尿盆自動沖水與行為監控系統

給狗狗「白白」用的自動沖水尿盆。震動感測器偵測進出，**狗狗完全離開後才**啟動水泵沖水（避免沖水聲驚嚇），並透過 MQTT 上雲，可遠端調整參數、手動沖水、查看使用紀錄。

韌體支援 **WiFi 無線更新（OTA）**，第一次燒錄之後就不需要再接 USB。

- 原始碼：<https://github.com/agwillfu/PetToilet>
- 隱私權政策：<https://agwillfu.github.io/PetToilet/privacy.html>

---

## 目前狀態

| 項目 | 狀態 |
|---|---|
| 韌體（ESP8266 + Adafruit IO） | ✅ 運作中，v0.2.0 |
| WiFi 無線更新 | ✅ 已驗證 |
| 定時清洗排程 | ✅ 已驗證（秒級準確） |
| iOS App | ✅ Demo 模式與實機連線都可用 |
| App Store 上架 | ⬜ 未開始 |

---

## 硬體

### 元件

| 元件 | 型號 | 備註 |
|---|---|---|
| 主控板 | NodeMCU (ESP8266, 4MB flash) | |
| 震動感測器 | SW-420 模組 | 目前 1 組，原規劃 4 組 |
| 水泵驅動 | IRF520 MOSFET 模組 | |
| 電源 | 110V AC 轉 5V DC 工業級開關電源 | 金屬外殼，鎖螺絲型 |

### 接線

**AC 高壓端**

| 端子 | 接線 | 備註 |
|---|---|---|
| L | 110V 火線 | |
| N | 110V 中性線 | |
| FG / ⏚ | 地線 | 金屬外殼接地，防漏電與濾波（**重要**） |

**DC 低壓與訊號端**

| 元件 | 元件接腳 | NodeMCU | 說明 |
|---|---|---|---|
| 電源供應器 | V+ (5V) | **Vin** | 供電 |
| 電源供應器 | V- (COM) | **GND** | 系統主共地 |
| SW-420 | VCC | **3V3** | |
| | GND | **GND** | |
| | DO | **D2** | 中斷輸入，RISING 觸發 |
| IRF520 | VCC | **Vin (5V)** | 控制端供電 |
| | GND | **GND** | |
| | SIG | **D6** | HIGH = 開啟水泵 |
| | VIN / GND（端子側） | 外部 5V / GND | 水泵驅動電源 |
| | V+ / V-（端子側） | 水泵馬達 +/- | 負載輸出 |

### 感測器靈敏度

SW-420 上的藍色電位器控制靈敏度。**建議調到「輕敲盆邊會觸發、但環境震動（走動、冰箱）不會」**。

靈敏度過高不會造成誤沖水（軟體有防誤觸邏輯），但會產生大量無謂的中斷。

---

## 系統架構

```
  SW-420 ──中斷──> NodeMCU ──TLS/MQTT──> Adafruit IO ──> iOS App（未完成）
                      │
                      └──> IRF520 ──> 水泵
```

裝置躲在家用 NAT 後面，手機無法直接連入，所以用 Adafruit IO 當雲端會合點：裝置持續保持一條對外的 TLS 連線，App 連同一個 broker，兩邊在雲端交換訊息。

**網路與沖水功能完全解耦** —— 斷網、斷雲端、Adafruit IO 掛掉時，狀態機照常運作，狗狗上完廁所還是會沖水。

---

## 狀態機

```
IDLE ──偵測到震動──> DETECTING ──持續震動達 entry 秒──> IN_USE
  ↑                      │                                │
  │                 靜止 3 秒                       靜止達 exit 秒
  │                （判定誤觸）                            │
  │                      │                                ↓
  └──────────────────────┴──── COOLDOWN <──── FLUSHING（水泵 ON + LED 閃爍）
                              靜置 8 秒        持續 duration 秒
```

- **DETECTING** 是內部防抖狀態，**不會發布到雲端**（環境震動會讓它每分鐘進出好幾次，發上去只是洗版並吃掉免費額度）
- **COOLDOWN** 是沖水後的靜置期，期間忽略所有震動。沒有這一段的話，水泵自身的震動會讓感測器立刻再次觸發，形成無限沖水迴圈
- 升級到 IN_USE 需要「**已在 DETECTING 停留足夠久**」**且**「**此刻仍在震動**」—— 只看停留時間會讓狗狗路過碰一下就誤判成使用中

---

## Adafruit IO Feeds

免費帳號上限 10 個 feed，這裡用掉 8 個。

| Feed key | 方向 | 型別 | 說明 |
|---|---|---|---|
| `state` | 裝置 → App | 字串 | `idle` / `inuse` / `flushing` / `cooldown` / `ota` / `offline` |
| `flush` | App → 裝置 | `1` | 手動沖水（僅在 idle 狀態接受） |
| `entry-threshold` | 雙向 | 秒 | 站上判斷時間，範圍 1–30 |
| `exit-threshold` | 雙向 | 秒 | 離開判斷時間，範圍 5–60 |
| `flush-duration` | 雙向 | 秒 | 沖水持續時間，範圍 10–120 |
| `last-flush` | 裝置 → App | 字串 | 上次沖水時間 `YYYY-MM-DD HH:MM:SS` |
| `schedule` | 雙向 | JSON | 定時清洗排程 |
| `ota` | App → 裝置 | `1` | 進入無線更新模式 |
| `diag` | 裝置 → App | JSON | 每 5 分鐘回報一次 |

### 定時清洗

`schedule` feed 的格式：

```json
{"on":true,"dur":120,"times":["08:00","14:00","20:00"]}
```

最多 6 個時間點，`dur` 範圍 10–300 秒。**時間點各存一個 feed 會爆掉免費版的 10 個額度，
所以整份設定塞在單一個 feed 的 JSON 裡。**

排程跑在裝置端而不是 App 端 —— 手機關機、不在身邊、App 沒開的時候，清洗還是要照常執行。

幾個設計細節：

- **獨立的時間長度**。日常沖水（`flush-duration`，上限 30 秒）與定時清洗（`dur`，上限 300 秒）
  是不同性質的動作。共用一個參數的話，把清洗設成兩分鐘會連帶讓每次狗狗上完廁所都沖兩分鐘。
- **狗狗正在使用時會延後**，最多等 20 分鐘。直接跳過會漏掉清洗，無限等待則會在感測器卡住時
  永遠不執行。
- **只在該分鐘的前 20 秒內觸發**。「今天已執行」的紀錄只存在 RAM，裝置在該分鐘內重開機會
  遺失；窄窗口大幅降低重複沖水的機率。
- **裝置不回發 `schedule` feed**。它有訂閱這個 feed，發回去會被 broker 原樣送回，
  造成解析→發布→解析的無限迴圈。實際套用值改由 `diag` 的 `sch_on` / `sch_dur` / `sch_t` 回報。
- `last-flush` 會帶觸發來源：`2026-08-22 15:46:20 排程` / `... 手動` / `... 自動`。

### 通訊協定版本

`diag` 裡的 `proto` 欄位，對應韌體的 `PROTOCOL_VERSION` 與 App 的 `DeviceProtocol.supported`。

**為什麼需要**：韌體可以 OTA 在幾分鐘內全部更新，但家人手機上的 App 什麼時候更新
**你無法控制**。改了 feed 格式卻沒有版本號的話，舊版 App 會默默壞掉，而且不會有人回報。

| | 你的控制力 | 生效速度 |
|---|---|---|
| 韌體 | 完全掌控 | OTA，幾分鐘 |
| App | 無法強制 | 看家人什麼時候按更新 |

**什麼時候要 +1**：

- ✅ 改掉或刪除既有 feed、改變 payload 格式、改變欄位語意
- ❌ 純粹新增欄位或新增 feed（舊版 App 忽略它即可，不算破壞相容）

App 發現裝置版本比自己新時，會在最上方顯示提示。**刻意只提示、不封鎖畫面** ——
就算格式對不上，手動沖水這類基本操作通常還是能用，直接擋住整個 App 會讓家人在
需要沖水時什麼都做不了，比顯示錯誤的數值更糟。

舊韌體沒有 `proto` 欄位，App 會視為第 1 版（那正是加入這個欄位之前的格式）。

`diag` 內容範例：

```json
{"fw":"0.1.3","heap":32320,"maxblock":32256,"frag":1,"rssi":-57,
 "uptime":13,"mfln":1,"state":"idle","ip":"10.20.30.181",
 "entry":5,"exit":22,"dur":6}
```

App 送來的參數一律夾在上下界內，送 `99` 會被存成 `30`。`diag` 回報的是**實際套用值**，不是收到的原始值。

`offline` 是 MQTT 的 Last Will —— 裝置非正常斷線時由 broker 代發。

### 設定的保存

Adafruit IO **不支援 MQTT 的 retain flag**。裝置改用 `<user>/feeds/<feed>/get` 機制：連線時對三個參數 feed 發一個 `/get`，broker 會把最後一筆值推回來。所以重開機後參數會還原成 App 上次設定的值，不會退回程式碼裡的預設。

---

## 從零開始設定

### 1. 開發環境（macOS）

```bash
# arduino-cli（免 Homebrew、免 sudo）
mkdir -p ~/.local/bin
curl -fsSL -o /tmp/acli.tar.gz \
  https://downloads.arduino.cc/arduino-cli/arduino-cli_latest_macOS_ARM64.tar.gz
tar xzf /tmp/acli.tar.gz -C ~/.local/bin arduino-cli
export PATH="$HOME/.local/bin:$PATH"

# ESP8266 開發板核心
arduino-cli config init --overwrite
arduino-cli config add board_manager.additional_urls \
  https://arduino.esp8266.com/stable/package_esp8266com_index.json
arduino-cli core update-index
arduino-cli core install esp8266:esp8266

# 函式庫
arduino-cli lib install "MQTT"          # 256dpi/arduino-mqtt
arduino-cli lib install "ArduinoJson"

# 燒錄與工具腳本需要
python3 -m pip install --user pyserial
```

> ### ⚠️ Apple Silicon 必讀
>
> **ESP8266 的工具鏈全部是 x86_64，沒有 arm64 版本**（編譯器、python、mkspiffs 都是），
> 官方核心停在 2023 年也不會再出。所以 M 系列 Mac **必須安裝 Rosetta 2**：
>
> ```bash
> sudo softwareupdate --install-rosetta
> ```
>
> 沒裝的話編譯會直接失敗：`bad CPU type in executable`。
> 這需要管理員權限，一般使用者帳號跑不了。
>
> （對照組：ESP32 的工具鏈有原生 arm64，完全不需要 Rosetta。若日後換板子，這個限制就消失。）

**USB 驅動不用裝。** macOS 已內建 CH340（`0x1A86:0x7523`）與 CP2102（`0x10C4:0xEA60`）的驅動。
插上就會出現 `/dev/cu.usbserial-*`。**不要去下載第三方 WCH 驅動，已知會造成系統崩潰。**

若插上沒反應：先確認用的是**傳輸線不是充電線**，再檢查是否錯過了 macOS 的「允許配件連接」提示
（系統設定 → 隱私權與安全性 → 允許配件連接）。

### 2. Adafruit IO

1. 到 <https://io.adafruit.com/> 註冊免費帳號
2. Feeds → New Feed，建立上表的 8 個 feed。**名稱直接用 feed key**（小寫、連字號），
   這樣產生的 key 才會一致。建完在列表確認 Key 欄位
3. 進入任一 Dashboard 頁面 → 右上角黃色鑰匙圖示 **My Key**，取得 Username 與 Active Key
   （首頁看不到這個按鈕，一定要先進 Dashboard）

### 3. secrets.h

```bash
cd 01_Arduino/PetToilet
cp secrets.h.example secrets.h
# 編輯 secrets.h 填入 WiFi、Adafruit IO、OTA 密碼
```

`secrets.h` 已列在 `.gitignore`。

> **OTA 走明文 HTTP 時 `.bin` 可被下載並逆向**，裡面的字串都不是秘密。
> 這些憑證只保護你家 WiFi 與 Adafruit IO 帳號，不要放更敏感的東西。
> OTA 密碼也**不要跟 WiFi 密碼設成同一組**。

---

## 編譯與燒錄

### 第一次：USB

```bash
arduino-cli board list          # 找出序列埠，例如 /dev/cu.usbserial-10

arduino-cli compile --upload \
  -p /dev/cu.usbserial-10 \
  --fqbn esp8266:esp8266:nodemcuv2:eesz=4M2M,ip=lm2f,xtal=160 \
  01_Arduino/PetToilet
```

FQBN 的三個選項都是必要的：

| 選項 | 意義 | 為什麼 |
|---|---|---|
| `eesz=4M2M` | 4MB flash，2MB 檔案系統 | OTA 需要同時容納新舊兩份韌體 |
| `ip=lm2f` | lwIP v2 Lower Memory | 省下數 KB heap，OTA 可靠度關鍵 |
| `xtal=160` | CPU 160MHz | 官方對 TLS 的硬性建議，80MHz 下交握容易觸發看門狗 |

### 之後：無線更新

```bash
python3 02_Tools/ota.py
```

自動完成：編譯 → 從 diag 讀取裝置 IP → 送 MQTT 指令進入 OTA 模式 → 從 WiFi 燒錄 → 驗證版本。

```bash
python3 02_Tools/ota.py --ip 10.20.30.181   # 手動指定 IP
python3 02_Tools/ota.py --no-build          # 用現有的 build/
```

**手動觸發**（不用腳本）：在 Adafruit IO 網頁上把 `ota` feed 設成 `1`，裝置會：

1. 關閉水泵並回到 IDLE（更新中重開機絕不能讓水泵卡在開啟狀態）
2. 斷開 MQTT 並呼叫 `net.stop()` 釋放 BearSSL 的緩衝區
3. 啟動 ArduinoOTA，開一個 **5 分鐘**的更新視窗，LED 快閃
4. 逾時沒人來燒錄就自動重開機回到正常運作

然後：

```bash
python3 ~/Library/Arduino15/packages/esp8266/hardware/esp8266/3.1.2/tools/espota.py \
  -i <裝置IP> -p 8266 -a <OTA密碼> -f build/PetToilet.ino.bin
```

### 序列埠監看

```bash
python3 -c "
import serial,sys
p=serial.Serial('/dev/cu.usbserial-10',115200,timeout=1)
while True:
    l=p.readline()
    if l: sys.stdout.write(l.decode('utf-8','replace'))
"
```

⚠️ **開啟序列埠會觸發 DTR 重置，裝置會重開機。** OTA 進行中絕對不要開序列埠。

---

## iOS App

SwiftUI，Swift 6 嚴格並發，**零第三方相依**。

### 在模擬器上執行

```bash
cd 03_iOS/PetToilet
xcodebuild build -project PetToilet.xcodeproj -scheme PetToilet \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

開發時可以用環境變數注入憑證，免去每次手動輸入（只在 DEBUG build 生效）：

```bash
SIMCTL_CHILD_AIO_USER=你的帳號 SIMCTL_CHILD_AIO_KEY=你的Key \
  xcrun simctl launch booted com.agwill.PetToilet
```

### 安裝到自己的 iPhone

1. Xcode → Settings → Accounts，用你的 Apple ID 登入（免費帳號即可）
2. 開啟 `03_iOS/PetToilet/PetToilet.xcodeproj`，選 PetToilet target →
   Signing & Capabilities → Team 選你的名字（Personal Team）
3. iPhone 用 USB 接上，Developer Mode 打開
   （設定 → 隱私權與安全性 → 開發者模式，要重開機）
4. Xcode 左上角的執行目標選你的 iPhone，按 ⌘R

> **免費帳號簽出來的 App 7 天後會失效**，要重新用 Xcode 安裝一次。
> 要給家人長期使用必須加入 Apple Developer Program（US$99/年）走 TestFlight。

### 架構

```
DeviceBackend (protocol, actor)
├── SimulatedDevice   Demo 模式：完整重現韌體狀態機，不連任何伺服器
└── MQTTDevice        實機：透過 Adafruit IO
        └── MQTTWebSocketClient   自製 MQTT 3.1.1 over WSS
```

**為什麼要有 Demo 模式**：一是沒有硬體時也能開發 UI，二是 App Store 審查員手上
沒有這台裝置 —— App 打開只顯示「連線中…」會直接被以審查指南 2.1 退件。

**為什麼自己寫 MQTT**：需求極小（訂閱 7 個 topic、發布 6 個），而 SwiftNIO 系列
會為此拉進四個套件。`URLSessionWebSocketTask` 由系統處理 TLS，零相依也讓 App Store
的隱私聲明最單純。Adafruit IO 在 443 埠提供 `wss://io.adafruit.com/mqtt`。

實作上兩個容易踩的地方：

- **解碼必須是累積式的**。MQTT over WebSocket 允許一個 frame 內含多個 MQTT 封包，
  也允許單一封包跨越多個 frame。把每個 frame 當成一個封包在多數情況下會「剛好」
  正確，然後在酬載變大時隨機出錯。
- **不要指定 `mqtt` subprotocol**。Adafruit IO 的伺服器不會回應它（實測回
  `101 Switching Protocols` 但無 `Sec-WebSocket-Protocol` 標頭）。

### App 圖示

圖示是程式化產生的，不是圖檔 —— 調色或改比例只要改參數重跑：

```bash
swiftc -O 02_Tools/make_icon.swift -o /tmp/make_icon
/tmp/make_icon 03_iOS/PetToilet/PetToilet/Assets.xcassets/AppIcon.appiconset/AppIcon.png
```

設計是水藍漸層 + 白色狗掌 + 掌墊中的水滴 + 背景水波紋。
輸出 1024×1024 **無 alpha 通道**（App Store 的硬性要求，有透明度會被退件），
其餘尺寸由 Xcode 自動產生。

繪製時兩個 CoreGraphics 的坑：`clockwise: true` 在 y 軸向上的座標系走的是上半圓
（水滴要圓底尖頂需要 `false`）；不要用 `.copy` 混合模式挖空，它會用單一色蓋掉
底下的漸層，形狀只要超出白色區域一點就會露出色差。

### 活動紀錄

紀錄**從 Adafruit IO 撈歷史**，不是只記錄 App 開著時觀察到的事件。

理由：狗狗上廁所時使用者不會正好開著 App。只靠 MQTT 即時訂閱的話，
兩週的紀錄裡幾乎不會有東西。真正的歷史在 feed 上（免費版保留 30 天），
用 REST API `GET /feeds/<key>/data?start_time=…` 撈回來。

- 來源：`last-flush`（每筆沖水，含觸發來源）與 `state`（只取 `inuse`）
- 本機以 JSON 檔快取於 Application Support，保留 **14 天**，開啟即顯示、離線可看
- 去重分兩層：先比 Adafruit IO 的 data point id，再比「訊息相同且時間相差 15 秒內」
  —— 同一事件可能已透過 MQTT 即時記錄過（本機 UUID），又從 REST 撈回來一次（AIO id），
  兩者 id 不同只能靠內容比對
- **「清除紀錄」記錄一個時間戳，早於它的一律不顯示**。不能真的刪掉就算了，
  因為下次同步又會全部回來；也刻意不去刪 Adafruit IO 上的資料，那是裝置的原始紀錄

#### 只放「裝置上真正發生的事」

活動紀錄裡只有兩種項目：`白白開始使用` 與 `沖水完成（原因）`。以下**刻意排除**：

| 排除項目 | 原因 |
|---|---|
| 連線狀態變化 | 手機休眠、切換網路都會正常斷線重連。記進去會把兩週紀錄洗成雜訊，而且「連線失敗」會讓人以為壞了。目前狀態在狀態卡片上已看得到 |
| 技術訊息（`.log` 事件） | Demo 模式提示、送出失敗、排程已更新等。改存在不持久化的 `notices`，只在診斷區塊顯示 |
| `detecting` / `cooldown` / `idle` | 流程雜訊，不是使用者關心的事件 |
| `flushing` | 會與 `last-flush` 的紀錄重複 |

#### `.syncing` 事件（重要）

Adafruit IO 沒有 retain flag，連線後必須對 `<feed>/get` 發空訊息才能取回目前值。
**那些回應在 MQTT 上跟「剛發生的事件」完全無法區分。**

沒有處理的話：每次開 App 都會把舊的 `last-flush` 當成一次新的沖水記進紀錄，
時間還是錯的（App 開啟時間而非實際沖水時間）—— 開十次就多十筆假紀錄。

解法是裝置層在回填期間送 `.syncing(true)` / `.syncing(false)`，上層在這段期間
不寫入活動紀錄。實作重點：

- `MQTTDevice` 追蹤還在等回應的 feed，收齊就結束
- **必須有逾時**（5 秒）—— 沒有資料的 feed 不會回應 `/get`，光等會永遠等不完
- `SimulatedDevice` 也要送同樣的標記，否則 Demo 模式行為會不一致

### 時間顯示

App 內所有時間**一律 24 小時制**，並依手機自己的時區換算。工具在 `Models/Formatting.swift`。

強制 24 小時制的正確方式是設定 Unicode 的 hour cycle：

```swift
var components = Locale.Components(locale: .autoupdatingCurrent)
components.hourCycle = .zeroToTwentyThree
let locale = Locale(components: components)
```

實測結果：

| 地區設定 | 原本 | 強制 24h |
|---|---|---|
| `en_US` | 10:29 PM | **22:29** |
| `zh_Hant_TW` | 晚上10:29 | **22:29** |
| `en_GB` / `ja_JP` | 22:29 | 22:29（本來就是） |

> ⚠️ **不要用 `.hour(.twoDigits(amPM: .omitted))` 來達成這件事。**
> 它只是把 AM/PM 標記藏起來，時鐘本身仍是 12 小時制 —— 在 12 小時制的地區設定下
> 會把 22:29 顯示成 **10:29**，那是錯誤的時間而不只是少了標記。

**「上次沖水」不使用裝置送來的時間字串。** 裝置送的是 `2026-08-23 22:28:59 手動`，
那是裝置所在時區的牆上時間、沒有帶時區資訊，手機在其他時區就會顯示錯誤。
改為從活動紀錄取最近一筆沖水事件 —— 那裡存的是絕對時間，顯示時才依手機時區換算。

日期與時間是手動串接的（`"\(shortDate) \(time24)"`），因為讓 `FormatStyle`
一次輸出會在中間補一個逗號（`8/23, 22:29`）。

### 憑證

AIO Key 等同帳號密碼 —— 持有它就能啟動水泵。App 把它存在系統 Keychain
（`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`，不同步到 iCloud）。
使用者名稱不是機密（它出現在每個 MQTT topic 裡），放 UserDefaults。

---

## 疑難排解

| 症狀 | 原因與處理 |
|---|---|
| 編譯 `bad CPU type in executable` | Apple Silicon 沒裝 Rosetta 2，見上方說明 |
| 插上 USB 沒有 `/dev/cu.usbserial-*` | 換傳輸線；檢查「允許配件連接」設定 |
| OTA `Authenticating...FAIL` | OTA 密碼錯。v0.1.1 起認證失敗不會重開機，可直接重試 |
| OTA `No Answer` | 裝置不在 OTA 模式（5 分鐘視窗已過，或從未觸發）。重送 `ota=1` |
| OTA 失敗但雲端控制正常 | **電腦與裝置不在同一個區網**。ArduinoOTA 是純區網協定，封包直接送到裝置 IP，跨網段不通。最常見是 Mac 連到了手機熱點（`172.20.10.x`）。`ota.py` 會先檢查並明確報錯 |
| MQTT 一直連不上 | 檢查 `AIO_USERNAME` 大小寫、Active Key、8 個 feed 是否都存在 |
| `[mqtt] 記憶體不足` | heap 碎片化。裝置會自動退避重試，連續失敗 10 次後重開機 |
| 狀態一直在 idle/detecting 跳 | SW-420 靈敏度過高。v0.1.2 起不再發布到雲端，但仍建議調低旋鈕 |
| 沖水後又立刻進入 detecting | COOLDOWN 太短。調高 `COOLDOWN_MS`（預設 8000ms） |
| 裝置 IP 變了 | DHCP 重新配發。看 `diag` feed 的 `ip` 欄位，或在路由器上把 hostname `pettoilet` 設成固定 IP |

---

## 設計筆記

記錄「為什麼這樣做」，避免日後改動時踩回同樣的坑。

### 為什麼是 Adafruit IO，不是 HiveMQ / EMQX

關鍵在 **MFLN（Maximum Fragment Length Negotiation，RFC 6066）**。

ESP8266 接上 WiFi 後只剩約 40KB heap，而 BearSSL 的 TLS 接收緩衝區**預設 16KB 且必須是連續區塊**。
官方 issue 有實測：free heap 剩 21.5KB 時 `connect()` 直接 OOM，剩 26KB 時交握過程觸發看門狗重開機。

MFLN 讓 client 跟 broker 協商把 TLS 封包切小。談成的話緩衝區從 16KB 降到 512B。實測結果：

```
io.adafruit.com:8883      MFLN_echo=01   ✅
mqtt.flespi.io:8883       MFLN_echo=01   ✅
test.mosquitto.org:8883   MFLN_echo=01   ✅
broker.hivemq.com:8883    ABSENT         ❌
```

HiveMQ 把整條憑證鏈塞在**單一個 3853 bytes 的封包**送出，緩衝區設小會直接在交握階段爆掉。
Adafruit IO 支援 MFLN，實測 TLS 只吃掉約 **5.2KB**，連線後仍有 **32KB heap、碎片化 1%**。

用 `02_Tools/mfln_probe.py <host> <port>` 可以測試任何 broker。

### 為什麼不用 PubSubClient

作者已於 2026 年在 README 掛出停止維護公告，最後一個正式版停在 2020 年。
改用 [256dpi/arduino-mqtt](https://github.com/256dpi/arduino-mqtt)（函式庫名稱 `MQTT`）。

### 為什麼 OTA 與 MQTT 不能同時開著

ESP8266 的記憶體放不下兩份 TLS context。`mqtt.disconnect()` 只關 MQTT 層，
**必須額外呼叫 `net.stop()`** 才會真正釋放 BearSSL 的緩衝區。

同理，**HTTPS OTA 在 ESP8266 上不可行**（會建立第二個 TLS context）。
若日後要做遠端 OTA（不限區網），應該走 **HTTP + RSA-2048 韌體簽章**——
ESP8266 核心原生支援，不需要 TLS，記憶體成本幾乎為零。

### 為什麼釘根憑證而不是憑證指紋

Adafruit 的葉憑證約每半年更換一次（目前這張 2027-01-28 到期），釘指紋會讓裝置每半年失聯。
`certs.h` 內嵌的是 **DigiCert Global Root G2**（有效期到 2038），從 macOS 系統信任庫取出並用
`openssl verify` 驗證過。

### 記憶體實測基準

```
開機                heap=39976
TLS/MQTT 連線後      heap=33488   (TLS 成本約 5.2KB)
穩態                heap≈32330  maxblock≈32260  frag=1%
```

長時間運作若 `frag` 明顯上升或 `maxblock` 掉到 14000 以下，代表有記憶體碎片化問題。
韌體已在 TLS 連線前檢查 `maxblock`，不足就跳過該輪重試而不是硬連。

---

## 檔案結構

```
PetToilet/
├── 01_Arduino/
│   ├── PetToilet/              ← 目前的韌體
│   │   ├── PetToilet.ino
│   │   ├── certs.h             DigiCert Global Root G2
│   │   ├── secrets.h           你的憑證（gitignored）
│   │   └── secrets.h.example
│   ├── Blink/                  板載 LED 測試
│   └── libraries/              Blynk 函式庫（舊版遺留，現已不需要）
├── 02_Tools/
│   ├── ota.py                  一鍵無線更新
│   ├── mfln_probe.py           測試 broker 的 MFLN 支援
│   └── make_icon.swift         App 圖示產生器
├── 03_iOS/PetToilet/           iOS App（SwiftUI，Swift 6 嚴格並發）
│   ├── PetToilet.xcodeproj/
│   └── PetToilet/
│       ├── ContentView.swift          主畫面
│       ├── SetupView.swift            Adafruit IO 帳號設定
│       └── Models/
│           ├── ToiletState.swift      狀態列舉，字串值與韌體對齊
│           ├── DeviceModels.swift     診斷、設定範圍、DeviceBackend 協定
│           ├── FlushSchedule.swift    排程模型與 JSON 編解碼
│           ├── Credentials.swift      Keychain 憑證儲存
│           ├── SimulatedDevice.swift  Demo 模式
│           ├── MQTTDevice.swift       實機連線
│           ├── ToiletController.swift @MainActor @Observable
│           └── MQTT/
│               ├── MQTTWire.swift              MQTT 3.1.1 封包編解碼
│               └── MQTTWebSocketClient.swift   WSS 傳輸層
├── build/                      編譯產物（gitignored）
├── gemini-code-*.md            最初的設計文件（含舊 Blynk 版程式碼，用佔位符）
└── README.md
```

舊的 Blynk 版韌體（`SW420/`）已刪除 —— 裡面有明碼憑證。程式碼結構保留在
`gemini-code-*.md` 中，該文件使用佔位符而非真實憑證。

---

## 待辦

- [ ] 感測器靈敏度旋鈕調校
- [ ] 長時間運作觀察（記憶體、誤判率）
- [x] 定時清洗排程
- [x] iOS App 骨架 + Demo 模式
- [x] iOS App 實機 MQTT 連線
- [ ] Apple Developer Program 申請
- [ ] 推播通知（需要 APNs 伺服器端，規劃為 v2）
- [ ] 擴充到多組感測器（原規劃 4 組）
- [ ] 考慮 HTTP + 簽章 OTA，讓不在家時也能更新
