import SwiftUI

struct IslandRootView: View {
    let model: IslandModel

    var body: some View {
        let size = model.islandSize
        let radii = IslandLayout.radii(for: model.mode, notch: model.notch)
        let shape = NotchShape(topRadius: radii.top, bottomRadius: radii.bottom)

        let open = model.mode == .peek || model.mode == .expanded

        ZStack(alignment: .top) {
            ZStack(alignment: .top) {
                // What sits beside the notch, then the peek's text or the tiles.
                BandRow(model: model, onTintedGlass: open)
                    .frame(width: size.width, height: model.notch.height)
                IslandBody(model: model)
                    .padding(.top, model.notch.height)
            }
            .frame(width: size.width, height: size.height, alignment: .top)
            // One Liquid Glass shape for the whole island: clear like the menu bar as the pill,
            // tinted toward the theme when open. The tiles stay matte on top of it.
            .modifier(IslandGlass(shape: shape, tint: open ? model.palette.background.opacity(IslandGlass<NotchShape>.tintStrength) : nil,
                                  visible: model.mode != .resting))
            // The black core, on top of the glass: under a real notch it is invisible, without
            // one it is the notch.
            NotchCore(model: model)
        }
            .frame(width: size.width, height: size.height, alignment: .top)
            .clipShape(shape)
            .contentShape(shape)
            .onTapGesture { model.onTap() }
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { model.drawnFrame = proxy.frame(in: .global) }
                        .onChange(of: proxy.frame(in: .global)) { _, frame in model.drawnFrame = frame }
                }
            }
            .offset(x: model.centerOffsetX)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .ignoresSafeArea()
    }
}

/// The island's soft shadow, drawn in its own click-through window under the island. The
/// island's own shape is cut out of it, so only the shadow itself is ever visible.
struct IslandShadowView: View {
    let model: IslandModel

    var body: some View {
        let size = model.islandSize
        let radii = IslandLayout.radii(for: model.mode, notch: model.notch)

        NotchShape(topRadius: radii.top, bottomRadius: radii.bottom)
            .fill(Color.black)
            .frame(width: size.width, height: size.height)
            .shadow(color: .black.opacity(model.mode == .peek || model.mode == .expanded ? 0.28 : 0), radius: 10, x: 0, y: 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .mask {
                IslandCutout(width: size.width, height: size.height, topRadius: radii.top, bottomRadius: radii.bottom)
                    .fill(style: FillStyle(eoFill: true))
            }
            .offset(x: model.shadowOffsetX)
            .ignoresSafeArea()
    }
}

/// Everything except the island's shape, top-centred. Animates with the same values as the
/// island so the cutout tracks it through the spring.
struct IslandCutout: Shape {
    var width: CGFloat
    var height: CGFloat
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(width, height), AnimatablePair(topRadius, bottomRadius)) }
        set {
            width = newValue.first.first; height = newValue.first.second
            topRadius = newValue.second.first; bottomRadius = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path(rect)
        let hole = CGRect(x: rect.midX - width / 2, y: rect.minY, width: width, height: height)
        p.addPath(NotchShape(topRadius: topRadius, bottomRadius: bottomRadius).path(in: hole))
        return p
    }
}

/// Liquid Glass where macOS has it (26 and later). On 14 and 15 the closest thing: the theme
/// colour when tinted, otherwise the menu bar's own blur of what is behind the window.
private struct IslandGlass<S: Shape>: ViewModifier {
    let shape: S
    let tint: Color?
    let visible: Bool

    /// How strongly the open island leans toward the theme colour. An opaque tint would turn
    /// the glass into a flat panel; this keeps it glass, with the tiles readable on top.
    static var tintStrength: Double { 0.45 }

    // Every branch below is fixed for the life of the app (OS version, self-test or not), and
    // "visible" only changes values inside one branch. Switching branches when the island opens
    // would make SwiftUI tear down and rebuild everything inside it: tiles would be created
    // twice and a drag in progress would be lost.
    func body(content: Content) -> some View {
        if Diag.selfTest {
            // Glass cannot be captured offscreen, so the self-test sees a flat fill of the same
            // shape: what it measures (shape, springs, clicks) is unchanged.
            content.background(visible ? Color(white: 0.5) : .clear, in: shape)
        } else if #available(macOS 26.0, *) {
            content.glassEffect(visible ? .regular.tint(tint) : .identity, in: shape)
        } else {
            content.background {
                ZStack {
                    BehindWindowBlur()
                    shape.fill(tint ?? .clear)
                }
                .clipShape(shape)
                .opacity(visible ? 1 : 0)
            }
        }
    }
}

/// The menu bar's material, blurring whatever is behind the window (macOS 14 and 15 only).
private struct BehindWindowBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .menu
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

private struct NotchCore: View {
    let model: IslandModel

    var body: some View {
        let core = model.size(for: .resting)
        let radii = IslandLayout.radii(for: .resting, notch: model.notch)
        NotchShape(topRadius: radii.top, bottomRadius: radii.bottom)
            .fill(Palette.band)
            .frame(width: core.width, height: core.height)
    }
}

