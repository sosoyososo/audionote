import SwiftUI

struct TranscriptionDetailView: View {
    let record: TranscriptionRecord
    @ObservedObject var viewModel: TranscriptionViewModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var actionsViewModel = RecordActionsViewModel()
    @State private var isEditing = false
    @State private var editedContent: String = ""
    @State private var isProcessing = false
    @State private var localArchived: Bool = false
    @State private var relatedNotes: [RelatedNote] = []

    init(record: TranscriptionRecord, viewModel: TranscriptionViewModel) {
        self.record = record
        self.viewModel = viewModel
        self._editedContent = State(initialValue: record.content)
        self._localArchived = State(initialValue: record.archived)
    }

    /// Latest snapshot of this record from the VM. `record` is a value-type
    /// copy handed in by the sheet and never refreshes; background LLM
    /// completion updates `viewModel.historyRecords` (via `loadHistory`), so
    /// deriving from it lets the detail view reflect post-open changes
    /// without a manual sync step.
    private var currentRecord: TranscriptionRecord {
        viewModel.historyRecords.first { $0.id == record.id } ?? record
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                metadataSection

                Divider()

                contentSection

                actionsSection
                    .padding(.top, 4)

                if let audioFileName = currentRecord.audioFileName {
                    PlaybackControlBar(audioFileName: audioFileName)
                        .padding(.top, 8)
                }

                llmResultsSection

                RelatedNotesSection(
                    rows: RelatedNotesSectionBuilder.rows(
                        for: currentRecord,
                        candidates: viewModel.historyRecords,
                        related: relatedNotes
                    ),
                    viewModel: viewModel
                )
            }
            .padding()
        }
        .navigationTitle(isEditing ? "Detail.Edit.Title".localized : "Detail.Title".localized)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                if isEditing {
                    Button("Action.Cancel".localized) {
                        cancelEditing()
                    }
                } else {
                    Button("Action.Close".localized) {
                        dismiss()
                    }
                }
            }

            ToolbarItem(placement: .primaryAction) {
                if isEditing {
                    Button("Action.Save".localized) {
                        saveEditing()
                    }
                } else {
                    HStack {
                        Button {
                            actionsViewModel.showShareSheet = true
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }

                        Button {
                            enterEditingMode()
                        } label: {
                            Image(systemName: "pencil")
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $actionsViewModel.showShareSheet) {
            ShareSheet(items: [currentRecord.content])
        }
        .overlay(alignment: .bottom) {
            ToastView(message: actionsViewModel.toastMessage, isShowing: $actionsViewModel.showCopiedToast)
                .padding(.bottom, 40)
        }
        .task(id: currentRecord.id) {
            // `relatedNotes.json` is the source of truth and the store has no
            // cache (spec §5.2), so this re-reads on every appear — the task
            // is cancelled and restarted when the view leaves. Loading once
            // would leave the section permanently empty for a note opened while
            // its own relation call was still in flight (1–3s window), since
            // nothing would re-read the file afterward.
            relatedNotes = await RelatedNotesStorage.shared.related(to: currentRecord.id)
        }
        .onChange(of: currentRecord.content) { newContent in
            // `editedContent` is seeded from `record.content` in `init` and
            // `record` is a stale value-type copy, so without this a pending
            // record that recovers while its sheet is open would flip the
            // badge to "已在线升级" and then render `Text("")` — the same
            // blank body the pending placeholder exists to prevent.
            //
            // Skipped while editing: that buffer is the user's, and
            // `enterEditingMode` / `cancelEditing` own resyncing it.
            if !isEditing {
                editedContent = newContent
            }
        }
    }

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "calendar")
                    .foregroundColor(.secondary)
                Text(currentRecord.createdAt, style: .date)
                    .foregroundColor(.secondary)
            }

            HStack {
                Image(systemName: "clock")
                    .foregroundColor(.secondary)
                Text(currentRecord.createdAt, style: .time)
                    .foregroundColor(.secondary)
            }

            if let duration = currentRecord.duration, duration > 0 {
                HStack {
                    Image(systemName: "timer")
                        .foregroundColor(.secondary)
                    Text(currentRecord.formattedDuration)
                        .foregroundColor(.secondary)
                }
            }

            if let mode = currentRecord.recognitionMode {
                let style = RecognitionModeStyle(mode: mode)
                HStack(spacing: 6) {
                    Image(systemName: style.icon)
                    Text(style.label)
                }
                .foregroundColor(style.color)
            }
        }
        .font(.subheadline)
    }

    private var contentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Always present, so the copy button below has a stable home: a
            // row that appeared only with the seal would make the affordance
            // jump in and out as LLM status changed. The seal is a prefix
            // inside this row, not the row itself.
            HStack {
                // Gated on `llmProcessingStatus`, not on `optimizedContent != nil`.
                // The marker field is overloaded: it holds the pre-LLM original
                // *and* the pre-edit text, and a record the user typed into
                // carries one of those too. Gating on the marker's presence would
                // announce LLM-optimized text the user wrote character by
                // character. `isHandEdited` is no better — it is true for every
                // LLM-processed record, since `processWithLLM` has always set
                // `optimizedContent = originalText`, so it would hide the badge
                // from exactly the records it exists for. LLM status is the one
                // signal here that is genuinely about the model.
                //
                // Accepted residual: a record that was LLM-processed and *then*
                // hand-edited still shows the badge. Defensible — the text was
                // optimized before the user took it over — and it is the best
                // available answer without adding a field to `TranscriptionRecord`.
                if currentRecord.llmProcessingStatus == .completed {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundColor(.green)
                    Text("优化后")
                        .font(.caption)
                        .foregroundColor(.green)
                }

                Text("Detail.Content.Label".localized)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer(minLength: 8)

                // Exact complement of the pending placeholder's *text* test
                // below — no `recognitionMode` term. Adding one would split
                // the pair again, the regression the placeholder's comment
                // records. `isEditing` because the text on screen is
                // `editedContent`, which has not been written back yet: a copy
                // button here would silently hand over the pre-edit value.
                if !isEditing && PendingRecognitionPolicy.isLLMEligible(text: currentRecord.content) {
                    CopyIconButton {
                        actionsViewModel.copyText(currentRecord.content)
                    }
                }
            }

            Group {
                if isEditing {
                    TextEditor(text: $editedContent)
                        .font(.body)
                        .frame(minHeight: 200)
                        .padding(8)
                        .background(Color(.systemGray6))
                        .cornerRadius(8)
                } else if !PendingRecognitionPolicy.isLLMEligible(text: currentRecord.content)
                            && currentRecord.recognitionMode == .pending {
                    // No transcript yet — the recovery sweep fills this in
                    // later. Rendering `Text("")` here would leave a blank
                    // body with no explanation of why (spec §4.7). The
                    // playback bar below already covers the "listen to the
                    // audio" affordance, so this stays a status block.
                    //
                    // Gated on *emptiness*, not mode alone. `saveEditing`
                    // preserves `recognitionMode`, so a pending record the
                    // user typed into keeps `.pending` while carrying real
                    // text — testing the mode alone hid the text they had
                    // just saved, which the pre-placeholder `else` branch
                    // (`Text(editedContent)`) had always shown. Shares
                    // `isLLMEligible` with the LLM block below, and feeds
                    // it the same value: this branch reads
                    // `currentRecord.content` and the button reads
                    // `llmCandidateText`, which is `llmInputText` and
                    // returns `content` for every record (see its doc). So
                    // the two gates are exact complements on the text test,
                    // not merely in agreement for today's records — an
                    // earlier version of this comment called that a
                    // coincidence of no route filling `optimizedContent`
                    // first, which stopped being true the moment
                    // `llmInputText` existed.
                    //
                    // The one asymmetry that remains is this branch's extra
                    // `&& recognitionMode == .pending`: a non-pending record
                    // with empty text shows neither the placeholder nor a
                    // button. Adding a mode condition to the button, or
                    // dropping this one, would reintroduce the split.
                    VStack(spacing: 12) {
                        let style = RecognitionModeStyle(mode: .pending)
                        Image(systemName: style.icon)
                            .font(.largeTitle)
                            .foregroundColor(style.color)
                        Text("Detail.Pending.Hint".localized)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                } else {
                    Text(editedContent)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var llmResultsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()

            // Show results if available
            if currentRecord.title != nil || currentRecord.summary != nil || currentRecord.tags != nil {
                if let title = currentRecord.title, !title.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Detail.LLM.Title".localized)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer(minLength: 8)
                            CopyIconButton {
                                actionsViewModel.copyText(title)
                            }
                        }
                        Text(title)
                            .font(.headline)
                    }
                }

                if let summary = currentRecord.summary, !summary.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Detail.LLM.Summary".localized)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer(minLength: 8)
                            CopyIconButton {
                                actionsViewModel.copyText(summary)
                            }
                        }
                        Text(summary)
                            .font(.body)
                    }
                }

                if let tags = currentRecord.tags, !tags.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Detail.LLM.Tags".localized)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TagFlowView(tags: tags, highlighted: viewModel.selectedTags)
                    }
                }
            }

            // Status indicator and action button
            llmStatusView
                .padding(.top, 8)
        }
    }

    @ViewBuilder
    private var llmStatusView: some View {
        if isProcessing || viewModel.isAwaitingUserLLMResult {
            // Currently processing - show disabled button with spinner
            HStack {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle())
                    .scaleEffect(0.8)
                Text("Detail.LLM.Processing".localized)
            }
            .disabled(true)
        } else if PendingRecognitionPolicy.isLLMEligible(text: llmCandidateText) {
            // Show action button based on status
            Button {
                reprocessRecord()
            } label: {
                HStack {
                    Image(systemName: buttonIcon)
                    Text(buttonTitle)
                }
            }
            .disabled(viewModel.isLLMProcessing)
        }
        // else: no text to send, so no button. A pending record with empty
        // `content` and `llmProcessingStatus == nil` is exactly the state
        // that used to render an enabled button here, and the tap landed on
        // the `isLLMEligible` guard in `reprocessRecord` — a log line and
        // no visible change. The guard stays (it is the only thing between a
        // race in the record snapshot and an invented title/summary/tags);
        // this just stops offering a control that cannot do anything.
    }

    /// The text `reprocessRecord` would send. Same `llmInputText` resolution
    /// the function uses, and read off the record rather than the
    /// `editedContent` buffer, so it does not flicker while the user types.
    ///
    /// Same source, but not the same instant: the button is built from this
    /// render-time value while `reprocessRecord`'s guard re-reads the record
    /// when the tap lands. The two therefore agree only until the record
    /// changes in between — which is the case the guard exists for.
    private var llmCandidateText: String {
        PendingRecognitionPolicy.llmInputText(for: currentRecord)
    }

    private var buttonIcon: String {
        switch currentRecord.llmProcessingStatus {
        case .completed: return "arrow.clockwise"
        case .failed: return "exclamationmark.triangle"
        default: return "sparkles"
        }
    }

    private var buttonTitle: String {
        switch currentRecord.llmProcessingStatus {
        case .completed: return "Detail.LLM.Reprocess".localized
        case .failed: return "Detail.LLM.Failed".localized
        default: return "Detail.LLM.Start".localized
        }
    }

    // MARK: - Recognition Mode Helpers
