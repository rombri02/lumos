// Renders the app icon glyph, same as the in-app header (wand.and.rays, black 75%).
// Usage: swiftc icon.swift -o /tmp/mkicon && /tmp/mkicon out.png   (build.sh does this)
import SwiftUI

// Foreground layer of AppIcon.icon: the glyph alone on a transparent 1024 canvas.
// The yellow gradient background is the .icon's fill, so macOS 27 masks and lights it natively.
struct Glyph: View {
    var body: some View {
        Image(systemName: "wand.and.rays")
            .font(.system(size: 490, weight: .semibold))
            .foregroundStyle(Color.black.opacity(0.75))
            .frame(width: 1024, height: 1024)
    }
}

@MainActor func render() {
    let renderer = ImageRenderer(content: Glyph())
    renderer.scale = 1
    guard let image = renderer.cgImage,
          let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL,
                                                     "public.png" as CFString, 1, nil) else { exit(1) }
    CGImageDestinationAddImage(dest, image, nil)
    exit(CGImageDestinationFinalize(dest) ? 0 : 1)
}

MainActor.assumeIsolated { render() }
