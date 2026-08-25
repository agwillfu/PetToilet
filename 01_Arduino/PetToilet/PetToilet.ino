/*
 * 寵物尿盆自動沖水與行為監控系統 — Adafruit IO 版
 *
 * 硬體：NodeMCU (ESP8266) + SW-420 震動感測器 (D2) + IRF520 MOSFET 水泵驅動 (D6)
 * 雲端：Adafruit IO，MQTT over TLS (io.adafruit.com:8883)
 * 更新：ArduinoOTA 區網無線燒錄，不需拔下來接 USB
 *
 * 設計重點：
 *   1. 狀態機與網路完全解耦 —— 斷網、斷雲端時沖水功能照常運作。
 *   2. 全域配置 TLS 物件，絕不動態 new/delete，避免 heap 碎片化。
 *   3. 啟用 MFLN 把 TLS 接收緩衝區從 16KB 壓到 512B（已實測 Adafruit IO 支援）。
 *   4. TLS 連線前檢查最大連續記憶體區塊，不足就不硬連。
 *   5. OTA 與 TLS MQTT 不共存 —— 進 OTA 前先釋放 TLS 騰出記憶體。
 */

#include <ESP8266WiFi.h>
#include <WiFiClientSecureBearSSL.h>
#include <ArduinoOTA.h>
#include <MQTT.h>
#include <ArduinoJson.h>
#include <TZ.h>
#include <time.h>

#include "secrets.h"
#include "certs.h"

#define FW_VERSION "0.3.1"

// 韌體與 App 之間的通訊協定版本（feed 名稱、payload 格式、欄位語意）。
//
// 韌體可以 OTA 在幾分鐘內全部更新，但家人手機上的 App 什麼時候更新無法控制。
// 改了格式卻沒有這個版本號的話，舊版 App 會默默壞掉而且不會有人回報。
//
// 什麼時候要 +1：
//   ✅ 改掉或刪除既有 feed、改變 payload 格式、改變欄位語意
//   ❌ 純粹新增欄位或新增 feed（舊版 App 忽略它就好，不算破壞相容）
//
// App 端在 Models/DeviceModels.swift 有對應的 supportedProtocolVersion，
// 發現裝置版本比自己新時會提示使用者更新 App。
#define PROTOCOL_VERSION 1

// ============================ 硬體定義 ============================
const uint8_t PIN_VIBRATION = D2;          // = GPIO4，SW-420 DO，中斷輸入
const uint8_t PIN_PUMP      = D6;          // = GPIO12，水泵驅動模組的訊號腳
const uint8_t PIN_LED       = LED_BUILTIN; // 板載 LED，低電位點亮

// 驅動模組的觸發極性。
//
//   false = 高電位觸發（IRF520 MOSFET 模組、部分繼電器）
//   true  = 低電位觸發（多數光耦合繼電器模組，IN 拉到 GND 才動作）
//
// 接錯的症狀：極性相反時，水泵會在開機後一直運轉，而「沖水」反而是停止。
// 若完全沒有反應，通常不是極性問題，而是 3.3V 的訊號電壓不足以驅動
// 5V 供電的高電位觸發模組。
const bool PUMP_ACTIVE_LOW = false;

// ============================ 連線設定 ============================
const char     AIO_HOST[] = "io.adafruit.com";
const uint16_t AIO_PORT   = 8883;

// Adafruit IO 的 topic 格式固定為 <username>/feeds/<feed key>。
// AIO_USERNAME 來自 secrets.h，是字串常值，所以這裡是編譯期串接，零執行期成本。
#define TOPIC(feed)     AIO_USERNAME "/feeds/" feed
#define TOPIC_GET(feed) AIO_USERNAME "/feeds/" feed "/get"

