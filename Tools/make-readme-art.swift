// Renders every picture in the README with Duo's own shader — no mockups.
//
//   swiftc -O Tools/make-readme-art.swift Sources/Duo/Shaders.swift \
//     Sources/Duo/BendRenderer.swift Sources/Duo/LidModel.swift -o /tmp/duo-art
//   /tmp/duo-art docs

import AppKit
import Metal
import CoreVideo
import ImageIO
import UniformTypeIdentifiers

// MARK: - small drawing helpers

func srgb(_ hex: UInt32, _ alpha: Double = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255,
            alpha: CGFloat(alpha))
}

func ns(_ hex: UInt32, _ alpha: Double = 1) -> NSColor { NSColor(cgColor: srgb(hex, alpha))! }

func newContext(_ width: Int, _ height: Int) -> CGContext {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high
    return ctx
}

func ramp(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
               colors: stops.map { $0.1 } as CFArray,
               locations: stops.map { $0.0 })!
}

func rounded(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

/// Rounded on top, square on the bottom — the shape of a MacBook's panel.
func panelShape(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: rect.minX, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - radius))
    path.addQuadCurve(to: CGPoint(x: rect.minX + radius, y: rect.maxY), control: CGPoint(x: rect.minX, y: rect.maxY))
    path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.maxY))
    path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY - radius), control: CGPoint(x: rect.maxX, y: rect.maxY))
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
    path.closeSubpath()
    return path
}

func fill(_ ctx: CGContext, _ path: CGPath, _ color: CGColor) {
    ctx.addPath(path); ctx.setFillColor(color); ctx.fillPath()
}