//
// `RecognitionModeStyle` lives in `SharedComponents.swift` and is the
// single source of truth for mode → {icon, color, label}. This view
// consumes it via the `if let mode = currentRecord.recognitionMode`
// binding above — no per-view helper duplication.

    @ViewBuilder
    private var actionsSection: some View {
        HStack(spacing: 8) {
            if let mode = currentRecord.recognitionMode,
               (mode == .onDevice || mode == .failed || mode == .pending),
               currentRecord.audioFileName != nil {
                Button {
                    upgradeRecognition()
                } label: {
                    HStack {
                        if viewModel.isEnhancing {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle())
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: "arrow.up.doc")
                        }
                        Text("在线升级识别")
                    }
                    .frame(maxWidth: .infinity)
                }
                .disabled(viewModel.isEnhancing)
                .padding(.vertical, 10)
                .padding(.horizontal, 16)
                .background(Color.blue.opacity(0.1))
                .foregroundColor(.blue)
                .cornerRadius(10)
            } else {
                Spacer()
            }

            archiveButton
        }
    }

    private var archiveButton: some View {
        Button {
            archiveToggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: localArchived ? "archivebox.fill" : "archivebox")
                Text(localArchived
                     ? "Detail.Action.Archived".localized
                     : "Detail.Action.Archive".localized)
                    .lineLimit(1)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 16)
            .background(localArchived ? Color.orange.opacity(0.25) : Color.gray.opacity(0.1))
            .foregroundColor(localArchived ? .orange : .primary)
            .cornerRadius(10)
        }
        .buttonStyle(.plain)
    }

    private func archiveToggle() {
        let nextState = !localArchived
        localArchived = nextState
        Task {
            if nextState {
                await viewModel.archiveRecord(id: record.id)
            } else {
                await viewModel.unarchiveRecord(id: record.id)
            }
        }
    }

    private func upgradeRecognition() {
        Task {
            await viewModel.reRecognizeOnline(recordId: record.id)
            // VM.reRecognizeOnline ends with loadHistory(); currentRecord
            // will pick up the refreshed recognitionMode + content on the
            // next render — no manual sync needed here.
        }
    }

    private func reprocessRecord() {
        isProcessing = true
        Task {
            let baseRecord = currentRecord
            let originalText = PendingRecognitionPolicy.llmInputText(for: baseRecord)

            // This view is NOT a route through `processWithLLM` — it calls
            // `optimizeAndProcess` itself, so it carries its own copy of the
            // empty-text guard. A `.pending` record reaches this screen
            // (`displayedRecords` filters on archived / search / tags only)
            // with `content == ""` and `llmProcessingStatus == nil`. Without
            // this guard the model would answer `""` with an invented title,
            // summary and tags, and those would be written over the record
            // and stamped `.completed`, while the later recognition retry
            // would fix only `content`.
            //
            // Why the guard is load-bearing even though the UI already
            // prevents the obvious bad input: `LLMService.optimizeAndProcess`
            // has no empty-text check of its own, so every route into it has
            // to vet its own input. This function is a network call, and it
            // is the one place between `originalText` and the model. Relying
            // on the button's own gate to keep the value non-empty would
            // make that guarantee a property of the *current* call graph
            // rather than of this function — and the gate is a render-time
            // decision, not an invariant. (`llmStatusView` hides the button
            // for a textless record today and this is its only caller, so no
            // tap currently reaches the guard; a recovery sweep writing
            // content between render and tap only moves the two in the safe
            // direction, since the added text satisfies the predicate.)
            //
            // Deliberately before the profile lookup: a record with no text
            // does not need a provider configured in order to be rejected.
            // Resets `isProcessing` the same way the missing-profile path
            // below does, because it is set at the top of this function.
            guard PendingRecognitionPolicy.isLLMEligible(text: originalText) else {
                Logger.warning("LLM reprocess skipped: empty text for record \(baseRecord.id)")
                await MainActor.run {
                    isProcessing = false
                }
                return
            }

            // Pull the active profile + key from the store. The profiles
            // live in the data folder now, so the read is asynchronous.
            await ProviderProfileStore.shared.ensureLoaded()
            // If no profile is configured, surface that as a status
            // without throwing.
            guard let profile = ProviderProfileStore.shared.active else {
                Logger.warning("LLM reprocess skipped: no active profile")
                await MainActor.run {
                    isProcessing = false
                }
                return
            }
            let apiKey = ProviderProfileStore.shared.apiKey(for: profile.id)
            let llmService = LLMService()

            do {
                let result = try await llmService.optimizeAndProcess(
                    originalText,
                    profile: profile,
                    apiKey: apiKey,
                    existingTags: await MainActor.run { viewModel.existingTagVocabulary }
                )
                let updatedRecord = TranscriptionRecord(
                    id: baseRecord.id,
                    content: result.optimizedText,
                    createdAt: baseRecord.createdAt,
                    duration: baseRecord.duration,
                    language: baseRecord.language,
                    audioFileName: baseRecord.audioFileName,
                    title: result.title,
                    summary: result.summary,
                    tags: result.tags,
                    llmProcessingStatus: .completed,
                    // Was `originalText != baseRecord.content ? originalText : baseRecord.optimizedContent`
                    // — "if I sent something other than what is stored, that
                    // is the pre-LLM original". Collapsed because it became a
                    // constant-false test: `llmInputText` returns `content`
                    // for every record (see its doc), so `originalText`
                    // always equals `baseRecord.content` and the true arm
                    // became unreachable when this function started calling
                    // `llmInputText`. Nothing is lost by dropping it — the
                    // marker that was carried is still the right one, and
                    // `handEditMarker` term 1 believes whatever is passed
                    // here, so a hand-edited record keeps its pre-edit marker
                    // and stays hand-edited.
                    optimizedContent: baseRecord.optimizedContent,
                    recognitionMode: baseRecord.recognitionMode
                )
                try await viewModel.updateRecord(updatedRecord)
                await MainActor.run {
                    isProcessing = false
                    editedContent = result.optimizedText
                }
            } catch {
                Logger.error("LLM reprocess failed: \(error.localizedDescription)")
                await MainActor.run {
                    isProcessing = false
                }
            }
        }
    }

    private func saveEditing() {
        let baseRecord = currentRecord
        let updatedRecord = TranscriptionRecord(
            id: baseRecord.id,
            content: editedContent.trimmingCharacters(in: .whitespacesAndNewlines),
            createdAt: baseRecord.createdAt,
            duration: baseRecord.duration,
            language: baseRecord.language,
            audioFileName: baseRecord.audioFileName,
            title: baseRecord.title,
            summary: baseRecord.summary,
            tags: baseRecord.tags,
            llmProcessingStatus: baseRecord.llmProcessingStatus,
            recognitionMode: baseRecord.recognitionMode
        )

        Task {
            do {
                try await viewModel.updateRecord(updatedRecord)
                await MainActor.run {
                    isEditing = false
                    actionsViewModel.showSaveConfirmation()
                }
            } catch {
                Logger.error("Failed to save edited content: \(error.localizedDescription)")
            }
        }
    }

    private func cancelEditing() {
        editedContent = currentRecord.content
        isEditing = false
    }

    private func enterEditingMode() {
        editedContent = currentRecord.content
        isEditing = true
    }
}