#define F_STATE     "state"           // 裝置 -> App：目前狀態
#define F_FLUSH     "flush"           // App -> 裝置：手動沖水
#define F_ENTRY     "entry-threshold" // 雙向：站上判斷秒數
#define F_EXIT      "exit-threshold"  // 雙向：離開判斷秒數
#define F_DURATION  "flush-duration"  // 雙向：沖水持續秒數
#define F_LASTFLUSH "last-flush"      // 裝置 -> App：上次沖水時間
#define F_OTA       "ota"             // App -> 裝置：進入 OTA 模式
#define F_DIAG      "diag"            // 裝置 -> App：診斷資訊 (JSON)
#define F_SCHEDULE  "schedule"        // 雙向：定時清洗排程 (JSON)

// ============================ 可調參數 ============================
// 上下界同時是防呆 —— App 傳來的值一律夾在這個範圍內，避免誤設成 0 導致誤判。
const int ENTRY_MIN = 1,  ENTRY_MAX = 30;
const int EXIT_MIN  = 5,  EXIT_MAX  = 60;
const int DUR_MIN   = 10, DUR_MAX   = 120;   // 10 秒 ~ 2 分鐘

int entryThreshold = 5;   // 秒：持續有震動多久才算「狗狗真的站上去了」
int exitThreshold  = 15;  // 秒：沒有震動多久才算「狗狗離開了」
int flushDuration  = 10;  // 秒：水泵運轉多久

// ---- 定時清洗排程 ----
// 與「狗狗用完後沖水」是不同性質的動作，所以用獨立的時間長度參數。
// 共用一個 flushDuration 的話，很容易不小心把日常沖水也設成兩分鐘。
const int MAX_SCHEDULES = 6;
const int SCHED_DUR_MIN = 10, SCHED_DUR_MAX = 300;

struct ScheduleConfig {
  bool     enabled     = false;
  int      durationSec = 120;              // 預設兩分鐘
  uint8_t  count       = 0;
  uint16_t minuteOfDay[MAX_SCHEDULES];     // 0..1439，從午夜起算的分鐘數
  int16_t  lastRunYday[MAX_SCHEDULES];     // 今年第幾天執行過，避免同一天重複觸發
};
ScheduleConfig schedule;

// 排程時間到但狗狗正在使用時，延後而不是放棄 —— 但不能無限延後，
// 否則感測器卡住會讓清洗永遠不執行。
int8_t        pendingScheduleIndex = -1;
unsigned long pendingSince         = 0;
const unsigned long PENDING_MAX_MS = 20UL * 60UL * 1000UL;   // 最多延後 20 分鐘

// 這次沖水實際要跑幾秒。手動/自動用 flushDuration，排程用 schedule.durationSec。
int         activeFlushSeconds = 10;
const char* activeFlushReason  = "自動";

// ============================ 時間常數 ============================
const unsigned long VIB_RECENT_MS   = 500;    // 多久內的震動算「現在正在震」
const unsigned long FALSE_TRIG_MS   = 3000;   // DETECTING 期間靜止這麼久 = 誤觸
const unsigned long COOLDOWN_MS     = 8000;   // 沖水後的靜置期，避免水泵震動自我觸發
const unsigned long LED_BLINK_MS    = 500;
const unsigned long DIAG_PERIOD_MS  = 300000; // 5 分鐘回報一次診斷
const unsigned long OTA_WINDOW_MS   = 300000; // OTA 模式最多開 5 分鐘

// TLS 記憶體。Adafruit IO 已實測支援 MFLN 512，所以緩衝區可以開很小。
const int      TLS_RX_BUF      = 512;
const int      TLS_TX_BUF      = 512;
const uint32_t MIN_BLOCK_FOR_TLS = 14000;  // 連線前要求的最大連續區塊下限

// ============================ 狀態機 ============================
enum State { ST_IDLE, ST_DETECTING, ST_IN_USE, ST_FLUSHING, ST_COOLDOWN };
State currentState = ST_IDLE;

const char* stateName(State s) {
  switch (s) {
    case ST_IDLE:      return "idle";
    case ST_DETECTING: return "detecting";
    case ST_IN_USE:    return "inuse";
    case ST_FLUSHING:  return "flushing";
    case ST_COOLDOWN:  return "cooldown";
  }
  return "unknown";
}

