import SwiftUI

struct RootView: View {
    private var service = ChangeService.shared

    var body: some View {
        Group {
            if service.isConfigured {
                OverviewView()
            } else {
                SetupView()
            }
        }
        .tint(Color.accentColor)
    }
}
