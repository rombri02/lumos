// Renders the DMG window background (640x420 pt) at 1x and 2x.
// Usage: background out.png out@2x.png   (make-dmg.sh does this)
// Layout must match the icon positions set in make-dmg.sh: Lumos (160,200), Applications (480,200).
import SwiftUI

let size = CGSize(width: 640, height: 420)
let appCenter = CGPoint(x: 160, y: 200)
let applicationsCenter = CGPoint(x: 480, y: 200)
let amber = Color(red: 0.55, green: 0.38, blue: 0.05)

struct Background: View {
    var body: some View {
        ZStack {
            // Warm paper → soft yellow, the icon's palette at low intensity.
            LinearGradient(colors: [Color(red: 1.0, green: 0.985, blue: 0.94),
                                    Color(red: 1.0, green: 0.93, blue: 0.70)],
                           startPoint: .top, endPoint: .bottom)

            // Glow behind the app icon: the "light" Lumos brings.
            RadialGradient(colors: [Color.yellow.opacity(0.55), Color.yellow.opacity(0)],
                           center: .init(x: appCenter.x / size.width, y: appCenter.y / size.height),
                           startRadius: 10, endRadius: 190)

            Rays().stroke(Color.yellow.opacity(0.35), style: StrokeStyle(lineWidth: 3, lineCap: .round))

            Sparkles()

            Arrow()
                .stroke(amber.opacity(0.55), style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [2, 9]))
            ArrowHead().fill(amber.opacity(0.65))

            VStack(spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "wand.and.rays").font(.system(size: 20, weight: .semibold))
                    Text("Lumos").font(.system(size: 26, weight: .bold, design: .rounded))
                }
                Text("More light for your XDR display")
                    .font(.system(size: 13, weight: .medium))
                    .opacity(0.6)
            }
            .foregroundStyle(Color(red: 0.24, green: 0.17, blue: 0.02))
            .position(x: size.width / 2, y: 52)

            Text("Drag Lumos into Applications to install")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(amber.opacity(0.85))
                .position(x: size.width / 2, y: 365)
        }
        .frame(width: size.width, height: size.height)
    }
}

// Short rays around the app icon, echoing the wand.and.rays glyph.
struct Rays: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        for i in 0..<12 {
            let a = Double(i) / 12 * 2 * .pi
            let (inner, outer) = (CGFloat(i.isMultiple(of: 2) ? 92 : 98), CGFloat(i.isMultiple(of: 2) ? 118 : 108))
            p.move(to: CGPoint(x: appCenter.x + cos(a) * inner, y: appCenter.y + sin(a) * inner))
            p.addLine(to: CGPoint(x: appCenter.x + cos(a) * outer, y: appCenter.y + sin(a) * outer))
        }
        return p
    }
}

struct Sparkles: View {
    // Fixed positions: deterministic background on every build.
    let dots: [(CGFloat, CGFloat, CGFloat)] = [(60, 120, 3), (250, 105, 2), (300, 300, 2.5), (90, 300, 2),
                                               (390, 120, 2), (570, 310, 3), (590, 110, 2), (40, 210, 2)]
    var body: some View {
        ForEach(0..<dots.count, id: \.self) { i in
            Circle()
                .fill(Color.orange.opacity(0.45))
                .frame(width: dots[i].2 * 2, height: dots[i].2 * 2)
                .shadow(color: .yellow, radius: 4)
                .position(x: dots[i].0, y: dots[i].1)
        }
    }
}

// Gentle arc from the app to the Applications folder.
let arrowStart = CGPoint(x: appCenter.x + 95, y: appCenter.y - 6)
let arrowEnd = CGPoint(x: applicationsCenter.x - 92, y: applicationsCenter.y - 6)
let arrowControl = CGPoint(x: size.width / 2, y: appCenter.y - 70)

struct Arrow: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: arrowStart)
        p.addQuadCurve(to: arrowEnd, control: arrowControl)
        return p
    }
}

struct ArrowHead: Shape {
    func path(in rect: CGRect) -> Path {
        // Tangent of the quad curve at its end.
        let angle = atan2(arrowEnd.y - arrowControl.y, arrowEnd.x - arrowControl.x)
        let len: CGFloat = 14, spread = 0.45
        var p = Path()
        p.move(to: arrowEnd)
        p.addLine(to: CGPoint(x: arrowEnd.x - cos(angle - spread) * len, y: arrowEnd.y - sin(angle - spread) * len))
        p.addLine(to: CGPoint(x: arrowEnd.x - cos(angle + spread) * len, y: arrowEnd.y - sin(angle + spread) * len))
        p.closeSubpath()
        return p
    }
}

@MainActor func render(scale: CGFloat, to path: String) {
    let renderer = ImageRenderer(content: Background().environment(\.colorScheme, .light))
    renderer.scale = scale
    guard let image = renderer.cgImage,
          let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)
    else { exit(1) }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { exit(1) }
}

MainActor.assumeIsolated {
    render(scale: 1, to: CommandLine.arguments[1])
    render(scale: 2, to: CommandLine.arguments[2])
}