volatile bool vibrationFlag = false;
unsigned long lastVibrationTime = 0;
unsigned long stateStartTime    = 0;
unsigned long lastLEDToggle     = 0;
bool          ledOn             = false;
bool          vibrationSeenInState = false;   // 這個狀態期間到底有沒有震動過

// ============================ 網路狀態機 ============================
enum NetState { NET_WIFI, NET_TIME, NET_MQTT, NET_ONLINE, NET_BACKOFF };
NetState      netState      = NET_WIFI;
unsigned long netTimer      = 0;
unsigned long backoffMs     = 5000;
unsigned long lastDiagTime  = 0;
uint8_t       mqttFailCount = 0;

// 全域配置，永不釋放 —— 反覆 new/delete TLS 物件是 ESP8266 記憶體碎片化的主因
BearSSL::X509List         rootCA(DIGICERT_GLOBAL_ROOT_G2);
BearSSL::WiFiClientSecure net;
BearSSL::Session          tlsSession;
MQTTClient                mqtt(512, 256);

// ============================ OTA ============================
bool          otaMode     = false;
unsigned long otaDeadline = 0;

// ============================ 中斷 ============================
void IRAM_ATTR onVibration() {
  vibrationFlag = true;
}

// ============================ 工具 ============================
//
// 注意：這一區是本檔第一個函式定義的所在，不要把函式往上搬到 enum State 之前。
// Arduino 的 .ino 前處理會自動產生所有函式原型，並插在「第一個函式定義之前」；
// 若上方出現函式定義，`stateName(State)` 的原型就會被插到 State 宣告之前，
// 整份檔案會以 "'State' was not declared in this scope" 爆掉。

/// 統一經過這裡控制水泵，避免極性處理散落在各個 digitalWrite。
static void pumpWrite(bool on) {
  digitalWrite(PIN_PUMP, (on != PUMP_ACTIVE_LOW) ? HIGH : LOW);
}

static int clampInt(int v, int lo, int hi) {
  return v < lo ? lo : (v > hi ? hi : v);
}

// 只有連線時才發布，離線時安靜失敗 —— 呼叫端不必到處檢查
static void pub(const char* topic, const char* payload) {
  if (mqtt.connected()) mqtt.publish(topic, payload, false, 1);
}

// DETECTING 是純粹的內部防抖狀態 —— 環境震動（走動、冰箱、感測器靈敏度過高）
// 會讓它在 idle/detecting 之間每分鐘來回好幾次。把這些送上雲端只會洗版，
// 而且會吃掉 Adafruit IO 免費版每分鐘 30 筆的配額。App 端也不需要知道。
// 這裡只回報「真的發生了事情」的狀態，並且濾掉重複值。
State lastPublishedState = ST_IDLE;

static void publishState(bool force = false) {
  if (!force) {
    if (currentState == ST_DETECTING) return;
    if (currentState == lastPublishedState) return;
  }
  lastPublishedState = currentState;
  pub(TOPIC(F_STATE), stateName(currentState));
}

// 回傳「現在幾點」的字串。NTP 還沒同步時回傳 uptime，不會謊報時間。
static String nowString() {
  time_t now = time(nullptr);
  if (now < 8 * 3600 * 2) {
    return String("uptime+") + String(millis() / 1000) + "s";
  }
  char buf[24];
  struct tm t;
  localtime_r(&now, &t);
  strftime(buf, sizeof(buf), "%Y-%m-%d %H:%M:%S", &t);
  return String(buf);
}

// ============================ 水泵 ============================
void startFlush(int seconds, const char* reason) {
  activeFlushSeconds = seconds;
  activeFlushReason  = reason;
  pendingScheduleIndex = -1;      // 已經開始沖了，取消任何等待中的排程

  currentState    = ST_FLUSHING;
  stateStartTime  = millis();
  lastLEDToggle   = millis();
  pumpWrite(true);
  Serial.printf("[flush] 開始沖水 %d 秒 (%s)\n", seconds, reason);
  publishState();
}