func fill(_ ctx: CGContext, _ path: CGPath, _ stops: [(CGFloat, CGColor)]) {
    let box = path.boundingBox
    ctx.saveGState(); ctx.addPath(path); ctx.clip()
    ctx.drawLinearGradient(ramp(stops), start: CGPoint(x: box.midX, y: box.maxY), end: CGPoint(x: box.midX, y: box.minY),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}

func glow(_ ctx: CGContext, at centre: CGPoint, radius: CGFloat, _ color: CGColor) {
    ctx.drawRadialGradient(ramp([(0, color), (1, color.copy(alpha: 0)!)]),
                           startCenter: centre, startRadius: 0, endCenter: centre, endRadius: radius, options: [])
}

@discardableResult
func text(_ ctx: CGContext, _ string: String, at point: CGPoint, size: CGFloat, weight: NSFont.Weight = .regular,
          color: NSColor, mono: Bool = false, tracking: CGFloat = 0, centred: Bool = false) -> CGSize {
    let font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
                    : NSFont.systemFont(ofSize: size, weight: weight)
    var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    if tracking != 0 { attributes[.kern] = tracking }
    let line = NSAttributedString(string: string, attributes: attributes)
    let measured = line.size()
    let origin = centred ? CGPoint(x: point.x - measured.width / 2, y: point.y) : point
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    line.draw(at: origin)
    NSGraphicsContext.restoreGraphicsState()
    return measured
}

let appIcon = NSImage(contentsOfFile: "Resources/AppIcon.icns")

func drawIcon(_ ctx: CGContext, in rect: CGRect) {
    guard let appIcon,
          let cg = appIcon.cgImage(forProposedRect: nil, context: nil, hints: [.interpolation: NSNumber(value: NSImageInterpolation.high.rawValue)])
    else { return }
    ctx.draw(cg, in: rect)
}

// MARK: - the desktop being folded

let desktopSize = CGSize(width: 1710, height: 1107)

func paintDesktop() -> (pixels: CVPixelBuffer, image: CGImage) {
    let w = desktopSize.width, h = desktopSize.height
    let ctx = newContext(Int(w), Int(h))

    // Wallpaper: a deep dusk with three soft auroras.
    ctx.drawLinearGradient(ramp([(0, srgb(0xFFC178)), (0.30, srgb(0xE07A8E)), (0.62, srgb(0x6E4BB0)), (1, srgb(0x1D2A78))]),
                           start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: h), options: [])
    glow(ctx, at: CGPoint(x: w * 0.22, y: h * 0.78), radius: w * 0.44, srgb(0x38D0E0, 0.34))
    glow(ctx, at: CGPoint(x: w * 0.80, y: h * 0.60), radius: w * 0.42, srgb(0xFF7AB6, 0.30))
    glow(ctx, at: CGPoint(x: w * 0.50, y: h * 0.06), radius: w * 0.50, srgb(0xFFD08A, 0.34))

    // Menu bar.
    let barHeight = h * 0.033
    fill(ctx, CGPath(rect: CGRect(x: 0, y: h - barHeight, width: w, height: barHeight), transform: nil), srgb(0x05070F, 0.30))
    let barText = h * 0.0155
    var cursor = w * 0.018
    drawIcon(ctx, in: CGRect(x: cursor, y: h - barHeight + barHeight * 0.22, width: barHeight * 0.56, height: barHeight * 0.56))
    cursor += barHeight * 0.78
    for (index, item) in ["Duo", "File", "Edit", "View", "Window", "Help"].enumerated() {
        let size = text(ctx, item, at: CGPoint(x: cursor, y: h - barHeight + barHeight * 0.3),
                        size: barText, weight: index == 0 ? .semibold : .regular, color: ns(0xFFFFFF, 0.92))
        cursor += size.width + w * 0.014
    }
    let clock = text(ctx, "9:41", at: CGPoint(x: w - w * 0.022, y: h - barHeight + barHeight * 0.3),
                     size: barText, weight: .medium, color: ns(0xFFFFFF, 0.92))
    let battery = CGRect(x: w - w * 0.032 - clock.width, y: h - barHeight * 0.62, width: barHeight * 0.5, height: barHeight * 0.26)
    ctx.addPath(rounded(battery, battery.height * 0.35))
    ctx.setStrokeColor(srgb(0xFFFFFF, 0.75)); ctx.setLineWidth(h * 0.0014); ctx.strokePath()
    fill(ctx, rounded(battery.insetBy(dx: battery.height * 0.12, dy: battery.height * 0.12), battery.height * 0.2), srgb(0xFFFFFF, 0.85))

    // A dark editor window, carrying the shader that draws all of this.
    let editor = CGRect(x: w * 0.065, y: h * 0.17, width: w * 0.545, height: h * 0.60)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -h * 0.018), blur: h * 0.055, color: srgb(0x000000, 0.55))
    fill(ctx, rounded(editor, h * 0.016), srgb(0x1B1D24, 0.98))
    ctx.restoreGState()
    let editorBar = CGRect(x: editor.minX, y: editor.maxY - h * 0.036, width: editor.width, height: h * 0.036)
    ctx.saveGState(); ctx.addPath(rounded(editor, h * 0.016)); ctx.clip()
    fill(ctx, CGPath(rect: editorBar, transform: nil), srgb(0x25272F))
    fill(ctx, CGPath(rect: CGRect(x: editor.minX, y: editor.minY, width: w * 0.105, height: editor.height - editorBar.height), transform: nil), srgb(0x16181E))
    ctx.restoreGState()
    for (index, colour) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
        let dot = CGRect(x: editorBar.minX + h * 0.018 + CGFloat(index) * h * 0.026, y: editorBar.midY - h * 0.007,
                         width: h * 0.014, height: h * 0.014)
        fill(ctx, CGPath(ellipseIn: dot, transform: nil), srgb(UInt32(colour)))
    }
    text(ctx, "DuoFold.metal", at: CGPoint(x: editorBar.midX, y: editorBar.midY - h * 0.009),
         size: h * 0.0145, weight: .medium, color: ns(0x9AA0AE), centred: true)
    for row in 0..<7 {
        let y = editor.maxY - editorBar.height - h * 0.045 - CGFloat(row) * h * 0.032
        fill(ctx, rounded(CGRect(x: editor.minX + h * 0.02, y: y, width: w * 0.062 - CGFloat(row % 3) * w * 0.008, height: h * 0.011), h * 0.005),
             srgb(0xFFFFFF, row == 2 ? 0.55 : 0.18))
    }
    let code: [[(String, UInt32)]] = [
        [("// the desktop keeps its place while the lid comes down", 0x6A9955)],
        [("float3 ", 0x4EC9B0), ("panel ", 0xD4D4D4), ("= ", 0xD4D4D4), ("float3", 0x4EC9B0), ("(p.x, size.y - s * ", 0xD4D4D4), ("cos", 0xDCDCAA), ("(tilt), -s * ", 0xD4D4D4), ("sin", 0xDCDCAA), ("(tilt));", 0xD4D4D4)],
        [("float2 ", 0x4EC9B0), ("hit   = eye.xy + (p - eye.xy) * t;", 0xD4D4D4)],
        [("", 0xD4D4D4)],
        [("// frosted glass: the farther it falls, the wider it scatters", 0x6A9955)],
        [("float  ", 0x4EC9B0), ("radius = blurSpread * gap;", 0xD4D4D4)],
        [("float  ", 0x4EC9B0), ("shade  = ", 0xD4D4D4), ("max", 0xDCDCAA), ("(", 0xD4D4D4), ("1.0", 0xB5CEA8), (" - darkening * radius, ", 0xD4D4D4), ("0.0", 0xB5CEA8), (");", 0xD4D4D4)],
        [("", 0xD4D4D4)],
        [("for ", 0xC586C0), ("(", 0xD4D4D4), ("int ", 0x4EC9B0), ("i = ", 0xD4D4D4), ("0", 0xB5CEA8), ("; i < taps; ++i) {", 0xD4D4D4)],
        [("    sum += desktop.", 0xD4D4D4), ("sample", 0xDCDCAA), ("(smp, tuv, ", 0xD4D4D4), ("level", 0xDCDCAA), ("(lod)).rgb;", 0xD4D4D4)],
        [("}", 0xD4D4D4)],
    ]
    let codeSize = h * 0.0175
    for (row, line) in code.enumerated() {
        var x = editor.minX + w * 0.125
        let y = editor.maxY - editorBar.height - h * 0.052 - CGFloat(row) * h * 0.0315
        for (fragment, colour) in line {
            let size = text(ctx, fragment, at: CGPoint(x: x, y: y), size: codeSize, weight: .regular, color: ns(colour), mono: true)
            x += size.width
        }
    }

    // A light window in front of it.
    let notes = CGRect(x: w * 0.545, y: h * 0.36, width: w * 0.375, height: h * 0.47)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -h * 0.02), blur: h * 0.06, color: srgb(0x000000, 0.5))
    fill(ctx, rounded(notes, h * 0.016), srgb(0xFBFBFD, 0.99))
    ctx.restoreGState()
    ctx.saveGState(); ctx.addPath(rounded(notes, h * 0.016)); ctx.clip()
    fill(ctx, CGPath(rect: CGRect(x: notes.minX, y: notes.maxY - h * 0.036, width: notes.width, height: h * 0.036), transform: nil), srgb(0xF0F0F4))
    ctx.restoreGState()
    for (index, colour) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
        let dot = CGRect(x: notes.minX + h * 0.018 + CGFloat(index) * h * 0.026, y: notes.maxY - h * 0.025,
                         width: h * 0.014, height: h * 0.014)
        fill(ctx, CGPath(ellipseIn: dot, transform: nil), srgb(UInt32(colour)))
    }
    text(ctx, "Lid angle", at: CGPoint(x: notes.minX + w * 0.022, y: notes.maxY - h * 0.095),
         size: h * 0.030, weight: .semibold, color: ns(0x14161C))
    text(ctx, "0°  shut     ·     80°  the fold begins     ·     113°  open", at: CGPoint(x: notes.minX + w * 0.022, y: notes.maxY - h * 0.135),
         size: h * 0.0165, weight: .regular, color: ns(0x6A7080))
    for row in 0..<5 {
        let y = notes.maxY - h * 0.185 - CGFloat(row) * h * 0.028
        fill(ctx, rounded(CGRect(x: notes.minX + w * 0.022, y: y, width: notes.width - w * 0.044 - CGFloat(row % 2) * w * 0.05, height: h * 0.011), h * 0.005),
             srgb(0x14161C, row == 0 ? 0.28 : 0.13))
    }
    let card = CGRect(x: notes.minX + w * 0.022, y: notes.minY + h * 0.035, width: notes.width - w * 0.044, height: h * 0.105)
    fill(ctx, rounded(card, h * 0.012), [(0, srgb(0x68A4FF)), (1, srgb(0x2A50C8))])
    text(ctx, "Frosted glass, on the hinge", at: CGPoint(x: card.minX + w * 0.018, y: card.midY - h * 0.009),
         size: h * 0.0185, weight: .medium, color: ns(0xFFFFFF, 0.95))

    // Dock.
    let dock = CGRect(x: w * 0.5 - w * 0.21, y: h * 0.022, width: w * 0.42, height: h * 0.082)
    fill(ctx, rounded(dock, dock.height * 0.32), srgb(0xFFFFFF, 0.16))
    ctx.addPath(rounded(dock, dock.height * 0.32))
    ctx.setStrokeColor(srgb(0xFFFFFF, 0.22)); ctx.setLineWidth(h * 0.0016); ctx.strokePath()
    let slot = dock.width / 8
    let iconSide = dock.height * 0.68
    let icons: [[(CGFloat, UInt32)]] = [
        [(0, 0x5AC8FA), (1, 0x0A84FF)], [(0, 0xFFFFFF), (1, 0xD8D8E0)], [(0, 0xFFD60A), (1, 0xFF9F0A)],
        [(0, 0x30D158), (1, 0x248A3D)], [(0, 0xFF6482), (1, 0xD3315F)], [(0, 0xBF5AF2), (1, 0x7D3BB3)],
        [(0, 0x8E8E93), (1, 0x545458)],
    ]
    for (index, stops) in icons.enumerated() {
        let box = CGRect(x: dock.minX + slot * (CGFloat(index) + 0.5) - iconSide / 2, y: dock.midY - iconSide / 2,
                         width: iconSide, height: iconSide)
        fill(ctx, rounded(box, iconSide * 0.24), stops.map { ($0.0, srgb($0.1)) })
    }
    drawIcon(ctx, in: CGRect(x: dock.minX + slot * 7.5 - iconSide / 2, y: dock.midY - iconSide / 2, width: iconSide, height: iconSide))

    // Hand it to Metal.
    let image = ctx.makeImage()!
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, Int(w), Int(h), kCVPixelFormatType_32BGRA,
                        [kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &buffer)
    let pixels = buffer!
    CVPixelBufferLockBaseAddress(pixels, [])
    let target = CGContext(data: CVPixelBufferGetBaseAddress(pixels), width: Int(w), height: Int(h),
                           bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixels),
                           space: CGColorSpace(name: CGColorSpace.sRGB)!,
                           bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    target.draw(image, in: CGRect(origin: .zero, size: desktopSize))
    CVPixelBufferUnlockBaseAddress(pixels, [])
    return (pixels, image)
}

