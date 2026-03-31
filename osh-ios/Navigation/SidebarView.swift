import SwiftUI

// MARK: - SidebarView
//
// Overlay-style sidebar that slides in from the leading edge.
// Width: 260 pt. Background tap dismisses it.
// Entries: Main, Garmin, Settings.

struct SidebarView: View {
    @EnvironmentObject private var nav: AppNavigationState

    var body: some View {
        ZStack(alignment: .leading) {
            // Dim background — tap to dismiss
            if nav.sidebarOpen {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .onTapGesture { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { nav.sidebarOpen = false } }
                    .transition(.opacity)
            }

            // Drawer
            if nav.sidebarOpen {
                drawerContent
                    .frame(width: 260)
                    .frame(maxHeight: .infinity)
                    .background(Color(UIColor.systemBackground))
                    .shadow(color: .black.opacity(0.18), radius: 12, x: 4, y: 0)
                    .transition(.move(edge: .leading))
                    .ignoresSafeArea(edges: .vertical)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: nav.sidebarOpen)
    }

    // MARK: - Drawer content

    private var drawerContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            Text("OSH Sensor Hub")
                .font(.headline)
                .padding(.horizontal, 20)
                .padding(.top, 60)
                .padding(.bottom, 20)

            Divider()

            // Nav rows
            navRow(tab: .main,     icon: "sensor.tag.radiowaves.forward.fill", label: "Sensors")
            navRow(tab: .garmin,   icon: "applewatch",                          label: "Garmin")

            Divider().padding(.vertical, 8)

            navRow(tab: .settings, icon: "gear",                               label: "Settings")

            Spacer()
        }
    }

    private func navRow(tab: AppTab, icon: String, label: String) -> some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                nav.open(tab)
            }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .frame(width: 24)
                    .foregroundStyle(nav.selectedTab == tab ? Color.accentColor : Color.primary)
                Text(label)
                    .foregroundStyle(nav.selectedTab == tab ? Color.accentColor : Color.primary)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(
                nav.selectedTab == tab
                    ? Color.accentColor.opacity(0.12)
                    : Color.clear
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    let nav = AppNavigationState()
    nav.sidebarOpen = true
    return ZStack {
        Color(UIColor.secondarySystemBackground).ignoresSafeArea()
        SidebarView()
    }
    .environmentObject(nav)
}