void stopFlush() {
  pumpWrite(false);
  digitalWrite(PIN_LED, HIGH);   // 熄滅
  ledOn = false;

  currentState   = ST_COOLDOWN;
  stateStartTime = millis();

  // 關鍵：把「上次震動」重設到現在。水泵運轉本身會讓 SW-420 一直觸發，
  // 若不重設，回到 IDLE 的瞬間就會因為「剛剛有震動」再次進入 DETECTING，
  // 形成無限沖水迴圈。
  lastVibrationTime = millis();

  Serial.println(F("[flush] 沖水結束，進入靜置期"));
  publishState();
  // 帶上觸發來源 —— 看紀錄時能分辨這次是狗狗用完自動沖、你手動沖、還是定時清洗
  pub(TOPIC(F_LASTFLUSH), (nowString() + " " + activeFlushReason).c_str());
}

// ============================ 感測器 ============================
void serviceSensor() {
  if (vibrationFlag) {
    vibrationFlag        = false;
    lastVibrationTime    = millis();
    vibrationSeenInState = true;
  }
}

static bool vibratingNow() {
  return (millis() - lastVibrationTime) < VIB_RECENT_MS;
}

// ============================ 主狀態機 ============================
void runStateMachine() {
  const unsigned long now = millis();

  switch (currentState) {
    case ST_IDLE:
      if (vibratingNow()) {
        currentState         = ST_DETECTING;
        stateStartTime       = now;
        vibrationSeenInState = false;
        Serial.println(F("[state] 偵測到活動"));
        publishState();
      }
      break;

    case ST_DETECTING:
      // 靜止太久 = 誤觸（狗狗只是路過碰一下）
      if ((now - lastVibrationTime) > FALSE_TRIG_MS) {
        currentState   = ST_IDLE;
        stateStartTime = now;
        Serial.println(F("[state] 誤觸，回到閒置"));
        publishState();
        break;
      }
      // 原版只看「進入這個狀態多久」，即使震動早就停了也會誤判成使用中。
      // 這裡額外要求「此刻仍在震動」才升級成 IN_USE。
      if ((now - stateStartTime) >= (unsigned long)entryThreshold * 1000UL && vibratingNow()) {
        currentState   = ST_IN_USE;
        stateStartTime = now;
        Serial.println(F("[state] 白白使用中"));
        publishState();
      }
      break;

    case ST_IN_USE:
      if ((now - lastVibrationTime) >= (unsigned long)exitThreshold * 1000UL) {
        Serial.println(F("[state] 判定已離開"));
        startFlush(flushDuration, "自動");
      }
      break;

    case ST_FLUSHING:
      if (now - lastLEDToggle >= LED_BLINK_MS) {
        ledOn = !ledOn;
        digitalWrite(PIN_LED, ledOn ? LOW : HIGH);
        lastLEDToggle = now;
      }
      if ((now - stateStartTime) >= (unsigned long)activeFlushSeconds * 1000UL) {
        stopFlush();
      }
      break;

    case ST_COOLDOWN:
      // 靜置期間完全忽略震動，讓水泵餘振與水流聲平息
      lastVibrationTime = now;
      if ((now - stateStartTime) >= COOLDOWN_MS) {
        currentState   = ST_IDLE;
        stateStartTime = now;
        Serial.println(F("[state] 靜置結束，回到閒置"));
        publishState();
      }
      break;
  }
}

// ============================ 定時清洗排程 ============================
//
// 排程放在裝置端而不是 App 端：手機關機、不在身邊、或 App 沒開的時候，
// 清洗還是必須照常執行。裝置已經有 NTP 校時（台北時區），自己跑排程才可靠。
//
// 設定格式（來自 schedule feed）：
//   {"on":true,"dur":120,"times":["08:00","14:00","20:00"]}

