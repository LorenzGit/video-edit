import Foundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Photos owns the received file. Preserve it once, then rename that owned
/// staging file into the draft instead of copying the video a second time.
enum MovieImportStorage {
    static var root: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Reel Imports", isDirectory: true)
    }

    static func stage(_ source: URL) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            do {
                let destination = folder.appendingPathComponent(source.lastPathComponent)
                try FileManager.default.copyItem(at: source, to: destination)
                return destination
            } catch {
                try? FileManager.default.removeItem(at: folder)
                throw error
            }
        }.value
    }

    static func owns(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/")
    }

    static func discard(_ url: URL) {
        guard owns(url) else { return }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}

struct PickedMovie: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            PickedMovie(url: try await MovieImportStorage.stage(received.file))
        }
    }
}

/// Retain Photos' progress object so a slow iCloud transfer is visible and
/// cancellable. A late provider callback cannot import a cancelled selection.
@MainActor
final class PhotoImportLoader: ObservableObject {
    @Published private(set) var isLoading = false
    @Published private(set) var fractionCompleted: Double = 0
    private var progress: Progress?
    private var observation: NSKeyValueObservation?
    private var continuation: CheckedContinuation<PickedMovie, Error>?
    private var requestID: UUID?

    func load(_ item: PhotosPickerItem) async throws -> PickedMovie {
        try await load { completion in item.loadTransferable(type: PickedMovie.self, completionHandler: completion) }
    }

    func load(start: (@escaping @Sendable (Result<PickedMovie?, Error>) -> Void) -> Progress) async throws -> PickedMovie {
        let id = UUID()
        requestID = id
        isLoading = true
        fractionCompleted = 0
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let progress = start { [weak self] result in
                    Task { @MainActor in
                        guard let self, self.requestID == id else {
                            if case .success(let movie) = result, let movie { MovieImportStorage.discard(movie.url) }
                            return
                        }
                        let waiting = self.continuation
                        self.reset()
                        switch result {
                        case .success(let movie):
                            if let movie { waiting?.resume(returning: movie) }
                            else { waiting?.resume(throwing: CocoaError(.fileReadUnknown)) }
                        case .failure(let error): waiting?.resume(throwing: error)
                        }
                    }
                }
                self.progress = progress
                observation = progress.observe(\.fractionCompleted, options: [.initial, .new]) { [weak self] progress, _ in
                    let fraction = progress.fractionCompleted
                    Task { @MainActor in
                        guard self?.requestID == id else { return }
                        self?.fractionCompleted = max(0, min(1, fraction))
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.requestID == id else { return }
                self?.cancel()
            }
        }
    }

    func cancel() {
        let waiting = continuation
        let transfer = progress
        reset()
        transfer?.cancel()
        waiting?.resume(throwing: CancellationError())
    }

    private func reset() {
        observation = nil
        progress = nil
        continuation = nil
        requestID = nil
        isLoading = false
        fractionCompleted = 0
    }
}
