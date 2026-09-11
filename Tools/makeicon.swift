// Draws Duo's app icon. Regenerate Resources/AppIcon.icns with:
//   swiftc -O Tools/makeicon.swift -o /tmp/makeicon && /tmp/makeicon /tmp/Duo.iconset \
//     && iconutil -c icns /tmp/Duo.iconset -o Resources/AppIcon.icns
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - tiny 3d

struct V3 {
    var x, y, z: Double
    static func - (a: V3, b: V3) -> V3 { V3(x: a.x - b.x, y: a.y - b.y, z: a.z - b.z) }
    static func dot(_ a: V3, _ b: V3) -> Double { a.x * b.x + a.y * b.y + a.z * b.z }
    static func cross(_ a: V3, _ b: V3) -> V3 {
        V3(x: a.y * b.z - a.z * b.y, y: a.z * b.x - a.x * b.z, z: a.x * b.y - a.y * b.x)
    }
    var normalized: V3 {
        let l = (x * x + y * y + z * z).squareRoot()
        return V3(x: x / l, y: y / l, z: z / l)
    }
}

struct Camera {
    let eye: V3
    let target: V3
    let fov: Double
    let frame: CGRect

    private var basis: (right: V3, up: V3, forward: V3) {
        let forward = (target - eye).normalized
        let right = V3.cross(forward, V3(x: 0, y: 1, z: 0)).normalized
        return (right, V3.cross(right, forward), forward)
    }

    func project(_ p: V3) -> CGPoint {
        let (right, up, forward) = basis
        let d = p - eye
        let depth = max(V3.dot(d, forward), 1e-4)
        let tanHalf = tan(fov / 2)
        let ndcX = V3.dot(d, right) / (tanHalf * depth)
        let ndcY = V3.dot(d, up) / (tanHalf * depth)
        return CGPoint(x: frame.midX + ndcX * frame.width / 2,
                       y: frame.midY + ndcY * frame.height / 2)
    }
}

// MARK: - the laptop

let halfWidth = 0.50
let screenHeight = 0.66
let deckDepth = 0.46

/// Point on the bent screen. `u` runs across, `s` from the hinge to the top edge.
func screenPoint(_ u: Double, _ s: Double, bend k: Double) -> V3 {
    let y = k < 1e-6 ? s : sin(k * s) / k
    let z = k < 1e-6 ? 0 : -(1 - cos(k * s)) / k
    return V3(x: (u - 0.5) * 2 * halfWidth, y: y * screenHeight, z: z * screenHeight)
}

func screenPath(bend: Double, camera: Camera) -> CGPath {
    let path = CGMutablePath()
    let steps = 80
    path.move(to: camera.project(screenPoint(0, 0, bend: bend)))
    for i in 0...steps { path.addLine(to: camera.project(screenPoint(1, Double(i) / Double(steps), bend: bend))) }
    for i in stride(from: steps, through: 0, by: -1) {
        path.addLine(to: camera.project(screenPoint(0, Double(i) / Double(steps), bend: bend)))
    }
    path.closeSubpath()
    return path
}

func deckPath(camera: Camera) -> CGPath {
    let path = CGMutablePath()
    let corners = [
        V3(x: -halfWidth, y: 0, z: 0),
        V3(x: halfWidth, y: 0, z: 0),
        V3(x: halfWidth * 1.02, y: 0, z: deckDepth),
        V3(x: -halfWidth * 1.02, y: 0, z: deckDepth),
    ]
    path.move(to: camera.project(corners[0]))
    corners.dropFirst().forEach { path.addLine(to: camera.project($0)) }
    path.closeSubpath()
    return path
}

// MARK: - drawing helpers

func squircle(in rect: CGRect, exponent: Double = 5.0) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    for step in 0...720 {
        let t = Double(step) / 720 * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = pow(abs(c), 2 / exponent) * (c < 0 ? -1 : 1) * a
        let y = pow(abs(s), 2 / exponent) * (s < 0 ? -1 : 1) * b
        let point = CGPoint(x: rect.midX + x, y: rect.midY + y)
        step == 0 ? path.move(to: point) : path.addLine(to: point)
    }
    path.closeSubpath()
    return path
}

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
               colors: stops.map { $0.1 } as CFArray,
               locations: stops.map { $0.0 })!
}