bool parseSchedule(const String& payload) {
  JsonDocument doc;
  if (deserializeJson(doc, payload)) {
    Serial.println(F("[sched] JSON 解析失敗，維持原設定"));
    return false;
  }

  ScheduleConfig s;
  s.enabled     = doc["on"] | false;
  s.durationSec = clampInt(doc["dur"] | 120, SCHED_DUR_MIN, SCHED_DUR_MAX);

  for (JsonVariant v : doc["times"].as<JsonArray>()) {
    if (s.count >= MAX_SCHEDULES) break;
    const char* t = v.as<const char*>();
    if (!t) continue;
    int hh = -1, mm = -1;
    if (sscanf(t, "%d:%d", &hh, &mm) != 2) continue;
    if (hh < 0 || hh > 23 || mm < 0 || mm > 59) continue;
    s.minuteOfDay[s.count] = (uint16_t)(hh * 60 + mm);
    s.lastRunYday[s.count] = -1;
    s.count++;
  }

  // 沿用相同時間點的「今天已執行」紀錄。否則只是改個時長就會讓已經跑過的
  // 排程在同一天再跑一次。
  for (int i = 0; i < s.count; i++) {
    for (int j = 0; j < schedule.count; j++) {
      if (schedule.minuteOfDay[j] == s.minuteOfDay[i]) {
        s.lastRunYday[i] = schedule.lastRunYday[j];
        break;
      }
    }
  }

  schedule = s;
  Serial.printf("[sched] 已套用：啟用=%d 時長=%ds 次數=%d\n",
                schedule.enabled, schedule.durationSec, schedule.count);
  return true;
}

void checkSchedule() {
  if (!schedule.enabled || schedule.count == 0) return;

  const time_t now = time(nullptr);
  if (now < 8 * 3600 * 2) return;          // NTP 還沒同步，時間不可信

  struct tm t;
  localtime_r(&now, &t);
  const uint16_t nowMinute = (uint16_t)(t.tm_hour * 60 + t.tm_min);

  // 先處理因為狗狗正在使用而延後的排程
  if (pendingScheduleIndex >= 0) {
    if (millis() - pendingSince > PENDING_MAX_MS) {
      Serial.println(F("[sched] 延後逾時，放棄本次清洗"));
      pendingScheduleIndex = -1;
    } else if (currentState == ST_IDLE) {
      schedule.lastRunYday[pendingScheduleIndex] = (int16_t)t.tm_yday;
      Serial.println(F("[sched] 狗狗已離開，執行延後的清洗"));
      startFlush(schedule.durationSec, "排程");
    }
    return;
  }

  for (int i = 0; i < schedule.count; i++) {
    if (schedule.minuteOfDay[i] != nowMinute) continue;
    if (schedule.lastRunYday[i] == (int16_t)t.tm_yday) continue;
    // 只在該分鐘的前 20 秒內觸發。「今天已執行」的紀錄只存在 RAM，
    // 裝置若在這一分鐘內重開機就會遺失；窄窗口能大幅降低重複沖水的機率。
    if (t.tm_sec >= 20) continue;

    if (currentState == ST_IDLE) {
      schedule.lastRunYday[i] = (int16_t)t.tm_yday;
      startFlush(schedule.durationSec, "排程");
    } else {
      Serial.printf("[sched] %02d:%02d 時間到，但目前是 %s，延後執行\n",
                    schedule.minuteOfDay[i] / 60, schedule.minuteOfDay[i] % 60,
                    stateName(currentState));
      pendingScheduleIndex = (int8_t)i;
      pendingSince         = millis();
    }
    return;
  }
}

// ============================ MQTT ============================
void enterOtaMode();

void onMqttMessage(String &topic, String &payload) {
  Serial.printf("[mqtt] %s = %s\n", topic.c_str(), payload.c_str());

  if (topic.endsWith("/" F_FLUSH)) {
    if (payload.toInt() == 1) {
      if (currentState == ST_IDLE) {
        Serial.println(F("[mqtt] 手動沖水"));
        startFlush(flushDuration, "手動");
      } else {
        Serial.printf("[mqtt] 忽略手動沖水，目前狀態 %s\n", stateName(currentState));
      }
    }
  } else if (topic.endsWith("/" F_ENTRY)) {
    entryThreshold = clampInt(payload.toInt(), ENTRY_MIN, ENTRY_MAX);
  } else if (topic.endsWith("/" F_EXIT)) {
    exitThreshold = clampInt(payload.toInt(), EXIT_MIN, EXIT_MAX);
  } else if (topic.endsWith("/" F_DURATION)) {
    flushDuration = clampInt(payload.toInt(), DUR_MIN, DUR_MAX);
  } else if (topic.endsWith("/" F_SCHEDULE)) {
    parseSchedule(payload);
  } else if (topic.endsWith("/" F_OTA)) {
    if (payload.toInt() == 1) enterOtaMode();
  }
}