struct RelatedNotesRow: Identifiable, Equatable {
    let id: UUID
    let title: String
    let createdAt: Date
    let preview: String
    let sharedTags: [String]
    /// The record a `NavigationLink` pushes. Carried here so the row stays a
    /// plain value the builder can construct without a view model.
    let record: TranscriptionRecord
}

/// Pure mapping from stored edges to renderable rows, so the skip rules are
/// unit-testable without instantiating a SwiftUI view.
enum RelatedNotesSectionBuilder {

    static func rows(
        for record: TranscriptionRecord,
        candidates: [TranscriptionRecord],
        related: [RelatedNote]
    ) -> [RelatedNotesRow] {
        let byID = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let currentTagKeys = TagIdentity.matchingKeys(Set(record.tagNames))

        // `related(to:)` already hands back score-descending edges, so this
        // sort is a no-op in production. It is kept, with the *same*
        // `uuidString` tie-break as the storage, so the rendered order cannot
        // drift from the stored one — and so the builder is well-defined for
        // any `related` input rather than trusting its caller's ordering.
        let ordered = related.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.id.uuidString < rhs.id.uuidString
        }

        return ordered.compactMap { link -> RelatedNotesRow? in
            guard let other = byID[link.id], other.archived != true else { return nil }
            // Matched through `TagIdentity` — deliberately the same match
            // `RelatedNotesService.prescreen` uses. A chip the prescreen never
            // matched would read as a contradiction; normalize both or neither.
            // The shared tags keep the *other* record's spelling, since they
            // are rendered as that record's tags.
            let shared = TagIdentity.matching(other.tagNames, in: currentTagKeys)
            return RelatedNotesRow(
                id: other.id,
                title: other.title?.isEmpty == false ? other.title! : other.preview,
                createdAt: other.createdAt,
                preview: other.preview,
                sharedTags: shared,
                record: other
            )
        }
    }
}

