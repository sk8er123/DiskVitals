// 앱 아이콘(1024px PNG)을 코드로 그려 저장하는 스크립트: 파란-청록 둥근 사각형 위 은색 드라이브와 초록 심박 선
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/AppIcon.png"
let size = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
func gradient(_ colors: [CGColor]) -> CGGradient {
    CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: nil)!
}

// 1) 바탕: macOS 아이콘 격자(824px 본체, 여백 100px)
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.35))
ctx.addPath(bodyPath); ctx.setFillColor(rgb(0x1E3A8A)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(bodyPath); ctx.clip()
ctx.drawLinearGradient(gradient([rgb(0x2563EB), rgb(0x1E3A8A), rgb(0x0F766E)]),
                       start: CGPoint(x: 100, y: 924), end: CGPoint(x: 924, y: 100), options: [])
// 위쪽 은은한 광택
ctx.drawRadialGradient(gradient([rgb(0xFFFFFF, 0.22), rgb(0xFFFFFF, 0)]),
                       startCenter: CGPoint(x: 360, y: 860), startRadius: 0,
                       endCenter: CGPoint(x: 360, y: 860), endRadius: 560, options: [])
ctx.restoreGState()

// 2) 드라이브 본체
let drive = CGRect(x: 232, y: 330, width: 560, height: 360)
let drivePath = CGPath(roundedRect: drive, cornerWidth: 44, cornerHeight: 44, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 36, color: rgb(0x000000, 0.45))
ctx.addPath(drivePath); ctx.setFillColor(rgb(0xD1D5DB)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(drivePath); ctx.clip()
ctx.drawLinearGradient(gradient([rgb(0xF9FAFB), rgb(0xD1D5DB), rgb(0x9CA3AF)]),
                       start: CGPoint(x: 0, y: drive.maxY), end: CGPoint(x: 0, y: drive.minY), options: [])
ctx.restoreGState()
ctx.addPath(drivePath); ctx.setStrokeColor(rgb(0xFFFFFF, 0.7)); ctx.setLineWidth(4); ctx.strokePath()

// 라벨 판
let label = drive.insetBy(dx: 54, dy: 58)
let labelPath = CGPath(roundedRect: label, cornerWidth: 22, cornerHeight: 22, transform: nil)
ctx.saveGState()
ctx.addPath(labelPath); ctx.clip()
ctx.drawLinearGradient(gradient([rgb(0x1F2937), rgb(0x111827)]),
                       start: CGPoint(x: 0, y: label.maxY), end: CGPoint(x: 0, y: label.minY), options: [])
ctx.restoreGState()

// 아래쪽 금색 커넥터 핀
for i in 0..<14 {
    let x = drive.minX + 150 + CGFloat(i) * 19
    let pin = CGRect(x: x, y: drive.minY + 16, width: 11, height: 26)
    ctx.addPath(CGPath(roundedRect: pin, cornerWidth: 3, cornerHeight: 3, transform: nil))
    ctx.setFillColor(rgb(0xD4A72C)); ctx.fillPath()
}

// 나사 네 개
for (x, y) in [(drive.minX + 26, drive.minY + 26), (drive.maxX - 26, drive.minY + 26),
               (drive.minX + 26, drive.maxY - 26), (drive.maxX - 26, drive.maxY - 26)] {
    ctx.setFillColor(rgb(0x6B7280))
    ctx.fillEllipse(in: CGRect(x: x - 11, y: y - 11, width: 22, height: 22))
    ctx.setFillColor(rgb(0xE5E7EB))
    ctx.fillEllipse(in: CGRect(x: x - 5, y: y - 5, width: 10, height: 10))
}

// 3) 심박 선 (라벨 위, 초록 발광)
let midY = label.midY
let pts: [CGPoint] = [
    CGPoint(x: label.minX + 24, y: midY),
    CGPoint(x: label.minX + 140, y: midY),
    CGPoint(x: label.minX + 178, y: midY + 48),
    CGPoint(x: label.minX + 222, y: midY - 92),
    CGPoint(x: label.minX + 270, y: midY + 118),
    CGPoint(x: label.minX + 312, y: midY - 30),
    CGPoint(x: label.minX + 340, y: midY),
    CGPoint(x: label.maxX - 24, y: midY),
]
let pulse = CGMutablePath()
pulse.addLines(between: pts)
ctx.saveGState()
ctx.setLineCap(.round); ctx.setLineJoin(.round)
ctx.setShadow(offset: .zero, blur: 26, color: rgb(0x22C55E, 0.95))
ctx.addPath(pulse); ctx.setStrokeColor(rgb(0x22C55E)); ctx.setLineWidth(20); ctx.strokePath()
ctx.restoreGState()
ctx.setLineCap(.round); ctx.setLineJoin(.round)
ctx.addPath(pulse); ctx.setStrokeColor(rgb(0xBBF7D0)); ctx.setLineWidth(7); ctx.strokePath()

// 4) 건강 표시 점 (오른쪽 위)
let dot = CGRect(x: drive.maxX - 110, y: drive.maxY - 6, width: 120, height: 120)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 16, color: rgb(0x000000, 0.4))
ctx.setFillColor(rgb(0x16A34A)); ctx.fillEllipse(in: dot)
ctx.restoreGState()
ctx.setStrokeColor(rgb(0xFFFFFF)); ctx.setLineWidth(10); ctx.strokeEllipse(in: dot.insetBy(dx: 5, dy: 5))
let check = CGMutablePath()
check.addLines(between: [CGPoint(x: dot.minX + 34, y: dot.midY + 2), CGPoint(x: dot.minX + 54, y: dot.midY - 20),
                         CGPoint(x: dot.minX + 88, y: dot.midY + 22)])
ctx.setLineCap(.round); ctx.setLineJoin(.round)
ctx.addPath(check); ctx.setStrokeColor(rgb(0xFFFFFF)); ctx.setLineWidth(14); ctx.strokePath()

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
let url = URL(fileURLWithPath: out)
try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
try rep.representation(using: .png, properties: [:])!.write(to: url)
print("Saved \(out)")
