import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Custom words (say this, write that) and snippets (say a trigger, insert a block of text).
struct DictionaryPane: View {
    enum Tab: Hashable { case dictionary, snippets }

    let stores: Stores
    let navigation: SettingsNavigation
    @State private var search = ""
    @State private var editingEntry: UUID?
    @State private var draftEntry = DictionaryEntry(spoken: "", written: "")
    @State private var editingSnippet: UUID?
    @State private var draftSnippet: Snippet?
    @State private var importNote: String?

    private var store: DictionaryStore { stores.dictionary }
    private var tab: Tab { navigation.dictionaryTab }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if tab == .dictionary { dictionaryTable } else { snippetList }
                }
                .padding(EdgeInsets(top: 4, leading: 12, bottom: 12, trailing: 6))
            }
            Text(importNote ?? (tab == .dictionary
                ? "\(store.entries.count) \(store.entries.count == 1 ? "entry" : "entries") · Entries also help the speech model recognise these words. Import accepts CSV (spoken, written) or Murmur JSON; Export writes JSON."
                : "Say a trigger on its own, or after “insert”: “insert my address”. Snippets are inserted as-is and skip AI Cleanup."))
                .font(.mmSub).lineSpacing(2).foregroundStyle(Tokens.labelTertiary)
                .padding(EdgeInsets(top: 8, leading: 18, bottom: 14, trailing: 12))
        }
        .padding(.leading, 8)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            SegmentedPicker(options: [(Tab.dictionary, "Dictionary"), (Tab.snippets, "Snippets")], selection: bind(navigation, \.dictionaryTab))
                .frame(width: 200)
            SearchField(placeholder: tab == .dictionary ? "Search dictionary" : "Search snippets", text: $search)
            Button { importFile() } label: { Label("Import", systemImage: "square.and.arrow.down") }.buttonStyle(MurmurButtonStyle(height: 28, fontSize: 12.5))
            Button { exportFile() } label: { Label("Export", systemImage: "square.and.arrow.up") }.buttonStyle(MurmurButtonStyle(height: 28, fontSize: 12.5))
            Button { add() } label: { Label("Add", systemImage: "plus") }.buttonStyle(MurmurButtonStyle(kind: .primary, height: 28, fontSize: 12.5))
        }
        .frame(height: 52)
        .padding(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 6))
    }

    // MARK: dictionary

    private var filteredEntries: [DictionaryEntry] {
        search.isEmpty ? store.entries : store.entries.filter { $0.spoken.localizedCaseInsensitiveContains(search) || $0.written.localizedCaseInsensitiveContains(search) }
    }

    private var dictionaryTable: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("When I say").frame(width: 190, alignment: .leading)
                Color.clear.frame(width: 22, height: 1)
                Text("Write").frame(maxWidth: .infinity, alignment: .leading)
                Text("Applies in").frame(width: 130, alignment: .leading)
                Color.clear.frame(width: 64, height: 1)
            }
            .font(.system(size: 11, weight: .semibold)).foregroundStyle(Tokens.labelTertiary)
            .padding(.horizontal, 16).frame(height: 30)

            if editingEntry != nil, !store.entries.contains(where: { $0.id == editingEntry }) { entryEditor }
            ForEach(filteredEntries) { entry in
                if entry.id == editingEntry {
                    entryEditor
                } else {
                    HStack(spacing: 10) {
                        Text("“\(entry.spoken)”").foregroundStyle(Tokens.labelSecondary).frame(width: 190, alignment: .leading)
                        Image(systemName: "arrow.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Tokens.labelTertiary).frame(width: 22)
                        Text(entry.written).fontWeight(.semibold).frame(maxWidth: .infinity, alignment: .leading)
                        Text(entry.scope).font(.mmCallout).foregroundStyle(Tokens.labelTertiary).frame(width: 130, alignment: .leading)
                        HStack(spacing: 2) {
                            IconButton(symbol: "pencil", label: "Edit \(entry.written)") {
                                draftEntry = entry
                                editingEntry = entry.id
                            }
                            IconButton(symbol: "trash", label: "Delete \(entry.written)") { store.entries.removeAll { $0.id == entry.id } }
                        }
                        .frame(width: 64)
                    }
                    .font(.mmBody).lineLimit(1)
                    .padding(.horizontal, 16).frame(minHeight: 44)
                    .overlay(alignment: .top) { Rectangle().fill(Tokens.separator).frame(height: 1) }
                }
            }
            if store.entries.isEmpty && editingEntry == nil {
                emptyState("No words yet", "Add names, product terms and anything the speech model keeps getting wrong.")
            } else if filteredEntries.isEmpty && editingEntry == nil {
                emptyState("No matches", "Nothing in your dictionary matches “\(search)”.")
            }
        }
        .background(Tokens.elevated, in: RoundedRectangle(cornerRadius: Tokens.Radius.group, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.group, style: .continuous).strokeBorder(Tokens.stroke, lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.group, style: .continuous))
    }

    private var entryEditor: some View {
        HStack(spacing: 10) {
            TextField("spoken phrase", text: $draftEntry.spoken).fieldChrome(emphasized: true).frame(width: 190)
                .accessibilityLabel("Spoken phrase")
            Image(systemName: "arrow.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Tokens.labelTertiary).frame(width: 22)
            TextField("written as", text: $draftEntry.written).fieldChrome().accessibilityLabel("Written as")
                .onSubmit(saveEntry)
            TextField("All apps", text: $draftEntry.scope).fieldChrome().frame(width: 130).accessibilityLabel("Applies in")
            HStack(spacing: 4) {
                Button(action: saveEntry) { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).frame(width: 12) }
                    .buttonStyle(MurmurButtonStyle(kind: .primary, height: 28)).accessibilityLabel("Save")
                    .disabled(draftEntry.spoken.trimmingCharacters(in: .whitespaces).isEmpty || draftEntry.written.trimmingCharacters(in: .whitespaces).isEmpty)
                IconButton(symbol: "xmark", label: "Cancel", tint: Tokens.label, chip: true) { editingEntry = nil }
            }
            .frame(width: 64)
        }
        .padding(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
        .background(Tokens.accentSoft)
        .overlay(alignment: .top) { Rectangle().fill(Tokens.separator).frame(height: 1) }
    }

    private func saveEntry() {
        var entry = draftEntry
        entry.spoken = entry.spoken.trimmingCharacters(in: .whitespaces)
        entry.written = entry.written.trimmingCharacters(in: .whitespaces)
        if entry.scope.trimmingCharacters(in: .whitespaces).isEmpty { entry.scope = "All apps" }
        guard !entry.spoken.isEmpty, !entry.written.isEmpty else { return }
        if let index = store.entries.firstIndex(where: { $0.id == entry.id }) { store.entries[index] = entry } else { store.entries.insert(entry, at: 0) }
        editingEntry = nil
    }

    // MARK: snippets

    private var filteredSnippets: [Snippet] {
        search.isEmpty ? store.snippets : store.snippets.filter { $0.trigger.localizedCaseInsensitiveContains(search) || $0.text.localizedCaseInsensitiveContains(search) }
    }

    @ViewBuilder private var snippetList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Trigger phrase").frame(width: 180, alignment: .leading)
                Text("Inserts").frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(width: 64, height: 1)
            }
            .font(.system(size: 11, weight: .semibold)).foregroundStyle(Tokens.labelTertiary)
            .padding(.horizontal, 16).frame(height: 30)
            ForEach(filteredSnippets) { snippet in
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("“\(snippet.trigger)”").fontWeight(.semibold)
                        if snippet.isDynamic {
                            Text("DYNAMIC").font(.system(size: 10, weight: .bold)).foregroundStyle(Tokens.accentText)
                                .padding(.horizontal, 7).padding(.vertical, 1).background(Tokens.accentSoft, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    .frame(width: 180, alignment: .leading)
                    Text(snippet.text).font(.system(size: 12.5)).lineSpacing(3).foregroundStyle(Tokens.labelSecondary).frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 2) {
                        IconButton(symbol: "pencil", label: "Edit snippet") {
                            draftSnippet = snippet
                            editingSnippet = snippet.id
                        }
                        IconButton(symbol: "trash", label: "Delete snippet") { store.snippets.removeAll { $0.id == snippet.id } }
                    }
                    .frame(width: 64)
                }
                .font(.mmBody)
                .padding(EdgeInsets(top: 11, leading: 16, bottom: 11, trailing: 16))
                .overlay(alignment: .top) { Rectangle().fill(Tokens.separator).frame(height: 1) }
            }
            if store.snippets.isEmpty {
                emptyState("No snippets yet", "Save an address, a sign-off or a template and insert it by saying its trigger.")
            } else if filteredSnippets.isEmpty {
                emptyState("No matches", "No snippet matches “\(search)”.")
            }
        }
        .background(Tokens.elevated, in: RoundedRectangle(cornerRadius: Tokens.Radius.group, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.group, style: .continuous).strokeBorder(Tokens.stroke, lineWidth: 0.5))

        if let draft = draftSnippet {
            VStack(alignment: .trailing, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Trigger phrase").font(.mmSub).foregroundStyle(Tokens.labelTertiary)
                        TextField("sign off", text: Binding(get: { draft.trigger }, set: { draftSnippet?.trigger = $0 })).fieldChrome(emphasized: true)
                    }
                    .frame(width: 180)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Inserts · tokens: {date} {time} {clipboard}").font(.mmSub).foregroundStyle(Tokens.labelTertiary)
                        TextEditor(text: Binding(get: { draft.text }, set: { draftSnippet?.text = $0 }))
                            .font(.mmBody).scrollContentBackground(.hidden)
                            .padding(EdgeInsets(top: 6, leading: 7, bottom: 6, trailing: 7))
                            .frame(height: 52)
                            .background(Tokens.elevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Tokens.stroke, lineWidth: 0.5))
                    }
                }
                HStack(spacing: 8) {
                    Button("Cancel") {
                        draftSnippet = nil
                        editingSnippet = nil
                    }
                    .buttonStyle(MurmurButtonStyle(height: 28, fontSize: 12.5))
                    Button("Save Snippet", action: saveSnippet).buttonStyle(MurmurButtonStyle(kind: .primary, height: 28, fontSize: 12.5))
                        .disabled(draft.trigger.trimmingCharacters(in: .whitespaces).isEmpty || draft.text.isEmpty)
                }
            }
            .padding(14)
            .glassSurface(cornerRadius: 18)
        }
    }

    private func saveSnippet() {
        guard var snippet = draftSnippet else { return }
        snippet.trigger = snippet.trigger.trimmingCharacters(in: .whitespaces)
        if let index = store.snippets.firstIndex(where: { $0.id == snippet.id }) { store.snippets[index] = snippet } else { store.snippets.append(snippet) }
        draftSnippet = nil
        editingSnippet = nil
    }

    // MARK: shared

    private func emptyState(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 4) {
            Text(title).font(.mmBodyEmphasis)
            Text(detail).font(.mmCallout).foregroundStyle(Tokens.labelTertiary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 28).padding(.horizontal, 40)
        .overlay(alignment: .top) { Rectangle().fill(Tokens.separator).frame(height: 1) }
    }

    private func add() {
        importNote = nil
        if tab == .dictionary {
            draftEntry = DictionaryEntry(spoken: "", written: "")
            editingEntry = draftEntry.id
        } else {
            draftSnippet = Snippet(trigger: "", text: "")
        }
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json, .commaSeparatedText, .plainText]
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        let added = store.importData(data)
        importNote = added == 0 ? "Nothing new was found in that file." : "Imported \(added) new \(added == 1 ? "item" : "items")."
    }

    private func exportFile() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Murmur dictionary.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? store.exportJSON().write(to: url)
    }
}
