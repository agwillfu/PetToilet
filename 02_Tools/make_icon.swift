// PetToilet App 圖示產生器
//
//   swiftc -O 02_Tools/make_icon.swift -o /tmp/make_icon && /tmp/make_icon <輸出路徑.png>
//
// 程式化繪製而不是用圖檔：調色、改比例只要改下面的參數重跑，
// 而且產出保證是 1024×1024 無 alpha（App Store 的硬性要求）。

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let size: CGFloat = 1024

// 水藍 → 青綠漸層。避開純藍是因為太多 App 用，這個帶青的色偏在圖示牆上比較跳。
let topColor    = CGColor(red: 0.11, green: 0.55, blue: 0.92, alpha: 1)
let bottomColor = CGColor(red: 0.05, green: 0.76, blue: 0.78, alpha: 1)

guard let ctx = CGContext(
    data: nil, width: Int(size), height: Int(size),
    bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
else { fatalError("無法建立繪圖環境") }

// MARK: - 背景漸層

let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                          colors: [topColor, bottomColor] as CFArray,
                          locations: [0, 1])!
ctx.drawLinearGradient(gradient,
                       start: CGPoint(x: 0, y: size),
                       end: CGPoint(x: size, y: 0),
                       options: [])

// MARK: - 水波紋
//
// 放在狗掌後方當背景層次。透明度壓得很低，縮到 40px 時不該搶掉主體。

ctx.setLineWidth(14)
for (index, radius) in [330.0, 420.0, 510.0].enumerated() {
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.16 - Double(index) * 0.04))
    ctx.strokeEllipse(in: CGRect(x: size / 2 - radius, y: size / 2 - radius - 40,
                                 width: radius * 2, height: radius * 2))
}

// MARK: - 狗掌

ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))

/// 畫一個可旋轉的橢圓。CoreGraphics 沒有現成 API，用 transform 包起來。
func ellipse(cx: CGFloat, cy: CGFloat, w: CGFloat, h: CGFloat, rotationDegrees: CGFloat) {
    ctx.saveGState()
    ctx.translateBy(x: cx, y: cy)
    ctx.rotate(by: rotationDegrees * .pi / 180)
    ctx.fillEllipse(in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
    ctx.restoreGState()
}

// 掌墊。稍微扁一點比較像狗掌，圓形會像貓。
ellipse(cx: 512, cy: 380, w: 420, h: 330, rotationDegrees: 0)

// 四個腳趾，沿弧線排列並各自向外傾斜
let toes: [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)] = [
    // cx,  cy,  w,   h,   角度
    (286,  560, 150, 205, 26),
    (430,  672, 158, 220, 9),
    (594,  672, 158, 220, -9),
    (738,  560, 150, 205, -26),
]
for (cx, cy, w, h, angle) in toes {
    ellipse(cx: cx, cy: cy, w: w, h: h, rotationDegrees: angle)
}

// MARK: - 水滴
//
// 這是圖示的敘事重點：不只是「寵物」，而是「寵物 + 水」。
//
// 兩個容易畫錯的地方：
//   1. CoreGraphics 的 y 軸向上，`clockwise: true` 從 π 到 0 走的是「上半圓」。
//      水滴要圓底尖頂，需要下半圓，所以是 clockwise: false。
//   2. 不要用 .copy 混合模式挖空 —— 它會用單一顏色蓋掉底下的漸層，
//      只要形狀超出白色掌墊一點點就會露出色差。這裡整個水滴都在掌墊範圍內，
//      用一般混合直接畫藍色就好。

let dropCenterX: CGFloat = 512
let circleCenterY: CGFloat = 332      // 圓底部分的圓心
let dropRadius: CGFloat = 66
let tipY: CGFloat = 508               // 尖端，必須落在掌墊內（掌墊上緣 545）

ctx.setFillColor(CGColor(red: 0.10, green: 0.60, blue: 0.90, alpha: 1))

let drop = CGMutablePath()
drop.addArc(center: CGPoint(x: dropCenterX, y: circleCenterY),
            radius: dropRadius, startAngle: .pi, endAngle: 0, clockwise: false)
drop.addQuadCurve(to: CGPoint(x: dropCenterX, y: tipY),
                  control: CGPoint(x: dropCenterX + dropRadius * 0.62,
                                   y: circleCenterY + (tipY - circleCenterY) * 0.52))
drop.addQuadCurve(to: CGPoint(x: dropCenterX - dropRadius, y: circleCenterY),
                  control: CGPoint(x: dropCenterX - dropRadius * 0.62,
                                   y: circleCenterY + (tipY - circleCenterY) * 0.52))
drop.closeSubpath()
ctx.addPath(drop)
ctx.fillPath()

// MARK: - 輸出

let outputPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "AppIcon.png"

guard let image = ctx.makeImage() else { fatalError("無法產生影像") }
let url = URL(fileURLWithPath: outputPath)
guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
else { fatalError("無法建立輸出檔") }
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("寫入失敗") }

print("已產生 \(outputPath)（\(Int(size))×\(Int(size))，無 alpha）")
