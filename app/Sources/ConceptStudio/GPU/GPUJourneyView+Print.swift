import SwiftUI

extension GPUJourneyView {
    /// One line of the plan, set like a receipt: the item, a rule, the value.
    func receiptRow(_ label: String, _ value: String) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(label).foregroundStyle(InstantPrint.inkSecondary)
                Spacer(minLength: 12)
                Text(value).fontWeight(.medium).monospacedDigit().multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
            .font(.system(size: 14)).padding(.vertical, 8)
            Rectangle().fill(InstantPrint.rule).frame(height: 1)
        }
        .accessibilityElement(children: .combine)
    }
}
