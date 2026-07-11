import SwiftUI
import SwiftData

/// Post-scan confirmation: fix anything odd, then add everything in one tap.
struct ReviewSheet: View {
    @Bindable var model: ScanFlowModel
    @Environment(\.modelContext) private var context
    @AppStorage("notificationHour") private var notificationHour = 9

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach($model.reviewItems) { $item in
                        ReviewRow(item: $item)
                    }
                    .onDelete { model.reviewItems.remove(atOffsets: $0) }
                } header: {
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(AppTheme.mutedInk)
                        .textCase(nil)
                }
            }
            .listStyle(.plain)
            .navigationTitle("Receipt scanned 🧾")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                Button {
                    model.confirm(into: context, notificationHour: notificationHour)
                } label: {
                    Text("Add \(model.reviewItems.count) item\(model.reviewItems.count == 1 ? "" : "s") to Fridge")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(AppTheme.brandGreen, in: RoundedRectangle(cornerRadius: 14))
                        .shadow(color: AppTheme.brandGreen.opacity(0.35), radius: 8, y: 6)
                }
                .disabled(model.reviewItems.isEmpty)
                .accessibilityIdentifier("review.confirmButton")
                .padding(.horizontal, 14)
                .padding(.bottom, 6)
            }
        }
        .presentationDragIndicator(.visible)
    }

    private var subtitle: String {
        let date = model.reviewPurchaseDate.formatted(.dateTime.month(.abbreviated).day())
        return "\(date) · \(model.reviewItems.count) item\(model.reviewItems.count == 1 ? "" : "s") found"
    }
}
