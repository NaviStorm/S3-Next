import SwiftUI

enum ToastType {
    case info
    case error
    case success

    var color: Color {
        switch self {
        case .info: return .blue
        case .error: return .red
        case .success: return .green
        }
    }

    var icon: String {
        switch self {
        case .info: return "info.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .success: return "checkmark.circle.fill"
        }
    }
}

struct ToastView: View {
    @Binding var message: String?
    var type: ToastType = .info

    var body: some View {
        if let msg = message {
            VStack {
                Spacer()
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: type.icon)
                        .foregroundColor(.white)
                    Text(msg)
                        .foregroundColor(.white)
                        .font(.subheadline)
                        .fontWeight(.medium)
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 16)
                .background(type.color.opacity(0.9))
                .cornerRadius(24)
                .shadow(radius: 4)
                .padding(.bottom, 50)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .onTapGesture {
                    withAnimation {
                        message = nil
                    }
                }
            }
            .animation(.spring(), value: message)
            .zIndex(100)
        }
    }
}
