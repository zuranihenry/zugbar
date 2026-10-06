import SwiftUI

/// Liquid Glass on macOS 26 and later, the regular look before.
/// Settings → Debug → "Classic design" forces the regular look for comparison.
private struct GlassStyle<S: Shape>: ViewModifier {
    let shape: S
    var tint: Color?
    var interactive = false
    let fallback: AnyShapeStyle
    @AppStorage("classicDesign") private var classicDesign = false

    func body(content: Content) -> some View {
        #if compiler(>=6.2) // Liquid Glass needs the macOS 26 SDK (Xcode 26)
        if #available(macOS 26, *), !classicDesign {
            content.glassEffect(.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            content.background(fallback, in: shape)
        }
        #else
        content.background(fallback, in: shape)
        #endif
    }
}

private struct ActionButtonStyle: ViewModifier {
    @AppStorage("classicDesign") private var classicDesign = false

    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *), !classicDesign {
            content.buttonStyle(.glass)
        } else {
            content.buttonStyle(.bordered)
        }
        #else
        content.buttonStyle(.bordered)
        #endif
    }
}

/// In classic mode the popover gets the vibrant material popovers had before macOS 26.
struct ClassicBackground: ViewModifier {
    @AppStorage("classicDesign") private var classicDesign = false

    func body(content: Content) -> some View {
        if classicDesign {
            content.background(VisualEffect().ignoresSafeArea())
        } else {
            content
        }
    }
}

private struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

extension View {
    func cardStyle() -> some View {
        modifier(GlassStyle(shape: RoundedRectangle(cornerRadius: 12), fallback: AnyShapeStyle(.quinary)))
    }

    func chipStyle(selected: Bool = false) -> some View {
        modifier(GlassStyle(
            shape: Capsule(), tint: selected ? .accentColor : nil, interactive: true,
            fallback: selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary)
        ))
    }

    /// Small capsule for labels like the provider name.
    func badgeStyle() -> some View {
        modifier(GlassStyle(shape: Capsule(), fallback: AnyShapeStyle(.quaternary)))
    }

    func mapButtonStyle() -> some View {
        modifier(GlassStyle(shape: Circle(), interactive: true, fallback: AnyShapeStyle(.regularMaterial)))
    }

    func actionButtonStyle() -> some View {
        modifier(ActionButtonStyle())
    }
}