void publishDiag() {
  JsonDocument doc;
  doc["fw"]       = FW_VERSION;
  doc["proto"]    = PROTOCOL_VERSION;
  doc["heap"]     = ESP.getFreeHeap();
  doc["maxblock"] = ESP.getMaxFreeBlockSize();
  doc["frag"]     = ESP.getHeapFragmentation();
  doc["rssi"]     = WiFi.RSSI();
  doc["uptime"]   = millis() / 1000;
  // 回報 IP 讓 OTA 工具找得到裝置。mDNS 不能用來做這件事 ——
  // ArduinoOTA 的 mDNS 只在 OTA 模式下才啟動，平常查不到 pettoilet.local。
  doc["ip"]       = WiFi.localIP().toString();
  doc["mfln"]     = net.getMFLNStatus();
  doc["state"]    = stateName(currentState);
  // 回報「實際套用」的參數而不是收到的原始值 —— App 傳來的值會被夾在上下界內，
  // 這樣才看得出防呆有沒有生效，也方便 App 開啟時同步顯示真實設定。
  doc["entry"]    = entryThreshold;
  doc["exit"]     = exitThreshold;
  doc["dur"]      = flushDuration;
  // 排程的實際套用狀態。不回發到 schedule feed 本身 —— 我們有訂閱它，
  // 發回去會被 broker 原樣送回來，造成解析→發布→解析的無限迴圈。
  doc["sch_on"]   = schedule.enabled;
  doc["sch_dur"]  = schedule.durationSec;
  JsonArray times = doc["sch_t"].to<JsonArray>();
  for (int i = 0; i < schedule.count; i++) {
    // 緩衝區給到 8 而非剛好的 6：編譯器無法證明 minuteOfDay/60 一定 ≤ 23
    // （型別是 uint16_t），會對 %02d 可能寫出 2 位以上發出截斷警告。
    char hhmm[8];
    snprintf(hhmm, sizeof(hhmm), "%02d:%02d",
             schedule.minuteOfDay[i] / 60, schedule.minuteOfDay[i] % 60);
    times.add(hhmm);
  }

  char buf[384];
  serializeJson(doc, buf, sizeof(buf));
  pub(TOPIC(F_DIAG), buf);
  Serial.printf("[diag] %s\n", buf);
}

bool connectMqtt() {
  // TLS 交握的峰值需求遠高於穩態。連續區塊不足時硬連只會 OOM 重開機，
  // 不如直接放棄這一輪、等下次重試。
  const uint32_t block = ESP.getMaxFreeBlockSize();
  if (block < MIN_BLOCK_FOR_TLS) {
    Serial.printf("[mqtt] 記憶體不足 (maxblock=%u)，跳過本輪\n", block);
    return false;
  }

  Serial.printf("[mqtt] 連線中… heap=%u block=%u\n", ESP.getFreeHeap(), block);

  String clientId = "pettoilet-" + String(ESP.getChipId(), HEX);
  if (!mqtt.connect(clientId.c_str(), AIO_USERNAME, AIO_KEY)) {
    Serial.printf("[mqtt] 連線失敗 err=%d\n", (int)mqtt.lastError());
    return false;
  }

  Serial.printf("[mqtt] 已連線 MFLN=%d heap=%u\n", net.getMFLNStatus(), ESP.getFreeHeap());

  mqtt.subscribe(TOPIC(F_FLUSH), 1);
  mqtt.subscribe(TOPIC(F_ENTRY), 1);
  mqtt.subscribe(TOPIC(F_EXIT), 1);
  mqtt.subscribe(TOPIC(F_DURATION), 1);
  mqtt.subscribe(TOPIC(F_SCHEDULE), 1);
  mqtt.subscribe(TOPIC(F_OTA), 1);

  // Adafruit IO 不支援 MQTT 的 retain flag，改用 /get 取回最後一筆值。
  // 這樣重開機後參數會自動還原成 App 上次設定的值，不會退回程式碼裡的預設。
  mqtt.publish(TOPIC_GET(F_ENTRY), "");
  mqtt.publish(TOPIC_GET(F_EXIT), "");
  mqtt.publish(TOPIC_GET(F_DURATION), "");
  mqtt.publish(TOPIC_GET(F_SCHEDULE), "");

  publishState(true);   // 剛連上線，無論如何都要讓 App 知道目前狀態
  publishDiag();
  lastDiagTime = millis();
  return true;
}

