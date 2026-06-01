import Foundation
import SproutEngine

/// A bounded, observable log buffer for one workspace's server/setup output.
/// `@MainActor` so it is safe to mutate from UI and is implicitly Sendable
/// (capture in `@Sendable` onLog closures is allowed; hop back via Task).
@MainActor
final class LogBuffer: ObservableObject, Identifiable {
    struct Entry: Identifiable, Equatable {
        let id = UUID()
        let source: LogLine.Source
        let text: String
    }

    nonisolated let id: String          // workspace branch (stable per project)
    @Published private(set) var entries: [Entry] = []
    @Published var paused = false       // affects autoscroll only, never drops lines

    private let maxLines = 5000

    init(id: String) { self.id = id }

    func append(_ line: LogLine) {
        entries.append(Entry(source: line.source, text: line.text))
        if entries.count > maxLines {
            entries.removeFirst(entries.count - maxLines)
        }
    }

    func clear() { entries.removeAll() }
}