// MARK: - the fold itself, through Duo's shader

let device = MTLCreateSystemDefaultDevice()!
let queue = device.makeCommandQueue()!
let desktopArt = paintDesktop()
let renderer: BendRenderer = {
    let renderer = BendRenderer(device: device)!
    renderer.pixelsPerMillimetre = Double(desktopSize.width) / 326
    renderer.cornerRadius = 2.2 * renderer.pixelsPerMillimetre
    return renderer
}()

func foldedScreen(tiltDegrees: Double) -> CGImage {
    // With the lid open the overlay draws nothing at all, so show the desktop itself.
    guard tiltDegrees > 0.01 else { return desktopArt.image }

    let width = Int(desktopSize.width), height = Int(desktopSize.height)
    renderer.submit(frame: desktopArt.pixels)
    renderer.params = BendParams(tilt: tiltDegrees * .pi / 180, perspective: 1, blur: 0.65, shadow: 0.35)

    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
    descriptor.usage = [.renderTarget, .shaderRead]
    descriptor.storageMode = .shared
    let texture = device.makeTexture(descriptor: descriptor)!
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = texture
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].storeAction = .store
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
    let commands = queue.makeCommandBuffer()!
    renderer.encode(into: pass, commandBuffer: commands)
    commands.commit()
    commands.waitUntilCompleted()

    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    texture.getBytes(&pixels, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
    return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                   space: CGColorSpace(name: CGColorSpace.sRGB)!,
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                   provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil,
                   shouldInterpolate: true, intent: .defaultIntent)!
}