/// The island's outline: concave corners at the top that flow into the screen edge, like the
/// hardware notch, and rounded corners at the bottom.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let t = max(0, min(topRadius, rect.width / 4, rect.height / 2))
        let b = max(0, min(bottomRadius, (rect.width - 2 * t) / 2, rect.height - t))
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t, y: rect.minY + t),
                       control: CGPoint(x: rect.minX + t, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + t, y: rect.maxY - b))
        p.addArc(tangent1End: CGPoint(x: rect.minX + t, y: rect.maxY),
                 tangent2End: CGPoint(x: rect.minX + t + b, y: rect.maxY), radius: b)
        p.addLine(to: CGPoint(x: rect.maxX - t - b, y: rect.maxY))
        p.addArc(tangent1End: CGPoint(x: rect.maxX - t, y: rect.maxY),
                 tangent2End: CGPoint(x: rect.maxX - t, y: rect.maxY - b), radius: b)
        p.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY + t))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                       control: CGPoint(x: rect.maxX - t, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

/// What sits under the notch's level: the peek's text or the tiles.
private struct IslandBody: View {
    let model: IslandModel

    var body: some View {
        VStack(spacing: 0) {
            switch model.mode {
            case .peek:
                if let peek = model.peek {
                    PeekBody(peek: peek, palette: model.palette)
                        .id(peek.id)
                        .transition(.opacity)
                }
            case .expanded:
                ExpandedBody(model: model)
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            case .resting, .compact:
                EmptyView()
            }
        }
    }
}

/// What sits level with the notch, either side of it. On clear glass it uses adaptive colours,
/// like menu bar items; on glass tinted to the theme, the theme's text colour.
private struct BandRow: View {
    let model: IslandModel
    let onTintedGlass: Bool

    var body: some View {
        let ink: Color = onTintedGlass ? model.palette.text : .primary
        HStack(spacing: 0) {
            Group {
                if let activity = model.activity {
                    IconView(icon: activity.leading, size: 16, tint: ink)
                }
            }
            .frame(width: IslandLayout.wing)

            Color.clear.frame(width: model.notch.width)

            Group {
                switch model.activity?.trailing {
                case .grid?: ActivityGrid(color: ink)
                case .waveform?: Waveform(color: ink)
                case .text(let text)?:
                    Text(text)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(ink)
                        .lineLimit(1)
                case .none?, nil: EmptyView()
                }
            }
            .frame(width: IslandLayout.wing)
        }
        .frame(maxWidth: .infinity)
        .opacity(model.mode == .resting ? 0 : 1)
    }
}

private struct PeekBody: View {
    let peek: PeekContent
    let palette: Palette

    var body: some View {
        HStack(spacing: 10) {
            IconView(icon: peek.icon, size: 24, tint: palette.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(peek.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.text)
                    .lineLimit(1)
                if let subtitle = peek.subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(palette.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .frame(height: IslandLayout.peekBodyHeight)
    }
}

/// The open island: the row of tiles under the notch strip.
private struct ExpandedBody: View {
    let model: IslandModel

    var body: some View {
        VStack(spacing: 0) {
            if let card = model.claude {
                // A new view (and a new scroll position) for every request: reusing the last
                // one's scroll offset could open the next request part way down, with its start
                // never on screen.
                ClaudeCardView(model: model, card: card)
                    .id(card.id)
                    .frame(height: IslandLayout.claudeCardHeight - IslandLayout.bodyTop - IslandLayout.bodyBottom)
            } else {
                TilesRow(model: model)
            }
            if model.claude == nil && model.showsLyricsRow {
                LyricsRow(model: model)
                    .frame(height: IslandLayout.lyricsRowHeight)
                    .transition(.opacity)
            }
        }
            .padding(.top, IslandLayout.bodyTop)
            .padding(.bottom, IslandLayout.bodyBottom)
            .frame(width: model.size(for: .expanded).width,
                   height: model.size(for: .expanded).height - model.notch.height, alignment: .top)
    }
}

struct IconView: View {
    let icon: IslandIcon
    let size: CGFloat
    let tint: Color

    var body: some View {
        switch icon {
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: size * 0.8, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
        case .image(let image):
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        }
    }
}

/// Four bars bouncing out of step while music plays.
struct Waveform: View {
    let color: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    let phase = Double(i) * 1.7
                    let level = 0.35 + 0.65 * abs(sin(t * (3.1 + Double(i) * 0.6) + phase))
                    Capsule().fill(color).frame(width: 2.5, height: 4 + 10 * level)
                }
            }
            .frame(height: 14)
        }
        .accessibilityLabel("Playing")
    }
}

/// The small animated grid shown while Claude is working: a wave runs across a 3 x 3 grid.
struct ActivityGrid: View {
    let color: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            VStack(spacing: 2) {
                ForEach(0..<3, id: \.self) { row in
                    HStack(spacing: 2) {
                        ForEach(0..<3, id: \.self) { col in
                            let wave = 0.5 + 0.5 * sin(t * 5 - Double(row + col) * 0.7)
                            RoundedRectangle(cornerRadius: 1)
                                .fill(color.opacity(0.25 + 0.75 * wave))
                                .frame(width: 4, height: 4)
                        }
                    }
                }
            }
        }
        .accessibilityLabel("Working")
    }
}
