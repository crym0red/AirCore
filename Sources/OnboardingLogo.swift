import SwiftUI
import UIKit

/// Shared AirShare branding used by onboarding and account flows.
/// The logo is stored in Sources/Resources rather than Assets.xcassets,
/// so load it explicitly from the application bundle.
struct OnboardingLogo: View {
    let size: CGFloat

    var body: some View {
        Group {
            if let image = Self.logoImage() {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                        .fill(Color.green.opacity(0.14))
                    Image(systemName: "signature")
                        .font(.system(size: size * 0.48, weight: .bold))
                        .foregroundStyle(Color.green)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .stroke(Color.green.opacity(0.30), lineWidth: 1)
        }
        .shadow(color: Color.green.opacity(0.22), radius: size * 0.22, y: size * 0.08)
        .accessibilityLabel("AirShare")
    }

    private static func logoImage() -> UIImage? {
        guard let url = Bundle.main.url(forResource: "AirShareLogo", withExtension: "png"),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return UIImage(data: data)
    }
}