void serviceNetwork() {
  const unsigned long now = millis();

  switch (netState) {
    case NET_WIFI:
      if (WiFi.status() == WL_CONNECTED) {
        Serial.printf("[wifi] 已連線 %s\n", WiFi.localIP().toString().c_str());
        configTime(TZ_Asia_Taipei, "pool.ntp.org", "time.google.com");
        netState = NET_TIME;
        netTimer = now;
      }
      break;

    case NET_TIME:
      // x.509 憑證驗證需要正確的系統時間，NTP 沒同步完成前連 TLS 一定失敗
      if (time(nullptr) > 8 * 3600 * 2) {
        Serial.printf("[time] 已同步 %s\n", nowString().c_str());
        netState = NET_MQTT;
      } else if (now - netTimer > 30000) {
        Serial.println(F("[time] NTP 逾時，重試"));
        netState = NET_WIFI;
      }
      break;

    case NET_MQTT:
      if (WiFi.status() != WL_CONNECTED) { netState = NET_WIFI; break; }
      if (connectMqtt()) {
        netState      = NET_ONLINE;
        backoffMs     = 5000;
        mqttFailCount = 0;
      } else {
        netState = NET_BACKOFF;
        netTimer = now;
        if (++mqttFailCount >= 10) {
          Serial.println(F("[mqtt] 連續失敗 10 次，重新開機"));
          ESP.restart();
        }
      }
      break;

    case NET_ONLINE:
      if (WiFi.status() != WL_CONNECTED) {
        Serial.println(F("[wifi] 斷線"));
        mqtt.disconnect();
        net.stop();
        netState = NET_WIFI;
        break;
      }
      if (!mqtt.connected()) {
        Serial.println(F("[mqtt] 斷線"));
        net.stop();
        netState = NET_BACKOFF;
        netTimer = now;
        break;
      }
      if (now - lastDiagTime >= DIAG_PERIOD_MS) {
        publishDiag();
        lastDiagTime = now;
      }
      break;

    case NET_BACKOFF:
      if (now - netTimer >= backoffMs) {
        backoffMs = min(backoffMs * 2, 120000UL);   // 指數退避，上限 2 分鐘
        netState  = NET_MQTT;
      }
      break;
  }
}

