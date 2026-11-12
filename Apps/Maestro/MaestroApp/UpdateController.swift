import Combine
import Foundation

@MainActor
final class UpdateController: ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    @Published var automaticallyChecksForUpdates = false

    init() {}
    func checkForUpdates() {}
}