/// The screen, wrapped in the machine it belongs to.
func macBook(_ screen: CGImage, screenWidth: CGFloat) -> CGImage {
    let screenHeight = screenWidth * desktopSize.height / desktopSize.width
    let bezel = screenWidth * 0.0115
    let lid = CGRect(x: bezel * 2, y: screenWidth * 0.032, width: screenWidth + bezel * 2, height: screenHeight + bezel * 2.6)
    let baseHeight = screenWidth * 0.023
    let width = Int(lid.width + bezel * 4 + lid.width * 0.07)
    let height = Int(lid.maxY + screenWidth * 0.012)
    let ctx = newContext(width, height)

    let lidRect = CGRect(x: (CGFloat(width) - lid.width) / 2, y: lid.minY, width: lid.width, height: lid.height)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -screenWidth * 0.012), blur: screenWidth * 0.045, color: srgb(0x000000, 0.55))
    fill(ctx, rounded(lidRect, screenWidth * 0.022), [(0, srgb(0x2A2C31)), (1, srgb(0x131418))])
    ctx.restoreGState()

    let screenRect = CGRect(x: lidRect.minX + bezel, y: lidRect.minY + bezel * 1.6, width: screenWidth, height: screenHeight)
    ctx.saveGState()
    ctx.addPath(panelShape(screenRect, screenWidth * 0.0068))
    ctx.clip()
    ctx.draw(screen, in: screenRect)
    ctx.restoreGState()

    let notch = CGRect(x: lidRect.midX - lid.width * 0.075, y: screenRect.maxY - bezel * 1.5,
                       width: lid.width * 0.15, height: bezel * 1.5)
    let notchPath = CGMutablePath()
    notchPath.move(to: CGPoint(x: notch.minX, y: notch.maxY))
    notchPath.addLine(to: CGPoint(x: notch.minX, y: notch.minY + notch.height * 0.4))
    notchPath.addQuadCurve(to: CGPoint(x: notch.minX + notch.height * 0.5, y: notch.minY), control: CGPoint(x: notch.minX, y: notch.minY))
    notchPath.addLine(to: CGPoint(x: notch.maxX - notch.height * 0.5, y: notch.minY))
    notchPath.addQuadCurve(to: CGPoint(x: notch.maxX, y: notch.minY + notch.height * 0.4), control: CGPoint(x: notch.maxX, y: notch.minY))
    notchPath.addLine(to: CGPoint(x: notch.maxX, y: notch.maxY))
    notchPath.closeSubpath()
    fill(ctx, notchPath, srgb(0x131418))

    let base = CGRect(x: lidRect.minX - lid.width * 0.035, y: lidRect.minY - baseHeight, width: lid.width * 1.07, height: baseHeight)
    fill(ctx, rounded(base, baseHeight * 0.42), [(0, srgb(0xD3D5DA)), (1, srgb(0x94969E))])
    let hinge = CGRect(x: base.midX - base.width * 0.07, y: base.maxY - baseHeight * 0.34, width: base.width * 0.14, height: baseHeight * 0.34)
    fill(ctx, rounded(hinge, baseHeight * 0.14), srgb(0x000000, 0.18))
    return ctx.makeImage()!
}

