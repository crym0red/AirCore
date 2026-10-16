//
//  PhoneIcon.swift
//  Small phone glyph used next to "This device" in the certificate and account screens.
//

import SwiftUI

struct PhoneIcon: View {
    var height: CGFloat = 24

    var body: some View {
        Image(systemName: "iphone")
            .resizable()
            .scaledToFit()
            .frame(height: height)
            .foregroundStyle(Theme.accent)
    }
}
