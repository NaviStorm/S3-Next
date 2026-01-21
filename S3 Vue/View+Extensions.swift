import SwiftUI

extension View {
    func customBorder(_ color: Color, width: CGFloat, edges: [Edge]) -> some View {
        overlay(
            GeometryReader { geometry in
                let w = geometry.size.width
                let h = geometry.size.height
                Path { path in
                    if edges.contains(.top) {
                        path.move(to: CGPoint(x: 0, y: 0))
                        path.addLine(to: CGPoint(x: w, y: 0))
                    }
                    if edges.contains(.bottom) {
                        path.move(to: CGPoint(x: 0, y: h))
                        path.addLine(to: CGPoint(x: w, y: h))
                    }
                    if edges.contains(.leading) {
                        path.move(to: CGPoint(x: 0, y: 0))
                        path.addLine(to: CGPoint(x: 0, y: h))
                    }
                    if edges.contains(.trailing) {
                        path.move(to: CGPoint(x: w, y: 0))
                        path.addLine(to: CGPoint(x: w, y: h))
                    }
                }
                .stroke(color, lineWidth: width)
            }
        )
    }
}
