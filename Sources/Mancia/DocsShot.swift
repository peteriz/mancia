import AppKit
import SwiftUI

/// Renders the README's hero image: the real `RibbonView`, laid over a mock
/// document, drawn straight to a PNG.
///
/// It is a render rather than a screen grab so the picture can be regenerated
/// from source — `make shot` — instead of re-staged by hand every time the lane
/// changes. The ribbon in it is the shipping view with the shipping palette; the
/// only thing invented is the document underneath, which stands in for whatever
/// app the user is actually writing in.
///
/// The geometry mirrors `RibbonPlacement`: the lane takes the host window's
/// width up to `maximumWidth`, sits centered on it, and hangs
/// `selectionClearance` below the selected text.
@MainActor
enum DocsShot {
    /// Written at 2x, the way a Retina screenshot arrives.
    private static let scale: CGFloat = 2

    static func render(to path: String) throws {
        let model = PanelModel()
        model.hasSelection = true
        model.selectionCharCount = Copy.selection.joined(separator: " ").count
        model.focusedCell = .run

        let scene = ShotScene(model: model)
        let host = NSHostingView(rootView: scene)
        host.safeAreaRegions = []
        host.frame = CGRect(origin: .zero, size: Layout.canvas)

        // A real window, off screen: `NSHostingView` needs one to complete a
        // layout pass, and drawing through the view's own backing store keeps
        // this free of the Screen Recording permission a capture would need.
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.setFrameOrigin(CGPoint(x: -20000, y: -20000))
        // Key, not merely ordered in: AppKit washes the text of an *inactive*
        // window's unfocused field in the secondary selection grey, which lands
        // on the typed instruction and reads as a smudge.
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        // SwiftUI resolves fonts, symbols and materials over a few turns of the
        // run loop; drawing before it settles yields a half-built lane.
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))

        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(Layout.canvas.width * scale),
                pixelsHigh: Int(Layout.canvas.height * scale),
                // `cacheDisplay` draws into a transparent context and needs the
                // alpha channel; the scene fills the canvas, so every pixel
                // comes back opaque anyway.
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { throw ShotError.allocationFailed }
        // Points, not pixels: `cacheDisplay` scales the context from the ratio
        // between this and the pixel dimensions above.
        rep.size = Layout.canvas
        host.cacheDisplay(in: host.bounds, to: rep)
        window.orderOut(nil)

        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw ShotError.encodingFailed
        }
        try data.write(to: URL(fileURLWithPath: path))
    }

    enum ShotError: LocalizedError {
        case allocationFailed
        case encodingFailed

        var errorDescription: String? {
            switch self {
            case .allocationFailed: return "Could not allocate the bitmap."
            case .encodingFailed: return "Could not encode the PNG."
            }
        }
    }
}

// MARK: - Scene

/// Fixed geometry for the shot, in points. Every position is a constant so the
/// lane lands exactly `RibbonPlacement.selectionClearance` under the last
/// selected line rather than wherever a stack happens to put it.
private enum Layout {
    static let canvas = CGSize(width: 1160, height: 574)
    static let window = CGRect(x: 80, y: 44, width: 1000, height: 486)
    static let titleBar: CGFloat = 40
    static let bodyInset: CGFloat = 40
    static let lineHeight: CGFloat = 30
    static let ribbonWidth = RibbonPlacement.standardWidth

    /// Top of the first body line, below the title bar and the heading.
    static let textTop = window.minY + titleBar + 34 + 42
    static let paragraphGap: CGFloat = 16
    /// Where the selected paragraph starts and stops.
    static let selectionTop = textTop + 3 * lineHeight + paragraphGap
    static let selectionBottom = selectionTop + 3 * lineHeight
    static let ribbonTop = selectionBottom + RibbonPlacement.selectionClearance
    static let ribbonX = window.minX + (window.width - ribbonWidth) / 2
}

