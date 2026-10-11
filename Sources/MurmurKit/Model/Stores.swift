import Foundation

/// Everything the windows read, in one place, so views take a single argument.
public final class Stores {
    public let controller: DictationController
    public let settings: SettingsStore
    public let dictionary: DictionaryStore
    public let history: HistoryStore
    public let network: NetworkLog
    public let catalog: ModelCatalog
    /// True with `--demo`: simulated services and sample data.
    public let isDemo: Bool

    public init(controller: DictationController, settings: SettingsStore, dictionary: DictionaryStore, history: HistoryStore, network: NetworkLog, catalog: ModelCatalog, isDemo: Bool) {
        self.controller = controller
        self.settings = settings
        self.dictionary = dictionary
        self.history = history
        self.network = network
        self.catalog = catalog
        self.isDemo = isDemo
    }
}
