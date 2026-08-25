#!/bin/bash
#
# 產生 App Store 上架用的螢幕截圖。
#
#   bash 02_Tools/make_screenshots.sh
#
# 產出 04_AppStore/screenshots/*.png，規格為 iPhone 6.9"（1320×2868、無 alpha）。
#
# 兩個實作上的注意事項：
#   1. 模擬器沒有捲動指令，所以改用「暫時把目標區塊移到清單最上方，拍完還原」
#      的方式逐張拍攝。腳本結束前一定會還原 ContentView.swift。
#   2. `xcrun simctl io ... screenshot` 產出的 PNG 一律帶 alpha 通道，但 App Store
#      明文禁止（"Images can't include alpha channels or transparencies"）。
#      sips 的格式選項不會移除它，必須用 flatten_png 重新繪製一次。

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJ="$ROOT/03_iOS/PetToilet"
OUT="$ROOT/04_AppStore/screenshots"
TMP="$(mktemp -d)"
DEVICE="iPhone 17 Pro Max"          # 6.9" → 1320×2868
BUNDLE="com.agwill.PetToilet"
VIEW="$PROJ/PetToilet/ContentView.swift"

mkdir -p "$OUT"
cp "$VIEW" "$TMP/ContentView.orig.swift"

# 無論成功失敗都要還原原始檔，否則會把暫時的區塊順序留在程式碼裡
restore() { cp "$TMP/ContentView.orig.swift" "$VIEW"; }
trap restore EXIT

# 用真實裝置的資料截圖（活動紀錄才有內容）。沒有 secrets.h 時會自動落入 Demo 模式。
SECRETS="$ROOT/01_Arduino/PetToilet/secrets.h"
if [ -f "$SECRETS" ]; then
  export SIMCTL_CHILD_AIO_USER=$(/usr/bin/python3 -c "
import re;print(re.search(r'^#define\s+AIO_USERNAME\s+\"([^\"]*)\"',open('$SECRETS').read(),re.M).group(1))")
  export SIMCTL_CHILD_AIO_KEY=$(/usr/bin/python3 -c "
import re;print(re.search(r'^#define\s+AIO_KEY\s+\"([^\"]*)\"',open('$SECRETS').read(),re.M).group(1))")
fi

ORDER_DEFAULT='                statusSection
                controlSection
                settingsSection
                scheduleSection
                if showDiagnostics { diagnosticsSection }
                activitySection'

swiftc -O "$ROOT/02_Tools/flatten_png.swift" -o "$TMP/flatten_png"
xcrun simctl boot "$DEVICE" 2>/dev/null || true
xcrun simctl bootstatus "$DEVICE" -b >/dev/null 2>&1

shoot() {  # $1=輸出名  $2=區塊順序
  /usr/bin/python3 -c "
p='$VIEW'
s=open(p).read()
s=s.replace('''$ORDER_DEFAULT''','''$2''')
open(p,'w').write(s)"

  (cd "$PROJ" && xcodebuild build -project PetToilet.xcodeproj -scheme PetToilet \
     -destination "platform=iOS Simulator,name=$DEVICE" \
     -derivedDataPath "$TMP/DD" CODE_SIGNING_ALLOWED=NO >/dev/null 2>&1)

  xcrun simctl terminate "$DEVICE" "$BUNDLE" >/dev/null 2>&1 || true
  xcrun simctl install "$DEVICE" "$TMP/DD/Build/Products/Debug-iphonesimulator/PetToilet.app"
  xcrun simctl launch "$DEVICE" "$BUNDLE" >/dev/null
  sleep 11                                   # 等連線、回填歷史、模擬事件產生
  xcrun simctl io "$DEVICE" screenshot "$TMP/raw_$1.png" >/dev/null 2>&1
  "$TMP/flatten_png" "$TMP/raw_$1.png" "$OUT/$1.png"
  restore
}

shoot 1_status "$ORDER_DEFAULT"
shoot 2_settings '                settingsSection
                statusSection
                controlSection
                scheduleSection
                if showDiagnostics { diagnosticsSection }
                activitySection'
shoot 3_schedule '                scheduleSection
                statusSection
                controlSection
                settingsSection
                if showDiagnostics { diagnosticsSection }
                activitySection'
shoot 4_activity '                activitySection
                statusSection
                controlSection
                settingsSection
                scheduleSection
                if showDiagnostics { diagnosticsSection }'

echo
echo "完成，輸出於 $OUT"
for f in "$OUT"/*.png; do
  printf "  %-16s " "$(basename "$f")"
  sips -g pixelWidth -g pixelHeight -g hasAlpha "$f" 2>/dev/null | tail -3 \
    | tr -d ' \n' | sed 's/pixelWidth:/W=/;s/pixelHeight:/  H=/;s/hasAlpha:/  alpha=/'
  echo
done
