import AppKit
import SwiftUI

/// Draws a button label in small text inside a capsule with a faint primary-colour fill and a
/// thin primary-colour border; the fill darkens while the button is pressed.
struct CoffeeButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: NSFont.smallSystemFontSize))
      .foregroundStyle(.primary)
      .padding(.horizontal, 10)
      .padding(.vertical, 4)
      // Native bordered buttons ignore capsule border shapes on macOS 14.
      .background(.primary.opacity(configuration.isPressed ? 0.12 : 0.04), in: Capsule())
      .overlay {
        Capsule().strokeBorder(.primary.opacity(0.2), lineWidth: 1)
      }
  }
}
