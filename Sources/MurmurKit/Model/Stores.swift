import Foundation
import Observation

/// Everything the windows read, in one place, so views take a single argument.
public final class Stores {
    public let controller: DictationController
    public let settings: SettingsStore
    public let dictionary: DictionaryStore
    public let history: HistoryStore
    public let stats: StatsStore
    public let network: NetworkLog
    public let catalog: ModelCatalog
    /// True with `--demo`: simulated services and sample data.
    public let isDemo: Bool
    let overlay = OverlayPanelState()

    public init(controller: DictationController, settings: SettingsStore, dictionary: DictionaryStore, history: HistoryStore, stats: StatsStore, network: NetworkLog, catalog: ModelCatalog, isDemo: Bool) {
        self.controller = controller
        self.settings = settings
        self.dictionary = dictionary
        self.history = history
        self.stats = stats
        self.network = network
        self.catalog = catalog
        self.isDemo = isDemo
    }
}

/// Which panel the overlay card shows in place of its body. Only one at a time, and only during a take.
@Observable
final class OverlayPanelState {
    enum Panel { case mode, actions }
    var open: Panel?
    /// Where the card is inside its window, for the smoke tour to check which way it grows.
    @ObservationIgnored var cardFrame = CGRect.zero

    /// After a choice: leave the highlight up for a moment, then collapse.
    func collapseSoon() {
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            open = nil
        }
    }
}
