import SwiftUI

struct ToastView: View {
    @Binding var message: String?
    var type: ToastType = .info

    var body: some View {
        if let msg = message {
            VStack {
                // Sur macOS on peut le mettre en haut ou en bas, ici on reste sur le style existant
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
