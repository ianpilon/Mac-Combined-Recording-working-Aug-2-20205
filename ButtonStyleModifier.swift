import SwiftUI

// Custom modifier to handle styling properly regardless of macOS version
struct ButtonStyleModifier: ViewModifier {
    let color: Color
    
    func body(content: Content) -> some View {
        // Use traditional styling approaches for backward compatibility
        content
            .foregroundColor(.white)
            .background(color)
    }
}
