// 把 PNG 的 alpha 通道攤平到白色背景。
//
//   swiftc -O 02_Tools/flatten_png.swift -o /tmp/flatten_png
//   /tmp/flatten_png in.png out.png
//
// 為什麼需要：App Store 對截圖明文要求
// 「Images can't include alpha channels or transparencies」，
// 而 `xcrun simctl io ... screenshot` 產出的 PNG 一律帶 alpha。
// `sips` 的格式選項不會移除 alpha，必須真的重新繪製一次。

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 3 else {
    FileHandle.standardError.write(Data("用法: flatten_png <輸入.png> <輸出.png>\n".utf8))
    exit(2)
}
let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])

guard let source = CGImageSourceCreateWithURL(inputURL as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    FileHandle.standardError.write(Data("無法讀取 \(inputURL.path)\n".utf8))
    exit(1)
}

// noneSkipLast = 每像素仍是 32 bits，但最後 8 bits 被忽略而非當成 alpha，
// 因此輸出的 PNG 不含 alpha 通道。
guard let ctx = CGContext(
    data: nil, width: image.width, height: image.height,
    bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
else {
    FileHandle.standardError.write(Data("無法建立繪圖環境\n".utf8))
    exit(1)
}

let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
ctx.fill(rect)
ctx.draw(image, in: rect)

guard let flattened = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(
        outputURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    FileHandle.standardError.write(Data("無法建立輸出檔\n".utf8))
    exit(1)
}
CGImageDestinationAddImage(dest, flattened, nil)
guard CGImageDestinationFinalize(dest) else {
    FileHandle.standardError.write(Data("寫入失敗\n".utf8))
    exit(1)
}

print("\(outputURL.lastPathComponent)  \(image.width)×\(image.height)  已移除 alpha")
