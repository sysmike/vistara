import SwiftUI

/// What an import did, above the list until closed. Not an alert: nothing
/// needs a decision (HIG Alerts).
struct ImportNotice: View {
    let report: ImportReport
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: report.failures.isEmpty && report.droppedPasswords.isEmpty
                ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(report.failures.isEmpty && report.droppedPasswords.isEmpty ? .green : .orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(report.sentences, id: \.self) { Text($0) }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Close")
            .accessibilityLabel("Close")
        }
        .padding(12)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}