/// Rendered at the bottom of the detail page. Hides itself entirely when
/// there is nothing to show — no empty state, no spinner. Takes the view model
/// separately so `RelatedNotesRow` stays a plain value.
struct RelatedNotesSection: View {
    let rows: [RelatedNotesRow]
    @ObservedObject var viewModel: TranscriptionViewModel

    var body: some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Related.Section.Title".localized)
                    .font(.headline)

                ForEach(rows) { row in
                    NavigationLink {
                        TranscriptionDetailView(record: row.record, viewModel: viewModel)
                    } label: {
                        RelatedNotesRowView(row: row)
                    }
                }
            }
            .padding(.vertical, 8)
        }
    }
}

struct RelatedNotesRowView: View {
    let row: RelatedNotesRow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(row.title)
                .font(.subheadline.weight(.medium))
                .foregroundColor(.primary)

            HStack(spacing: 6) {
                Text(row.createdAt, style: .date)
                Text(row.createdAt, style: .time)
            }
            .font(.caption)
            .foregroundColor(.secondary)

            Text(row.preview)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(2)

            if !row.sharedTags.isEmpty {
                HStack(spacing: 6) {
                    ForEach(row.sharedTags, id: \.self) { tag in
                        Text(tag)
                            .font(.caption2)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.accentColor.opacity(0.1))
                            .cornerRadius(8)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }
}

struct TagFlowView: View {
    let tags: [TaggedItem]

