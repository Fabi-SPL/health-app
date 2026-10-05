import SwiftUI

/// Floating action button — plus icon, expands to FABMenu.
struct FABButton: View {
    @Binding var isOpen: Bool

    @State private var isPressed = false

    var body: some View {
        Button {
            DS.Haptic.commit()
            withAnimation(DS.Anim.standard) { isOpen.toggle() }
        } label: {
            ZStack {
                Circle()
                    .fill(DS.Colors.violet)
                    .frame(width: 56, height: 56)


                Image(systemName: isOpen ? "xmark" : "plus")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .rotationEffect(.degrees(isOpen ? 45 : 0))
                    .animation(DS.Anim.standard, value: isOpen)
            }
            .scaleEffect(isPressed ? 0.92 : 1.0)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in withAnimation(DS.Anim.quick) { isPressed = true } }
                .onEnded   { _ in withAnimation(DS.Anim.quick) { isPressed = false } }
        )
    }
}
