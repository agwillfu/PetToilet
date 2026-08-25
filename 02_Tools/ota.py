#!/usr/bin/env python3
"""
PetToilet 無線更新工具

一鍵完成：編譯 -> 透過 MQTT 叫裝置進入 OTA 模式 -> 從 WiFi 燒錄 -> 驗證版本

用法：
    python3 02_Tools/ota.py                    # 自動探測裝置 IP
    python3 02_Tools/ota.py --ip 10.20.30.181  # 指定 IP
    python3 02_Tools/ota.py --no-build         # 跳過編譯，用現有的 build/

裝置 IP 會變（DHCP）。找不到時去路由器看，或插 USB 用序列埠看開機訊息。
建議在路由器上把 pettoilet 設成固定 IP。
"""

import argparse
import json
import os
import re
import subprocess
import sys
import time
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SKETCH = os.path.join(ROOT, "01_Arduino", "PetToilet")
BUILD = os.path.join(ROOT, "build")
SECRETS = os.path.join(SKETCH, "secrets.h")

FQBN = "esp8266:esp8266:nodemcuv2:eesz=4M2M,ip=lm2f,xtal=160"
ARDUINO_CLI = os.path.expanduser("~/.local/bin/arduino-cli")
ESPOTA = os.path.expanduser(
    "~/Library/Arduino15/packages/esp8266/hardware/esp8266/3.1.2/tools/espota.py")


def secret(name):
    """從 secrets.h 讀值。用 re.M 錨定行首，否則會誤抓到註解裡提及的同名字串。"""
    src = open(SECRETS).read()
    m = re.search(r'^#define\s+%s\s+"([^"]*)"' % name, src, re.M)
    if not m:
        sys.exit("secrets.h 裡找不到 %s" % name)
    return m.group(1)


def aio(path, payload=None):
    user, key = secret("AIO_USERNAME"), secret("AIO_KEY")
    req = urllib.request.Request(
        "https://io.adafruit.com/api/v2/%s/%s" % (user, path),
        data=json.dumps(payload).encode() if payload else None,
        headers={"X-AIO-Key": key, "Content-Type": "application/json"},
        method="POST" if payload else "GET")
    return json.load(urllib.request.urlopen(req, timeout=20))


def firmware_version():
    """從原始碼讀 FW_VERSION，用來確認 OTA 之後跑的真的是新版。"""
    m = re.search(r'#define\s+FW_VERSION\s+"([^"]*)"',
                  open(os.path.join(SKETCH, "PetToilet.ino")).read())
    return m.group(1) if m else None


def discover_ip():
    """從 diag feed 讀裝置自己回報的 IP。

    不能用 mDNS (pettoilet.local)：ArduinoOTA 的 mDNS 只在裝置進入 OTA 模式後
    才啟動，平常是查不到的 —— 而我們需要在觸發 OTA 之前就知道位址。
    """
    try:
        d = json.loads(aio("feeds/diag/data?limit=1")[0]["value"])
        return d.get("ip")
    except Exception:
        return None


def local_subnets():
    """本機各介面的 IPv4 位址與遮罩。"""
    out = subprocess.run(["ifconfig"], capture_output=True, text=True).stdout
    found = []
    for m in re.finditer(r"inet (\d+\.\d+\.\d+\.\d+) netmask (0x[0-9a-f]+)", out):
        ip, mask = m.group(1), int(m.group(2), 16)
        if ip.startswith("127."):
            continue
        found.append((ip, mask))
    return found


