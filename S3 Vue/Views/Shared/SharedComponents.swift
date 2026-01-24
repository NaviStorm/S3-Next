import SwiftUI

#if os(macOS)
    import AppKit

    struct VisualEffectView: NSViewRepresentable {
        let material: NSVisualEffectView.Material
        let blendingMode: NSVisualEffectView.BlendingMode

        func makeNSView(context: Context) -> NSVisualEffectView {
            let view = NSVisualEffectView()
            view.material = material
            view.blendingMode = blendingMode
            view.state = .active
            return view
        }

        func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
            nsView.material = material
            nsView.blendingMode = blendingMode
        }
    }
#endif

struct Badge: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.2))
            .foregroundColor(color)
            .cornerRadius(6)
    }
}

struct SecurityCard<Content: View>: View {
    let title: String
    let icon: String
    let color: Color
    var isWarning: Bool = false
    let content: Content

    init(
        title: String, icon: String, color: Color, isWarning: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.icon = icon
        self.color = color
        self.isWarning = isWarning
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(color)
                    .font(.headline)
                Text(title)
                    .font(.headline)
                Spacer()
                if isWarning {
                    Image(systemName: "exclamationmark.shield.fill")
                        .foregroundColor(.red)
                }
            }

            content
        }
        .padding(20)
        #if os(macOS)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        #else
            .background(Color(UIColor.secondarySystemGroupedBackground))
        #endif
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(
                    isWarning ? Color.red.opacity(0.3) : Color.primary.opacity(0.1), lineWidth: 1)
        )
    }
}
