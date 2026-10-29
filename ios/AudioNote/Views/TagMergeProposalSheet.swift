import SwiftUI

/// The model's merge suggestions, as a list the user can prune before
/// anything changes.
///
/// **The model proposes; the user disposes.** Nothing here merges on its
/// own: every proposal can be excluded or deleted, or have its target name
/// changed, and the merge happens only when the user presses the button at
/// the bottom (ADR-0010).
///
/// The counts are on every row on purpose. A tag on one note and a tag on
/// forty are very different things to merge, and the user cannot judge a
/// proposal without knowing which one they are looking at.
struct TagMergeProposalSheet: View {
    @ObservedObject var viewModel: TranscriptionViewModel
    @Environment(\.dismiss) private var dismiss

    /// The proposals as they stand. Deleting removes one; excluding keeps
    /// it visible but out of the merge.
    @State private var proposals: [TagMergeProposal] = []
    @State private var excluded = Set<UUID>()
    @State private var isApplying = false

    /// The proposals that will actually be merged.
    private var accepted: [TagMergeProposal] {
        proposals.filter { !$0.sources.isEmpty && !excluded.contains($0.id) }
    }

    /// Pull the view model's answer into the local list — once, when it
    /// arrives. The run itself belongs to the view model: closing this
    /// sheet does not stop it.
    private func adoptProposalsIfNeeded() {
        guard proposals.isEmpty, !viewModel.mergeProposals.isEmpty else { return }
        proposals = viewModel.mergeProposals
    }

    /// How many notes the merge would rewrite in total. A note carrying two
    /// of the tags is one note to rewrite, so this is not the sum of the
    /// counts.
    private var affectedNotes: Int {
        let keys = Set(accepted.flatMap { $0.sources }.map(TagIdentity.key))
        guard !keys.isEmpty else { return 0 }
        return viewModel.historyRecords.filter { record in
            record.tagNames.contains { keys.contains(TagIdentity.key($0)) }
        }.count
    }

    var body: some View {
        NavigationStack {
            List {
                if viewModel.mergeProposalState == .running {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("Library.Tags.Merge.Working".localized)
                                .font(.subheadline)
                            Spacer()
                            Button {
                                viewModel.cancelTagMergeProposal()
                            } label: {
                                Text("Library.Tags.Merge.Cancel".localized)
                                    .font(.caption)
                            }
                        }
                    } footer: {
                        Text("Library.Tags.Merge.CanClose".localized)
                    }
                } else if viewModel.mergeProposalState == .failed {
                    Section {
                        Text("Library.Tags.Merge.Failed".localized)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Button {
                            viewModel.startTagMergeProposal()
                        } label: {
                            Text("Library.Tags.Merge.Retry".localized)
                        }
                    }
                } else if viewModel.mergeProposalState == .cancelled {
                    Section {
                        Text("Library.Tags.Merge.Cancelled".localized)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Button {
                            viewModel.startTagMergeProposal()
                        } label: {
                            Text("Library.Tags.Merge.Retry".localized)
                        }
                    }
                }

                if !proposals.isEmpty {
                    Section {
                        ForEach($proposals) { $proposal in
                            row(for: $proposal)
                        }
                        .onDelete { offsets in
                            proposals.remove(atOffsets: offsets)
                        }
                    } footer: {
                        Text("Library.Tags.Merge.Footer".localized)
                    }
                } else if viewModel.mergeProposalState == .done {
                    Section {
                        Text("Library.Tags.Merge.Empty".localized)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .onAppear { adoptProposalsIfNeeded() }
            .onChange(of: viewModel.mergeProposalState) { _ in
                adoptProposalsIfNeeded()
            }
            .navigationTitle("Library.Tags.Merge.Title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Text("Action.Cancel".localized)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        // Every proposal is agreed to by default; this undoes
                        // the individual exclusions.
                        excluded.removeAll()
                    } label: {
                        Text("Library.Tags.Merge.AcceptAll".localized)
                    }
                    .disabled(excluded.isEmpty)
                }
            }
            .safeAreaInset(edge: .bottom) {
                applyBar
            }
        }
    }

    // MARK: - Rows

    private func row(for proposal: Binding<TagMergeProposal>) -> some View {
        let value = proposal.wrappedValue
        let isExcluded = excluded.contains(value.id)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    if isExcluded {
                        excluded.remove(value.id)
                    } else {
                        excluded.insert(value.id)
                    }
                } label: {
                    Image(systemName: isExcluded ? "circle" : "checkmark.circle.fill")
                        .foregroundColor(isExcluded ? Color.secondary : Color.accentColor)
                }
                .buttonStyle(.plain)

                TextField(
                    "Library.Tags.Merge.Target".localized,
                    text: proposal.target
                )
                .textFieldStyle(.roundedBorder)
                .font(.body)
            }

            ForEach(value.sources, id: \.self) { source in
                HStack(spacing: 6) {
                    Text(source)
                        .font(.subheadline)
                    Text(String(format: "Library.Tags.Merge.Notes".localized,
                               value.counts[source] ?? 0))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                    Spacer()
                }
            }

            Text(String(format: "Library.Tags.Merge.Affects".localized,
                       value.affectedNoteCount(in: viewModel.historyRecords)))
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Apply

    @ViewBuilder
    private var applyBar: some View {
        if proposals.isEmpty {
            EmptyView()
        } else {
            applyButton
        }
    }

    private var applyButton: some View {
        VStack(spacing: 6) {
            Button {
                apply()
            } label: {
                HStack {
                    if isApplying {
                        ProgressView().controlSize(.small)
                    }
                    Text(String(format: "Library.Tags.Merge.Apply".localized, accepted.count))
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(accepted.isEmpty || isApplying)
            .padding(.horizontal, 16)

            Text(String(format: "Library.Tags.Merge.WillAffect".localized, affectedNotes))
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 10)
        .background(.regularMaterial)
    }

    private func apply() {
        isApplying = true
        let toApply = accepted
        Task {
            do {
                let outcome = try await viewModel.applyTagMerges(toApply)
                Logger.info("tag merge: applied \(outcome.applied.count), skipped \(outcome.skipped)")
                dismiss()
            } catch {
                Logger.error("tag merge failed: \(error)")
                isApplying = false
            }
        }
    }
}