// ============================ OTA ============================
void enterOtaMode() {
  // 水泵絕不能在 OTA 期間留在開啟狀態 —— 更新中重開機會讓它一直抽水
  pumpWrite(false);
  currentState = ST_IDLE;

  Serial.println(F("[ota] 進入 OTA 模式"));
  pub(TOPIC(F_STATE), "ota");

  // ESP8266 的記憶體放不下「TLS MQTT」與「OTA」同時存在。
  // mqtt.disconnect() 只關 MQTT 層，必須再呼叫 net.stop() 才會真正釋放
  // BearSSL 的緩衝區。
  mqtt.disconnect();
  net.stop();
  delay(200);

  Serial.printf("[ota] 釋放 TLS 後 heap=%u block=%u\n",
                ESP.getFreeHeap(), ESP.getMaxFreeBlockSize());

  ArduinoOTA.setHostname("pettoilet");
  ArduinoOTA.setPassword(OTA_PASSWORD);
  ArduinoOTA.onStart([]() {
    Serial.println(F("[ota] 開始接收韌體"));
    pumpWrite(false);
  });
  ArduinoOTA.onEnd([]() { Serial.println(F("[ota] 完成，重新開機")); });
  ArduinoOTA.onError([](ota_error_t e) {
    Serial.printf("[ota] 錯誤 %u\n", e);
    // 認證失敗只是密碼打錯，留在 OTA 模式讓人重試就好；重開機會逼使用者
    // 從頭再走一次「發 MQTT 指令 -> 等待進入 OTA」的流程，太難用。
    // 其他錯誤（接收中斷、寫入失敗）代表 flash 可能已經寫壞，必須重開。
    if (e != OTA_AUTH_ERROR) ESP.restart();
  });
  ArduinoOTA.begin();

  otaMode     = true;
  otaDeadline = millis() + OTA_WINDOW_MS;
  netState    = NET_BACKOFF;
}

void serviceOta() {
  ArduinoOTA.handle();

  // OTA 模式下 LED 快閃，跟沖水的慢閃區分開
  if (millis() - lastLEDToggle >= 150) {
    ledOn = !ledOn;
    digitalWrite(PIN_LED, ledOn ? LOW : HIGH);
    lastLEDToggle = millis();
  }

  // 沒人來燒錄就重開機回到正常運作，不要一直卡在 OTA 模式
  if ((long)(millis() - otaDeadline) >= 0) {
    Serial.println(F("[ota] 視窗逾時，重新開機"));
    ESP.restart();
  }
}

// ============================ setup / loop ============================
void setup() {
  // 先把水泵關掉再做任何事 —— 開機瞬間腳位狀態不確定
  pinMode(PIN_PUMP, OUTPUT);
  pumpWrite(false);

  pinMode(PIN_LED, OUTPUT);
  digitalWrite(PIN_LED, HIGH);   // ESP8266 板載 LED 是低電位點亮，HIGH = 熄滅

  Serial.begin(115200);
  Serial.println();
  Serial.printf("\n=== PetToilet %s ===\n", FW_VERSION);
  Serial.printf("開機 heap=%u\n", ESP.getFreeHeap());

  pinMode(PIN_VIBRATION, INPUT);
  attachInterrupt(digitalPinToInterrupt(PIN_VIBRATION), onVibration, RISING);

  // 開機時把「上次震動」設在遠方，否則 millis() 還很小時
  // (millis() - 0) < 500 會成立，一開機就假觸發。
  lastVibrationTime = millis() - VIB_RECENT_MS - 1;
  stateStartTime    = millis();

  // TLS：釘住根憑證（不是葉憑證指紋，Adafruit 的葉憑證每半年就換一次）
  net.setTrustAnchors(&rootCA);
  net.setSession(&tlsSession);          // 加速重連，省下一次完整交握
  net.setBufferSizes(TLS_RX_BUF, TLS_TX_BUF);   // 已實測 Adafruit IO 支援 MFLN

  mqtt.begin(AIO_HOST, AIO_PORT, net);
  mqtt.onMessage(onMqttMessage);
  mqtt.setKeepAlive(60);                // 預設 15 秒對 TLS 太頻繁
  mqtt.setTimeout(15000);
  mqtt.setWill(TOPIC(F_STATE), "offline", false, 1);

  WiFi.mode(WIFI_STA);
  WiFi.persistent(false);
  WiFi.setAutoReconnect(true);
  WiFi.hostname("pettoilet");
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);
  // 這裡刻意不等待連線完成。沖水是這台裝置的本職，不該因為 WiFi 連不上就停擺。
}

void loop() {
  if (otaMode) {
    serviceOta();
    return;
  }

  serviceSensor();
  runStateMachine();
  checkSchedule();
  serviceNetwork();

  if (netState == NET_ONLINE) mqtt.loop();

  delay(10);   // arduino-mqtt 在 ESP8266 上的建議做法，讓出時間給 WiFi 堆疊
}