// MARK: - the pictures

func write(_ image: CGImage, to url: URL) {
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

func hero(dark: Bool) -> CGImage {
    let width = 2560, height = 1180
    let w = CGFloat(width), h = CGFloat(height)
    let ctx = newContext(width, height)
    fill(ctx, CGPath(rect: CGRect(x: 0, y: 0, width: w, height: h), transform: nil), dark ? srgb(0x05070E) : srgb(0xF7F8FB))
    glow(ctx, at: CGPoint(x: w * 0.68, y: h * 0.52), radius: w * 0.46, srgb(0x2F6BFF, dark ? 0.34 : 0.18))
    glow(ctx, at: CGPoint(x: w * 0.12, y: h * 0.12), radius: w * 0.34, srgb(0x7D3BB3, dark ? 0.24 : 0.12))

    let screen = foldedScreen(tiltDegrees: 15)
    let machine = macBook(screen, screenWidth: w * 0.355)
    let machineRect = CGRect(x: w * 0.955 - CGFloat(machine.width), y: h * 0.5 - CGFloat(machine.height) / 2,
                             width: CGFloat(machine.width), height: CGFloat(machine.height))
    ctx.draw(machine, in: machineRect)

    let left = w * 0.075
    drawIcon(ctx, in: CGRect(x: left, y: h * 0.70, width: h * 0.20, height: h * 0.20))
    text(ctx, "Duo", at: CGPoint(x: left - h * 0.008, y: h * 0.44), size: h * 0.20, weight: .bold,
         color: dark ? ns(0xFFFFFF) : ns(0x0A0C12), tracking: -h * 0.006)
    text(ctx, "Your desktop folds away", at: CGPoint(x: left, y: h * 0.33), size: h * 0.052, weight: .regular,
         color: dark ? ns(0xC7CDDB) : ns(0x3A4050))
    text(ctx, "as you close the lid.", at: CGPoint(x: left, y: h * 0.255), size: h * 0.052, weight: .regular,
         color: dark ? ns(0xC7CDDB) : ns(0x3A4050))
    text(ctx, "MACOS 14  ·  APPLE SILICON  ·  METAL  ·  MIT", at: CGPoint(x: left, y: h * 0.145),
         size: h * 0.026, weight: .semibold, color: dark ? ns(0x6E7A8C) : ns(0x8A90A0), tracking: h * 0.006)
    return ctx.makeImage()!
}

func geometry(dark: Bool) -> CGImage {
    let width = 2000, height = 1120
    let w = CGFloat(width), h = CGFloat(height)
    let ctx = newContext(width, height)
    let ink = dark ? ns(0xEDF0F7) : ns(0x0B0D12)
    let quiet = dark ? ns(0x8790A6) : ns(0x6B7383)
    let line = dark ? srgb(0x39415A) : srgb(0xCDD3DF)
    let accent = srgb(0x4C8DFF)
    let accentText = ns(0x4C8DFF)
    fill(ctx, CGPath(rect: CGRect(x: 0, y: 0, width: w, height: h), transform: nil), dark ? srgb(0x090C14) : srgb(0xFFFFFF))

    let hinge = CGPoint(x: w * 0.34, y: h * 0.17)
    let screenTop = CGPoint(x: w * 0.34, y: h * 0.86)
    let eye = CGPoint(x: w * 0.88, y: h * 0.40)
    let tilt = 34.0 * .pi / 180
    let length = screenTop.y - hinge.y
    let along = CGPoint(x: -sin(tilt), y: cos(tilt))
    let panelTop = CGPoint(x: hinge.x + along.x * length, y: hinge.y + along.y * length)

    // Follow one pixel: from the eye, through the screen, on to the panel.
    let pixel = CGPoint(x: hinge.x, y: hinge.y + length * 0.62)
    let ray = CGPoint(x: pixel.x - eye.x, y: pixel.y - eye.y)
    let determinant = along.x * (-ray.y) - along.y * (-ray.x)
    let distanceAlong = ((eye.x - hinge.x) * (-ray.y) - (eye.y - hinge.y) * (-ray.x)) / determinant
    let hit = CGPoint(x: hinge.x + along.x * distanceAlong, y: hinge.y + along.y * distanceAlong)

    // Where the desktop used to be.
    ctx.setLineWidth(h * 0.004)
    ctx.setStrokeColor(line)
    ctx.setLineDash(phase: 0, lengths: [h * 0.016, h * 0.014])
    ctx.move(to: hinge); ctx.addLine(to: screenTop); ctx.strokePath()
    ctx.setLineDash(phase: 0, lengths: [])

    // The panel, tilted away.
    ctx.setLineWidth(h * 0.011)
    ctx.setStrokeColor(ink.cgColor)
    ctx.move(to: hinge); ctx.addLine(to: panelTop); ctx.strokePath()

    // The line of sight itself.
    ctx.setLineWidth(h * 0.005)
    ctx.setStrokeColor(accent)
    ctx.move(to: eye); ctx.addLine(to: hit); ctx.strokePath()
    for point in [pixel, hit] {
        fill(ctx, CGPath(ellipseIn: CGRect(x: point.x - h * 0.011, y: point.y - h * 0.011, width: h * 0.022, height: h * 0.022), transform: nil), accent)
    }

    // The gap that sets frost and shade.
    ctx.setStrokeColor(srgb(0xFF9F0A))
    ctx.setLineWidth(h * 0.005)
    ctx.setLineDash(phase: 0, lengths: [h * 0.012, h * 0.010])
    ctx.move(to: hit); ctx.addLine(to: CGPoint(x: hinge.x, y: hit.y)); ctx.strokePath()
    ctx.setLineDash(phase: 0, lengths: [])

    // The eye.
    fill(ctx, CGPath(ellipseIn: CGRect(x: eye.x - h * 0.018, y: eye.y - h * 0.018, width: h * 0.036, height: h * 0.036), transform: nil), ink.cgColor)

    let label = h * 0.030
    text(ctx, "your eye, where it was", at: CGPoint(x: eye.x - w * 0.165, y: eye.y + h * 0.042), size: label, weight: .medium, color: ink)
    text(ctx, "the screen, where the desktop was", at: CGPoint(x: screenTop.x + w * 0.016, y: screenTop.y - h * 0.028), size: label, weight: .medium, color: quiet)
    text(ctx, "the desktop, hinged at the bottom", at: CGPoint(x: max(w * 0.03, panelTop.x - w * 0.03), y: panelTop.y + h * 0.032), size: label, weight: .medium, color: ink)
    text(ctx, "gap → frost + shade", at: CGPoint(x: (hit.x + hinge.x) / 2, y: hit.y + h * 0.022), size: label, weight: .medium, color: ns(0xFF9F0A), centred: true)
    text(ctx, "hinge", at: CGPoint(x: hinge.x + w * 0.014, y: hinge.y - h * 0.014), size: label, weight: .medium, color: quiet)
    text(ctx, "the pixel being drawn", at: CGPoint(x: pixel.x + w * 0.016, y: pixel.y + h * 0.016), size: label, weight: .medium, color: accentText)
    text(ctx, "Every pixel asks where its line of sight lands on the tilted desktop.",
         at: CGPoint(x: w * 0.5, y: h * 0.055), size: h * 0.034, weight: .regular, color: quiet, centred: true)
    return ctx.makeImage()!
}

/// A GIF only gets 256 colours, and a wide smooth gradient turns into stripes.
/// A touch of ordered noise before quantising trades the stripes for grain.
func dither(_ ctx: CGContext) {
    guard let data = ctx.data else { return }
    let bayer: [Int] = [
        0, 32, 8, 40, 2, 34, 10, 42, 48, 16, 56, 24, 50, 18, 58, 26,
        12, 44, 4, 36, 14, 46, 6, 38, 60, 28, 52, 20, 62, 30, 54, 22,
        3, 35, 11, 43, 1, 33, 9, 41, 51, 19, 59, 27, 49, 17, 57, 25,
        15, 47, 7, 39, 13, 45, 5, 37, 63, 31, 55, 23, 61, 29, 53, 21,
    ]
    let bytes = data.assumingMemoryBound(to: UInt8.self)
    for y in 0..<ctx.height {
        for x in 0..<ctx.width {
            let offset = Int(((Double(bayer[(y % 8) * 8 + (x % 8)]) + 0.5) / 64 - 0.5) * 9)
            let pixel = y * ctx.bytesPerRow + x * 4
            for channel in 0..<3 {
                bytes[pixel + channel] = UInt8(clamping: Int(bytes[pixel + channel]) + offset)
            }
        }
    }
}

func foldGIF(to url: URL) {
    let stageWidth = 1360, stageHeight = 900
    var model = LidModel(angle: 113)
    model.startAngle = 80

    var tilts: [Double] = []
    func run(_ from: Double, _ to: Double, _ seconds: Double) {
        let steps = Int(seconds * 60)
        for i in 1...steps {
            let x = Double(i) / Double(steps)
            model.step(target: (from + (to - from) * x * x * (3 - 2 * x)).rounded(), dt: 1.0 / 60)
            tilts.append(model.tilt)
        }
    }
    run(113, 113, 0.25)
    run(113, 6, 0.85)
    run(6, 6, 0.45)
    run(6, 113, 0.95)
    run(113, 113, 0.5)

    let frames = stride(from: 0, to: tilts.count, by: 3).map { tilts[$0] }
    var images: [CGImage] = []
    for tilt in frames {
        let ctx = newContext(stageWidth, stageHeight)
        let w = CGFloat(stageWidth), h = CGFloat(stageHeight)
        fill(ctx, CGPath(rect: CGRect(x: 0, y: 0, width: w, height: h), transform: nil), srgb(0x06080F))
        glow(ctx, at: CGPoint(x: w * 0.5, y: h * 0.46), radius: w * 0.55, srgb(0x2F6BFF, 0.22))
        let machine = macBook(foldedScreen(tiltDegrees: tilt), screenWidth: w * 0.78)
        ctx.draw(machine, in: CGRect(x: (w - CGFloat(machine.width)) / 2, y: (h - CGFloat(machine.height)) / 2,
                                     width: CGFloat(machine.width), height: CGFloat(machine.height)))
        dither(ctx)
        images.append(ctx.makeImage()!)
    }

    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, images.count, nil)!
    CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    for image in images {
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.05]] as CFDictionary)
    }
    CGImageDestinationFinalize(destination)
}

// MARK: - go

@main
enum ReadmeArt {
    static func main() {
        let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "docs")
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        write(hero(dark: true), to: output.appendingPathComponent("hero-dark.png"))
        write(hero(dark: false), to: output.appendingPathComponent("hero-light.png"))
        write(geometry(dark: true), to: output.appendingPathComponent("geometry-dark.png"))
        write(geometry(dark: false), to: output.appendingPathComponent("geometry-light.png"))
        foldGIF(to: output.appendingPathComponent("fold.gif"))
        print("wrote art to \(output.path)")
    }
}