private enum Copy {
    static let title = "New Message"
    static let heading = "Re: Thursday rollout"
    static let lead = [
        "Thanks for the notes, everyone — genuinely useful, and between them they",
        "cover most of what came up in the review last week. Two things are still",
        "open, and I have put both of them below.",
    ]
    static let selection = [
        "I think it is probably fine for us to go ahead and ship on Thursday,",
        "assuming nothing else comes up between now and then, though we can",
        "obviously revisit this if anyone feels strongly about it either way.",
    ]
    static let sign = "— Dana"
}

private enum Ink {
    static let text = Color(hex: 0x1F1B15)
    static let faint = Color(hex: 0x8B8271)
    static let paper = Color(hex: 0xFDFBF6)
    static let chrome = Color(hex: 0xF1ECE2)
    static let edge = Color(hex: 0xDED5C4)
    /// The macOS text-selection wash, so the picture reads as a real selection
    /// rather than a highlighter.
    static let selection = Color(hex: 0xB6D5FB)
}

/// The whole picture: desktop, document, lane.
private struct ShotScene: View {
    @Bindable var model: PanelModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Flat rather than a gradient: a gradient this wide is dithered,
            // and the dither costs the README image an order of magnitude in
            // file size for something nobody looks at.
            Color(hex: 0xE7DECC)
                .frame(width: Layout.canvas.width, height: Layout.canvas.height)

            documentWindow
                .frame(width: Layout.window.width, height: Layout.window.height)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.black.opacity(0.12), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.22), radius: 44, y: 20)
                .offset(x: Layout.window.minX, y: Layout.window.minY)

            RibbonView(
                model: model, width: Layout.ribbonWidth, anchor: .belowSelection, isLive: false
            )
            // The lane's shadow is drawn by the window server in the app; here
            // it has to be drawn with it.
            .shadow(color: .black.opacity(0.28), radius: 20, y: 10)
            .offset(x: Layout.ribbonX, y: Layout.ribbonTop)
        }
        .frame(width: Layout.canvas.width, height: Layout.canvas.height, alignment: .topLeading)
        // The document is a light-appearance surface whatever the machine
        // rendering it is set to; the lane keeps its own fixed dark register.
        .environment(\.colorScheme, .light)
    }

    private var documentWindow: some View {
        VStack(spacing: 0) {
            titleBar
            Rectangle().fill(Ink.edge).frame(height: 1)
            documentBody
        }
        .background(Ink.paper)
    }

    private var titleBar: some View {
        ZStack {
            Ink.chrome
            HStack(spacing: 8) {
                trafficLight(0xFF5F57)
                trafficLight(0xFEBC2E)
                trafficLight(0x28C840)
                Spacer()
            }
            .padding(.leading, 16)
            Text(Copy.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Ink.faint)
        }
        .frame(height: Layout.titleBar)
    }

    private func trafficLight(_ hex: Int) -> some View {
        Circle().fill(Color(hex: hex)).frame(width: 12, height: 12)
    }

    private var documentBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(Copy.heading)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Ink.text)
                .frame(height: 42, alignment: .top)
            paragraph(Copy.lead, selected: false)
            Spacer().frame(height: Layout.paragraphGap)
            paragraph(Copy.selection, selected: true)
            Spacer().frame(height: Layout.lineHeight * 3)
            Text(Copy.sign)
                .font(.system(size: 15.5))
                .foregroundStyle(Ink.faint)
                .frame(height: Layout.lineHeight, alignment: .top)
            Spacer(minLength: 0)
        }
        .padding(.top, 34)
        .padding(.horizontal, Layout.bodyInset)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Line-by-line so the selection wash can hug each line the way a real one
    /// does, and so the lane's offset can be computed from line counts.
    private func paragraph(_ lines: [String], selected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(lines, id: \.self) { line in
                Text(line)
                    .font(.system(size: 15.5))
                    .foregroundStyle(Ink.text)
                    .padding(.horizontal, selected ? 3 : 0)
                    .frame(height: Layout.lineHeight, alignment: .center)
                    .background(selected ? Ink.selection : .clear)
            }
        }
    }
}