def same_network(device_ip):
    """裝置是否與本機在同一個子網。

    ArduinoOTA 是純區網協定，燒錄封包直接送到裝置 IP，跨網段不會通。
    最常見的情況是 Mac 連到了手機熱點而裝置還在家裡的 Wi-Fi —— 這時雲端
    那條路照常運作（雙方各自連得到網際網路），只有 OTA 會失敗，
    錯誤訊息卻只有一句看不懂的 "No Answer"。
    """
    def to_int(ip):
        a, b, c, d = (int(x) for x in ip.split("."))
        return (a << 24) | (b << 16) | (c << 8) | d

    target = to_int(device_ip)
    for ip, mask in local_subnets():
        if (to_int(ip) & mask) == (target & mask):
            return True, ip
    return False, None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ip", help="裝置 IP，省略則自動探測")
    ap.add_argument("--no-build", action="store_true", help="跳過編譯")
    args = ap.parse_args()

    target = firmware_version()
    print("目標版本: %s" % target)

    if not args.no_build:
        print("\n[1/4] 編譯…")
        r = subprocess.run([ARDUINO_CLI, "compile", "--fqbn", FQBN,
                            "--warnings", "all", "--output-dir", BUILD, SKETCH],
                           capture_output=True, text=True)
        if r.returncode != 0:
            print(r.stdout[-3000:], r.stderr[-3000:])
            sys.exit("編譯失敗")
        for line in r.stdout.splitlines():
            if "used" in line and "bytes" in line:
                print("   " + line.strip())
    else:
        print("\n[1/4] 略過編譯")

    binpath = os.path.join(BUILD, "PetToilet.ino.bin")
    if not os.path.exists(binpath):
        sys.exit("找不到 %s" % binpath)

    ip = args.ip or discover_ip()
    if not ip:
        sys.exit("找不到裝置 IP。請用 --ip 指定，或到路由器查 hostname 'pettoilet'。")
    print("\n[2/4] 裝置位址: %s" % ip)

    reachable, via = same_network(ip)
    if not reachable:
        mine = ", ".join(a for a, _ in local_subnets()) or "（沒有可用的網路介面）"
        sys.exit(
            "\n❌ 這台電腦與裝置不在同一個網路，ArduinoOTA 無法燒錄。\n"
            "   裝置 IP : %s\n"
            "   本機 IP : %s\n\n"
            "   最常見的原因是 Mac 連到了手機熱點（172.20.10.x）而裝置還在家裡的\n"
            "   Wi-Fi。雲端控制不受影響，但無線燒錄必須在同一個區網。\n"
            "   請把 Mac 連回家裡的 Wi-Fi 後重試。" % (ip, mine))
    print("      本機 %s，與裝置同網段 ✓" % via)

    print("\n[3/4] 送出 OTA 指令，等待裝置釋放 TLS…")
    aio("feeds/ota/data", {"value": "1"})
    # 裝置要先斷開 MQTT、呼叫 net.stop() 釋放 BearSSL 緩衝區，才有記憶體跑 OTA。
    # 太早連過去會收到 No Answer。
    time.sleep(7)

    print("\n[4/4] 從 WiFi 燒錄…")
    r = subprocess.run([sys.executable, ESPOTA, "-i", ip, "-p", "8266",
                        "-a", secret("OTA_PASSWORD"), "-f", binpath, "-r"],
                       capture_output=True, text=True)
    out = r.stdout + r.stderr
    if "Result: OK" not in out and r.returncode != 0:
        print(out[-2000:])
        aio("feeds/ota/data", {"value": "0"})
        sys.exit("OTA 失敗")
    print("   傳輸完成，等待重新開機…")

    for _ in range(9):
        time.sleep(10)
        try:
            d = json.loads(aio("feeds/diag/data?limit=1")[0]["value"])
        except Exception:
            continue
        if d.get("fw") == target:
            print("\n✅ %s 已上線" % target)
            print("   heap=%d maxblock=%d frag=%d%% mfln=%d rssi=%d"
                  % (d["heap"], d["maxblock"], d["frag"], d["mfln"], d["rssi"]))
            print("   entry=%ds exit=%ds dur=%ds" % (d["entry"], d["exit"], d["dur"]))
            break
        print("   等待中… (目前回報 %s)" % d.get("fw"))
    else:
        print("\n⚠️ 逾時未收到新版回報。裝置每 5 分鐘才發一次 diag，可能只是還沒到時間。")

    aio("feeds/ota/data", {"value": "0"})


if __name__ == "__main__":
    main()
