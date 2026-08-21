import SwiftUI
import UIKit

// MARK: - LogsTabView
//
// The in-app tail of the log, newest at the bottom like a terminal.
//
// Auto-scroll follows the tail only while the user is already there. Yanking
// the view back to the bottom while someone is reading an error further up is
// the classic way to make a log viewer useless, so scrolling up pauses the
// follow and offers an explicit way back.

struct LogsTabView: View {

    @StateObject private var model = LogsViewModel()

    /// Bottom anchor for the auto-scroll target.
    private static let tailID = "log-tail"

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                filterBar
                Divider()
                logList
            }
            .navigationTitle("Logs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Copy last 200", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = model.copyText(limit: 200)
                        }
                        Button("Clear", systemImage: "trash", role: .destructive) {
                            Task { await model.clear() }
                        }
                    } label: {
                        Label("Actions", systemImage: "ellipsis.circle")
                    }
                }
            }
            .task { await model.start() }
        }
    }

    // MARK: Filters

    private var filterBar: some View {
        VStack(spacing: 8) {
            Picker("Level", selection: $model.levelFilter) {
                ForEach(LogsViewModel.LevelFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.segmented)

            HStack {
                Menu {
                    Button("All categories") { model.category = nil }
                    Divider()
                    ForEach(Log.categories, id: \.self) { category in
                        Button(category) { model.category = category }
                    }
                } label: {
                    Label(model.category ?? "All categories", systemImage: "line.3.horizontal.decrease.circle")
                        .font(.subheadline)
                }
                Spacer()
                Text("\(model.filtered.count) lines")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: List

    private var logList: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottom) {
                List {
                    ForEach(model.filtered) { entry in
                        LogRow(entry: entry)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 2, leading: 12, bottom: 2, trailing: 12))
                            .onAppear { model.noteAppeared(entry) }
                            .onDisappear { model.noteDisappeared(entry) }
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(Self.tailID)
                        .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
                .onChange(of: model.filtered.count) { _, _ in
                    guard model.isFollowingTail else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(Self.tailID, anchor: .bottom)
                    }
                }

                if !model.isFollowingTail {
                    Button {
                        model.isFollowingTail = true
                        withAnimation { proxy.scrollTo(Self.tailID, anchor: .bottom) }
                    } label: {
                        Label("Jump to latest", systemImage: "arrow.down")
                            .font(.footnote.weight(.medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(.thinMaterial, in: Capsule())
                    }
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: model.isFollowingTail)
        }
    }
}

// MARK: - LogRow

struct LogRow: View {

    let entry: LogEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(Self.timeFormatter.string(from: entry.date))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)

            Text(entry.category)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(levelColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
                .foregroundStyle(levelColor)

            Text(entry.message)
                .font(.caption.monospaced())
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .textSelection(.enabled)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.level.label) \(entry.category): \(entry.message)")
    }

    private var levelColor: Color {
        switch entry.level {
        case .debug:            return .secondary
        case .info, .notice:    return .blue
        case .warning:          return .orange
        case .error, .fault:    return .red
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}

// MARK: - LogsViewModel
//
// Holds the visible slice of the log and tracks whether the user is at the
// tail. Kept off the view so filtering does not re-run on every layout pass.

@MainActor
final class LogsViewModel: ObservableObject {

    enum LevelFilter: String, CaseIterable, Identifiable {
        case all, info, warning, error

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all:     return "All"
            case .info:    return "Info+"
            case .warning: return "Warn+"
            case .error:   return "Error"
            }
        }

        var minimum: LogLevel {
            switch self {
            case .all:     return .debug
            case .info:    return .info
            case .warning: return .warning
            case .error:   return .error
            }
        }
    }

    @Published private(set) var entries: [LogEntry] = []
    @Published var levelFilter: LevelFilter = .all
    @Published var category: String?
    @Published var isFollowingTail = true

    /// Rows currently on screen. The tail is "followed" while the newest
    /// visible row is the newest row there is.
    private var visibleIDs: Set<UInt64> = []
    private var streamTask: Task<Void, Never>?

    var filtered: [LogEntry] {
        entries.filter { entry in
            entry.level >= levelFilter.minimum
                && (category == nil || entry.category == category)
        }
    }

    func start() async {
        guard streamTask == nil else { return }
        entries = await LogStore.shared.snapshot()
        let stream = await LogStore.shared.updates()
        streamTask = Task { [weak self] in
            for await entry in stream {
                guard let self else { return }
                self.entries.append(entry)
                if self.entries.count > LogStore.capacity {
                    self.entries.removeFirst(self.entries.count - LogStore.capacity)
                }
            }
        }
    }

    func clear() async {
        await LogStore.shared.clear()
        entries = []
        visibleIDs = []
        isFollowingTail = true
    }

    /// The filtered tail as plain text, oldest first — the order it reads in.
    func copyText(limit: Int) -> String {
        filtered.suffix(limit).map { entry in
            let time = ISO8601DateFormatter().string(from: entry.date)
            return "\(time) [\(entry.level.label)] \(entry.category): \(entry.message)"
        }
        .joined(separator: "\n")
    }

    // MARK: Tail tracking

    func noteAppeared(_ entry: LogEntry) {
        visibleIDs.insert(entry.id)
        if entry.id == filtered.last?.id { isFollowingTail = true }
    }

    func noteDisappeared(_ entry: LogEntry) {
        visibleIDs.remove(entry.id)
        // The last row scrolling out of view is the signal that the user has
        // moved up; a new row arriving below the fold is not.
        if entry.id == filtered.last?.id, !visibleIDs.isEmpty {
            isFollowingTail = false
        }
    }
}

#Preview {
    LogsTabView()
}

#Preview("Rows") {
    List(PreviewSupport.logEntries()) { entry in
        LogRow(entry: entry)
    }
    .listStyle(.plain)
}
