import OffboardingCore
import SwiftUI

/// Always-visible mode indicator so simulation cannot be mistaken for production (and vice versa).
struct ModeBanner: View {
    let mode: ExecutionMode

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: mode == .simulation ? "testtube.2" : "exclamationmark.triangle.fill")
            Text(mode == .simulation
                 ? "SIMULATION MODE — no changes will be made"
                 : "PRODUCTION MODE — actions affect real devices")
                .fontWeight(.bold)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .foregroundStyle(.white)
        .background(mode == .simulation ? Color.orange : Color.red)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}