    /// Tag names the surrounding context has selected — in practice the
    /// library's `selectedTags`. Chips in this set render at full strength and
    /// the rest recede, so a record opened from a filtered list says which of
    /// its tags brought it there. The filter is OR (`displayedRecords`), so
    /// this is often a strict subset of the chips on screen.
    ///
    /// **Empty means "no context", not "nothing matches"** — every chip then
    /// renders identically, which is why there is no separate
    /// `isFilterActive` flag: the rule lives here, so a call site cannot
    /// forget to apply it.
    ///
    /// Matched through `TagIdentity`, the same comparison the library's own
    /// filter (`TranscriptionViewModel.displayedRecords`) uses. Sharing the
    /// definition is what keeps this honest: a chip lights up exactly when it
    /// actually filtered the record in. A case-sensitive `contains` here would
    /// light nothing at all whenever the record spells the tag differently
    /// from the chip — reintroducing on this screen the very ambiguity the
    /// highlight exists to remove.
    let highlighted: Set<String>

    /// Tags sorted by relevance score descending. The LLM is *instructed* to
    /// return them sorted, but doesn't reliably honor that — sorting here
    /// guarantees the most relevant tag renders first regardless of what the
    /// model returns.
    private var sortedTags: [TaggedItem] {
        tags.sorted { $0.score > $1.score }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(sortedTags, id: \.name) { tag in
                    // Two variables, not one: "matched" decides the tint,
                    // "demphasised" decides the fade, and they do NOT
                    // partition the same way. With no filter the chips must
                    // stay exactly as they were — base tint, full opacity —
                    // so `isMatched` alone would wrongly tint them all 0.18,
                    // while `isDemphasised` alone would wrongly fade them all.
                    let isMatched = TagIdentity.matches(tag.name, anyOf: highlighted)
                    let isDemphasised = !highlighted.isEmpty && !isMatched
                    HStack(spacing: 4) {
                        Text(tag.name)
                            .font(.caption)
                        Text(String(format: "%.2f", tag.score))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(isMatched ? 0.18 : 0.1))
                    .cornerRadius(8)
                    .opacity(isDemphasised ? 0.4 : 1)
                }
            }
        }
    }
}

#Preview {
    NavigationView {
        let record = TranscriptionRecord(
            content: "这是一段测试文本，用于预览转写详情页面的显示效果。",
            createdAt: Date()
        )
        TranscriptionDetailView(record: record, viewModel: TranscriptionViewModel())
    }
}
