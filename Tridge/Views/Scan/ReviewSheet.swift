import SwiftUI

/// Post-scan confirmation: fix anything odd, then add everything in one tap.
struct ReviewSheet: View {
    @Bindable var model: ScanFlowModel
    let session: HouseholdSession

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
                    model.confirm(into: session)
                } label: {
                    Text("Add \(model.reviewItems.count) item\(model.reviewItems.count == 1 ? "" : "s") to Fridge")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(AppTheme.brandGreen, in: RoundedRectangle(cornerRadius: 14))
                        .shadow(color: AppTheme.brandGreen.opacity(0.35), radius: 8, y: 6)
                }
                .disabled(model.reviewItems.isEmpty || model.isSaving)
                .accessibilityIdentifier("review.confirmButton")
                .padding(.horizontal, 14)
                .padding(.bottom, 6)
            }
        }
        .presentationDragIndicator(.visible)
        // The draft stays open behind the alert, so a refused save can be
        // corrected or retried with the same preallocated ids.
        .alert("Couldn't add these", isPresented: failureBinding) {
            Button("OK", role: .cancel) { session.clearFailure() }
        } message: {
            Text(session.lastFailure?.message ?? "")
        }
    }

    private var subtitle: String {
        let date = model.reviewPurchaseDay.startOfDay(in: .current) ?? Date()
        let day = date.formatted(.dateTime.month(.abbreviated).day())
        return "\(day) · \(model.reviewItems.count) item\(model.reviewItems.count == 1 ? "" : "s") found"
    }

    private var failureBinding: Binding<Bool> {
        Binding(get: { session.lastFailure != nil },
                set: { if !$0 { session.clearFailure() } })
    }
}