func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(red: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

func fill(_ context: CGContext, _ path: CGPath, _ stops: [(CGFloat, CGColor)]) {
    context.saveGState()
    context.addPath(path)
    context.clip()
    let box = path.boundingBox
    context.drawLinearGradient(gradient(stops),
                               start: CGPoint(x: box.midX, y: box.maxY),
                               end: CGPoint(x: box.midX, y: box.minY),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.restoreGState()
}

// MARK: - icon

func drawIcon(size: Int) -> CGImage {
    let s = CGFloat(size)
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high

    let plate = CGRect(x: s * 0.1, y: s * 0.116, width: s * 0.8, height: s * 0.8)
    let shape = squircle(in: plate)

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -s * 0.013), blur: s * 0.036,
                      color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.30))
    context.addPath(shape)
    context.setFillColor(rgb(40, 80, 200))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(shape)
    context.clip()

    // Plate: lighter at the top, the way the system lights every icon.
    context.drawLinearGradient(
        gradient([(0, rgb(22, 44, 122)), (0.5, rgb(38, 84, 200)), (1, rgb(104, 164, 255))]),
        start: CGPoint(x: plate.midX, y: plate.minY),
        end: CGPoint(x: plate.midX, y: plate.maxY),
        options: [])
    context.drawRadialGradient(
        gradient([(0, rgb(255, 255, 255, 0.30)), (1, rgb(255, 255, 255, 0))]),
        startCenter: CGPoint(x: plate.midX, y: plate.maxY - plate.height * 0.06), startRadius: 0,
        endCenter: CGPoint(x: plate.midX, y: plate.maxY - plate.height * 0.06), endRadius: plate.width * 0.78,
        options: [])

    let stage = plate.insetBy(dx: plate.width * 0.16, dy: plate.height * 0.16)
    let camera = Camera(eye: V3(x: 0, y: 0.56, z: 2.05),
                        target: V3(x: 0, y: 0.24, z: 0.10),
                        fov: 32 * .pi / 180,
                        frame: stage)

    let bend = 1.05
    let screen = screenPath(bend: bend, camera: camera)
    let deck = deckPath(camera: camera)

    // Deck first — the screen bends back over it.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -s * 0.008), blur: s * 0.022,
                      color: CGColor(red: 0, green: 0.03, blue: 0.16, alpha: 0.5))
    context.addPath(deck)
    context.setFillColor(rgb(226, 231, 240))
    context.fillPath()
    context.restoreGState()
    fill(context, deck, [(0, rgb(198, 208, 226)), (1, rgb(241, 244, 250))])

    // Screen: white at the hinge, cooling off as the arc falls away.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: s * 0.004), blur: s * 0.028,
                      color: CGColor(red: 0, green: 0.03, blue: 0.18, alpha: 0.42))
    context.addPath(screen)
    context.setFillColor(rgb(255, 255, 255))
    context.fillPath()
    context.restoreGState()
    fill(context, screen, [(0, rgb(150, 183, 240)), (0.58, rgb(244, 248, 255)), (1, rgb(255, 255, 255))])

    // Hinge seam.
    let hingeLeft = camera.project(screenPoint(0, 0, bend: bend))
    let hingeRight = camera.project(screenPoint(1, 0, bend: bend))
    context.move(to: hingeLeft)
    context.addLine(to: hingeRight)
    context.setStrokeColor(rgb(52, 86, 160, 0.32))
    context.setLineWidth(max(s * 0.006, 0.75))
    context.setLineCap(.round)
    context.strokePath()

    // Top rim highlight on the plate.
    context.addPath(shape)
    context.setStrokeColor(rgb(255, 255, 255, 0.28))
    context.setLineWidth(s * 0.005)
    context.strokePath()

    context.restoreGState()
    return context.makeImage()!
}

// MARK: - write

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

let variants: [(name: String, size: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for variant in variants {
    let url = outputDirectory.appendingPathComponent("\(variant.name).png")
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, drawIcon(size: variant.size), nil)
    CGImageDestinationFinalize(destination)
}
print("wrote \(variants.count) sizes to \(outputDirectory.path)")
