#!/usr/bin/env swift
import Foundation

// 创建一个 1024x1024 的麦克风图标
let size = 1024
let iconSize = CGSize(width: size, height: size)

// 创建 RGB 颜色空间
let colorSpace = CGColorSpaceCreateDeviceRGB()
let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

// 创建位图上下文
guard let context = CGContext(data: nil,
                            width: size,
                            height: size,
                            bitsPerComponent: 8,
                            bytesPerRow: 0,
                            space: colorSpace,
                            bitmapInfo: bitmapInfo) else {
    print("Failed to create context")
    exit(1)
}

// 填充背景 - 渐变蓝色
let gradient = CGGradient(colorsSpace: colorSpace,
                          colorComponents: [0.2, 0.5, 1.0, 1.0,  // 深蓝色
                                             0.4, 0.7, 1.0, 1.0], // 浅蓝色
                          locations: [0.0, 1.0],
                          count: 2)
context.drawLinearGradient(gradient,
                           start: CGPoint(x: 0, y: 0),
                           end: CGPoint(x: size, y: size),
                           options: [])

// 圆角矩形背景
let cornerRadius: CGFloat = 180
let path = CGPath(roundedRect: CGRect(x: 40, y: 40, width: size-80, height: size-80),
                  cornerWidth: cornerRadius,
                  cornerHeight: cornerRadius)
context.addPath(path)
context.clip()

// 绘制麦克风图标
context.setStrokeColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0))
context.setFillColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0))
context.setLineWidth(30)

// 麦克风外框 (圆角矩形)
let micRect = CGRect(x: size/2 - 140, y: size/2 - 200, width: 280, height: 380)
let micPath = CGPath(roundedRect: micRect, cornerWidth: 40, cornerHeight: 40)
context.addPath(micPath)
context.drawPath(using: .fill)

// 麦克风网格线 (横向)
let gridYStart = size/2 - 160
for i in 0..<7 {
    let y = gridYStart + CGFloat(i) * 40
    context.move(to: CGPoint(x: size/2 - 100, y: y))
    context.addLine(to: CGPoint(x: size/2 + 100, y: y))
}
context.strokePath()

// 麦克风网格线 (竖向)
let gridXStart = size/2 - 100
for i in 0..<5 {
    let x = gridXStart + CGFloat(i) * 50
    context.move(to: CGPoint(x: x, y: size/2 - 160))
    context.addLine(to: CGPoint(x: x, y: size/2 + 160))
}
context.strokePath()

// 麦克风支架
context.setLineWidth(35)
context.move(to: CGPoint(x: size/2 - 120, y: size/2 + 200))
context.addLine(to: CGPoint(x: size/2 - 120, y: size/2 + 280))
context.strokePath()

context.move(to: CGPoint(x: size/2 + 120, y: size/2 + 200))
context.addLine(to: CGPoint(x: size/2 + 120, y: size/2 + 280))
context.strokePath()

// 横杆
context.move(to: CGPoint(x: size/2 - 120, y: size/2 + 260))
context.addLine(to: CGPoint(x: size/2 + 120, y: size/2 + 260))
context.strokePath()

// 获取图像
guard let image = context.makeImage() else {
    print("Failed to create image")
    exit(1)
}

// 保存为 PNG
guard let bitmapContext = CGContext(data: nil,
                                   width: size,
                                   height: size,
                                   bitsPerComponent: 8,
                                   bytesPerRow: 0,
                                   space: colorSpace,
                                   bitmapInfo: bitmapInfo) else {
    print("Failed to create bitmap context")
    exit(1)
}

bitmapContext.draw(image, in: CGRect(origin: .zero, size: iconSize))

guard let pngData = bitmapContext.data?.copy() as Data?,
      let destination = CFURLCreateWithFileSystemPath(kCFAllocatorDefault, "AppIcon-Source.png", false) as CFURL else {
    print("Failed to create PNG data")
    exit(1)
}

pngData.write(to: destination as URL)
print("Icon generated successfully: AppIcon-Source.png")
