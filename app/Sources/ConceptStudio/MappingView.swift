import AppKit
import ConceptCore
import SwiftUI

struct MappingView: View {
    @Bindable var session: StudioSession
    @State private var locators: [String: String] = [:]
    @State private var enabled: Set<String> = []
    @State private var filter = "all"
    @State private var selection: Set<String> = []
    @State private var selectionAnchor: String?
    @State private var batchTrigger = ""
    @State private var batchLocation = ""
    private var onlyUnmapped: Bool {
        filter == "unconfirmed"
    }

    /// The person changed the editor since it was filled; a late suggestion must not overwrite that.
    @State private var edited = false
    /// Height of the photo detail's scroll area; below `shortDetail` the photo moves beside the subjects.
    @State private var detailHeight: CGFloat = 600
    private let shortDetail: CGFloat = 440

    private var images: [ProjectImage] {
        (session.project?.allMedia ?? []).filter { image in
            let excluded = session.project?.excludedImages.contains { $0.id == image.id } == true
            switch filter {
            case "notSure": return !excluded && session.projectState.notSure[image.id] != nil
            case "excluded": return excluded
            case "unconfirmed": return !excluded && session.project?.job.mapping(for: image.id) == nil
            default: return !excluded
            }
        }
    }

    private var confirmedCount: Int {
        (session.project?.images.count ?? 0) - session.unmappedCount
    }

    private var selectedImage: ProjectImage? {
        images.first { $0.id == session.selectedImageID }
    }

    /// The open sample, while it holds edits that are not confirmed yet; bulk actions leave it alone.
    private var heldDraftIDs: Set<String> {
        guard edited, let id = session.selectedImageID else { return [] }
        return [id]
    }

    private var acceptableSuggestionIDs: [String] {
        session.validMappingSuggestionIDs.filter { !heldDraftIDs.contains($0) }
    }

    private var locatorConcepts: [Concept] {
        (session.project?.job.concepts ?? []).filter(\.targetConcept.requiresLocator)
    }

    var body: some View {
        mappingEditor
    }

    private var mappingEditor: some View {
        VStack(alignment: .leading, spacing: 18) {
            StudioSection(
                title: "Locate the concept in each image or clip",
                subtitle: "Identify who or what is present. "
                    + "A suggestion becomes part of your project only when you confirm it.",
                paper: false
            ) {
                HStack(spacing: 20) {
                    Text("\(confirmedCount) / \(session.project?.images.count ?? 0) confirmed")
                        .fontWeight(.medium)
                    ProgressView(
                        value: Double(confirmedCount),
                        total: Double(max(session.project?.images.count ?? 0, 1))
                    )
                    .frame(maxWidth: 180).accessibilityLabel("Samples confirmed")
                    Spacer()
                    Picker("Show", selection: $filter) {
                        Text("Included").tag("all")
                        Text("Unconfirmed").tag("unconfirmed")
                        Text("Not sure (\(session.projectState.notSure.count))").tag("notSure")
                        Text("Excluded (\(session.project?.excludedImages.count ?? 0))").tag("excluded")
                    }.frame(maxWidth: 240)
                }.font(.callout)
                HStack(spacing: 10) {
                    Button("Request assignments from model", systemImage: "sparkles") {
                        session.proposeMappings(useModel: true)
                    }
                    Picker("Photos per request", selection: $session.mappingBatchSize) {
                        Text("Single image").tag(1)
                        Text("2 × 2 sheet").tag(4)
                        Text("3 × 3 sheet").tag(9)
                    }.frame(maxWidth: 260)
                    if !session.mappingProposals.isEmpty {
                        Button("Clear suggestions") {
                            session.mappingProposals = [:]
                            session.mappingDescriptions = [:]
                            if !edited { load() }
                        }
                    }
                }.disabled(session.busy)
                HStack {
                    if let concept = session.project?.job.concepts.first,
                       session.project?.job.concepts.count == 1, concept.targetConcept.isPersonIdentity {
                        Button("Confirm all remaining as \(concept.trigger)") {
                            session.confirmRemainingSinglePerson()
                            if !edited { load() }
                        }.disabled(session.analyzing)
                            .help(
                                "Confirm samples with exactly one detected face. "
                                    + "Skip Not sure; list the rest for review."
                            )
                    }
                }.disabled(session.busy)
                if !session.mappingReviewExceptions.isEmpty {
                    DisclosureGroup("\(session.mappingReviewExceptions.count) samples need face review") {
                        ScrollView {
                            ForEach(session.mappingReviewExceptions, id: \.self) { id in
                                Button(id) { filter = "all"; selection = [id]; session.selectedImageID = id }
                                    .buttonStyle(.link)
                            }
                        }.frame(maxHeight: 100)
                    }
                }
                if selection.count > 1 { batchControls }
                if !acceptableSuggestionIDs.isEmpty || session.canUndoMappingChange {
                    HStack(spacing: 10) {
                        if !acceptableSuggestionIDs.isEmpty {
                            Button("Accept all \(acceptableSuggestionIDs.count) suggestions") {
                                session.acceptMappingSuggestions(except: heldDraftIDs)
                                if !edited { load() }
                            }
                            .help(
                                "Accept valid suggestions for unconfirmed samples. The open sample's unconfirmed "
                                    + "edits are kept for you to confirm. Review suggestions individually if needed."
                            )
                        }
                        if session.canUndoMappingChange {
                            Button("Undo last mapping change", systemImage: "arrow.uturn.backward") {
                                session.undoMappingChange()
                                if !edited { load() }
                            }
                        }
                    }.disabled(session.busy || session.editing)
                }
                Text(session.demoMode ? "The demo model uses prepared assignments." :
                    "Select several photos with ⇧-click or ⌘-click. Model suggestions use your selected provider.")
                    .font(.callout).foregroundStyle(StudioStyle.supportingText)
            }
            HStack(alignment: .top, spacing: 18) {
                printStrip
                ScrollView {
                    if let image = selectedImage {
                        VStack(alignment: .leading, spacing: 16) {
                            suggestionResult(for: image)
                            // The open print sits beside the assignment, so what a suggestion filled in stays in
                            // view above the pinned Confirm bar next to the photo it describes.
                            HStack(alignment: .top, spacing: 18) {
                                openPrint(
                                    image,
                                    photoSide: detailHeight < shortDetail ? 170 : min(360, detailHeight * 0.62)
                                )
                                presentSubjects
                            }
                        }.padding(.horizontal, 4).padding(.top, 2).padding(.bottom, 12)
                    } else {
                        ContentUnavailableView(
                            onlyUnmapped && images.isEmpty ? "Every sample is confirmed" : "Select an image or clip",
                            systemImage: onlyUnmapped && images.isEmpty ? "checkmark.circle" : "person.crop.rectangle",
                            description: Text(onlyUnmapped && images
                                .isEmpty ? "Turn off the filter to review your confirmed mappings." :
                                "Choose an image or clip from the list to identify the concept.")
                        )
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if let image = selectedImage { confirmBar(for: image) }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { detailHeight = $0 }
            }
        }
        .onAppear { selectVisiblePhoto(); load() }
        .onChange(of: filter) { _, _ in selectVisiblePhoto() }
        .onChange(of: images.map(\.id)) { _, ids in selection.formIntersection(ids) }
        .onChange(of: session.selectedImageID) { _, _ in load() }
        .onChange(of: session.selectedImageID.flatMap { session.mappingProposals[$0] }) { _, _ in
            // A suggestion that arrives while this photo is open fills it, unless the person already edited it.
            if !edited { load() }
        }
        .onChange(of: session.selectedImageID.flatMap { session.analyses[$0]?.faces.count }) { _, _ in
            if !edited { load() }
        }
    }

    private func rowStatus(_ image: ProjectImage) -> Label<Text, Image> {
        if session.project?.excludedImages.contains(where: { $0.id == image.id }) == true {
            return Label("Excluded", systemImage: "minus.circle")
        }
        if session.projectState
            .notSure[image.id] != nil { return Label("Not sure", systemImage: "questionmark.circle") }
        if let result = suggestionConclusion(for: image.id) {
            return Label(result.rowTitle, systemImage: result.symbol)
        }
        if session.project?.job.mapping(for: image.id) != nil {
            return Label("Confirmed", systemImage: "checkmark.circle.fill")
        }
        return Label("Unconfirmed", systemImage: "circle")
    }

    private func suggestionConclusion(for id: String) -> MappingSuggestionConclusion? {
        MappingSuggestionConclusion.compare(
            proposal: session.mappingProposals[id], confirmed: session.project?.job.mapping(for: id),
            locatorTriggers: Set(locatorConcepts.map(\.trigger))
        )
    }

    @ViewBuilder
    private func suggestionResult(for image: ProjectImage) -> some View {
        if let result = suggestionConclusion(for: image.id), let proposal = session.mappingProposals[image.id] {
            VStack(alignment: .leading, spacing: 8) {
                StudioNotice(result.message, symbol: result.symbol)
                if let description = session.mappingDescriptions[image.id], !description.isEmpty {
                    Text("Model saw: " + description).font(.callout).textSelection(.enabled)
                }
                ForEach(locatorConcepts.filter { proposal[$0.trigger] != nil }, id: \.trigger) { concept in
                    Text("Suggested location for \(concept.trigger): \(proposal[concept.trigger] ?? "")")
                        .font(.callout).foregroundStyle(StudioStyle.supportingText).textSelection(.enabled)
                }
            }
        }
    }

    private func photo(_ image: ProjectImage) -> some View {
        TrainingTargetPreview(
            url: image.url,
            faces: session.project?.job.concepts.contains { $0.targetConcept.isPersonIdentity } == true
                ? session.analyses[image.id]?.faces ?? [] : []
        )
    }

    /// The open sample as a print at twice contact-sheet size, its name and state in the margin.
    private func openPrint(_ image: ProjectImage, photoSide: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            photo(image).frame(width: photoSide, height: photoSide)
                .background(InstantPrint.filterTrack)
            VStack(alignment: .leading, spacing: 6) {
                Text(image.id).font(.system(size: 14, weight: .semibold)).foregroundStyle(InstantPrint.ink)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                PrintStateChip(state: .other(statusTitle(image)))
            }
            .padding(.horizontal, 4).padding(.top, 10).padding(.bottom, 12)
        }
        .padding([.horizontal, .top], 8)
        .frame(width: photoSide + 16, alignment: .leading)
        .background(InstantPrint.paper, in: RoundedRectangle(cornerRadius: 4))
        .shadow(color: .black.opacity(0.10), radius: 3, x: 0, y: 1.5)
        .environment(\.colorScheme, .light)
    }

    private func statusTitle(_ image: ProjectImage) -> String {
        if session.project?.excludedImages.contains(where: { $0.id == image.id }) == true { return "Excluded" }
        if session.projectState.notSure[image.id] != nil { return "Not sure" }
        if let result = suggestionConclusion(for: image.id) { return result.rowTitle }
        return session.project?.job.mapping(for: image.id) != nil ? "Confirmed" : "Unconfirmed"
    }
}

private extension MappingView {
    /// The samples as a slim strip of small prints; the open one is ringed. Arrow keys move through it.
    private var printStrip: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(images) { image in
                        let selected = selection.contains(image.id)
                        Button { choose(image.id) } label: {
                            HStack(spacing: 10) {
                                TrainingTargetPreview(url: image.url, fill: true)
                                    .frame(width: 46, height: 46).clipped()
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(image.id).font(.system(size: 12.5, weight: .semibold))
                                        .foregroundStyle(InstantPrint.ink).lineLimit(1).truncationMode(.middle)
                                    rowStatus(image).font(.system(size: 11.5))
                                        .foregroundStyle(InstantPrint.inkSecondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(5)
                            .background(InstantPrint.paper, in: RoundedRectangle(cornerRadius: 4))
                            .shadow(color: .black.opacity(0.08), radius: 2, x: 0, y: 1)
                            .overlay {
                                if selected {
                                    RoundedRectangle(cornerRadius: 5).strokeBorder(InstantPrint.developer, lineWidth: 2)
                                        .padding(-3)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .environment(\.colorScheme, .light)
                        .id(image.id)
                        .contextMenu {
                            if !Sources.isVideo(Sources.suffix(of: image.id)) {
                                ForEach(locatorConcepts, id: \.trigger) { concept in
                                    Button("Use as reference photo for \(concept.trigger)") {
                                        session.useAsReference(image: image, trigger: concept.trigger)
                                    }.disabled(session.busy || session.editing)
                                }
                            }
                            Button("Not sure") { session.markNotSure(id: image.id, note: "") }
                            Button("Exclude") { session.includeMedia(image.id, included: false) }
                        }
                        .help(image.id)
                        .accessibilityLabel("\(image.id), \(statusTitle(image))")
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
                .padding(4)
            }
            .scrollIndicators(.automatic)
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                moveSelection(by: press.key == .upArrow ? -1 : 1)
                if let id = session.selectedImageID { proxy.scrollTo(id) }
                return .handled
            }
            .onAppear { if let id = session.selectedImageID { proxy.scrollTo(id, anchor: .center) } }
        }
        .frame(width: 230)
    }

    private func moveSelection(by offset: Int) {
        let order = images.map(\.id)
        guard !order.isEmpty else { return }
        let current = session.selectedImageID.flatMap { order.firstIndex(of: $0) } ?? -offset
        choose(order[min(max(current + offset, 0), order.count - 1)], modifiers: [])
    }

    private var presentSubjects: some View {
        StudioSection(title: "Concept assignment") {
            ForEach(locatorConcepts, id: \.trigger) { concept in
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(
                        "\(concept.trigger) · \(concept.classNoun)",
                        isOn: Binding(get: { enabled.contains(concept.trigger) }, set: { value in
                            edited = true
                            if value {
                                enabled.insert(concept.trigger)
                            } else {
                                enabled.remove(concept.trigger)
                            }
                        })
                    ).toggleStyle(.checkbox).fontWeight(.medium)
                    if enabled.contains(concept.trigger) {
                        TextField(
                            concept.targetConcept.locatorHint,
                            text: Binding(
                                get: { locators[concept.trigger] ?? "" },
                                set: { edited = true; locators[concept.trigger] = $0 }
                            ),
                            axis: .vertical
                        ).lineLimit(1 ... 3)
                            .accessibilityLabel("\(concept.trigger) location in this sample")
                    }
                }.padding(.vertical, 4)
            }
            if let job = session.project?.job, !job.wholeTargetMapping.isEmpty {
                ForEach(job.concepts.filter { !$0.targetConcept.requiresLocator }, id: \.trigger) { concept in
                    Label("\(concept.trigger) · assigned to the whole target", systemImage: "checkmark.circle")
                        .font(.callout)
                }
                Text("Style and motion are assigned automatically. Select only the locator concepts present "
                    + "in this sample, then confirm the combined assignment.")
                    .font(.callout).foregroundStyle(StudioStyle.supportingText)
            } else {
                Text("Select only concepts visible in this sample. If none appears, exclude the sample on Images; "
                    + "it cannot be captioned for this LoRA.")
                    .font(.callout).foregroundStyle(StudioStyle.supportingText)
            }
            Text("Check each selected concept against this exact training target.")
                .font(.callout).foregroundStyle(StudioStyle.supportingText)
        }
    }

    /// Pinned below the photo so Confirm stays visible at the minimum window size.
    private func confirmBar(for image: ProjectImage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            if session.projectState.notSure[image.id] != nil {
                TextField("Not sure — optional note", text: Binding(
                    get: { session.projectState.notSure[image.id] ?? "" },
                    set: { session.markNotSure(id: image.id, note: $0) }
                ))
            }
            HStack(spacing: 12) {
                Button(confirmTitle(for: image), systemImage: "checkmark") { confirm(image) }
                    .buttonStyle(.borderedProminent).tint(StudioStyle.actionTint)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Save this sample's mapping and open the next unconfirmed one (⌘↩)")
                    .disabled((enabled.isEmpty && session.project?.job.wholeTargetMapping.isEmpty != false)
                        || enabled.contains { (locators[$0] ?? "").isBlank } || session.busy
                        || session.projectState.notSure[image.id] != nil || filter == "excluded")
                Spacer(minLength: 8)
                if session.project?.job.mapping(for: image.id) != nil {
                    Button("Mark as unconfirmed") { unconfirm(image) }.disabled(session.busy)
                }
            }
            HStack(spacing: 12) {
                Button(
                    session.projectState.notSure[image.id] == nil ? "Not sure" : "Clear Not sure",
                    systemImage: "questionmark.circle"
                ) {
                    session.markNotSure(id: image.id, note: session.projectState.notSure[image.id] == nil ? "" : nil)
                }.keyboardShortcut("?", modifiers: []).disabled(session.busy)
                Button(filter == "excluded" ? "Include" : "Exclude") {
                    session.includeMedia(image.id, included: filter == "excluded")
                }.disabled(session.busy)
            }
            .padding(.leading, 4).padding(.vertical, 10)
        }
        .background(InstantPrint.ground)
    }

    private func confirm(_ image: ProjectImage) {
        // Snapshot before confirmation removes this sample from a filtered list.
        let order = images.map(\.id)
        session.confirmMapping(
            id: image.id,
            mapping: Job.Mapping(enabled.sorted().map { ($0, locators[$0] ?? "") })
        )
        guard session.project?.job.mapping(for: image.id) != nil else { return }
        let confirmed = Set(session.project?.images.filter { session.project?.job.mapping(for: $0.id) != nil }
            .map(\.id) ?? [])
        if let next = StudioSession.nextUnconfirmed(
            after: image.id,
            order: order,
            confirmed: confirmed,
            notSure: Set(session.projectState.notSure.keys)
        ) {
            choose(next, modifiers: [])
        } else { load() }
    }

    private func confirmTitle(for image: ProjectImage) -> String {
        session.project?.job.mapping(for: image.id) == nil
            && session.validMappingSuggestionIDs.contains(image.id)
            ? "Accept suggestion and next" : "Confirm and next"
    }

    private func unconfirm(_ image: ProjectImage) {
        session.unconfirmMapping(id: image.id)
        load()
    }

    private func selectVisiblePhoto() {
        if !images.contains(where: { $0.id == session.selectedImageID }) {
            session.selectedImageID = images.first?.id
        }
        selection.formIntersection(images.map(\.id))
        if selection.isEmpty, let id = session.selectedImageID { selection = [id] }
    }

    private func choose(_ id: String, modifiers: NSEvent.ModifierFlags = NSEvent.modifierFlags) {
        let order = images.map(\.id)
        if modifiers.contains(.shift), let anchor = selectionAnchor,
           let start = order.firstIndex(of: anchor), let end = order.firstIndex(of: id) {
            selection = Set(order[min(start, end) ... max(start, end)])
        } else if modifiers.contains(.command) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            selectionAnchor = id
        } else {
            selection = [id]
            selectionAnchor = id
        }
        session.selectedImageID = id
    }

    private var batchControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(selection.count) selected")
                Picker("Confirm selected as", selection: $batchTrigger) {
                    Text("Choose concept").tag("")
                    ForEach(locatorConcepts, id: \.trigger) { Text($0.trigger).tag($0.trigger) }
                }.frame(maxWidth: 240)
                TextField("Location", text: $batchLocation).frame(maxWidth: 180)
            }
            HStack {
                Button("Confirm selected") {
                    session.confirmMappings(ids: selection, mapping: [batchTrigger: batchLocation])
                    load()
                }.disabled(batchTrigger.isEmpty || batchLocation.isBlank || session.busy)
                Button("Clear selected") { session.confirmMappings(ids: selection, mapping: nil); load() }
                    .disabled(session.busy)
            }
        }
    }

    /// Fills the editor with the confirmed mapping, or else the suggestion for this photo.
    private func load() {
        guard let id = session.selectedImageID else { return }
        let confirmed = session.project?.job.mapping(for: id)
        let suggestion = confirmed == nil ? session.mappingProposals[id] : nil
        let selected = confirmed ?? suggestion ?? [:]
        let faceCount = session.analyses[id]?.faces.count
        locators = Dictionary(uniqueKeysWithValues: locatorConcepts.compactMap { concept in
            MappingLocatorDefaults.singleFaceClassNoun(for: concept, faceCount: faceCount)
                .map { (concept.trigger, $0) }
        })
        for (trigger, locator) in selected {
            locators[trigger] = locator
        }
        enabled = Set(selected.keys).intersection(locatorConcepts.map(\.trigger))
        edited = false
    }
}

enum MappingLocatorDefaults {
    static func singleFaceClassNoun(for concept: Concept, faceCount: Int?) -> String? {
        guard concept.targetConcept.isPersonIdentity, faceCount == 1 else { return nil }
        let noun = concept.classNoun.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return noun.hasPrefix("the ") ? noun : "the \(noun)"
    }
}

/// Compares concept presence, not arbitrary locator prose or a calibrated identity score.
enum MappingSuggestionConclusion: Equatable {
    case agrees, differs, confirmedNoMatch, suggested, noMatch

    static func compare(
        proposal: Job.Mapping?, confirmed: Job.Mapping?, locatorTriggers: Set<String>
    ) -> Self? {
        guard let proposal else { return nil }
        let proposed = Set(proposal.keys).intersection(locatorTriggers)
        if proposed.isEmpty { return confirmed == nil ? .noMatch : .confirmedNoMatch }
        guard let confirmed else { return .suggested }
        return proposed == Set(confirmed.keys).intersection(locatorTriggers) ? .agrees : .differs
    }

    var rowTitle: String {
        switch self {
        case .agrees: "Confirmed · suggestion agrees"
        case .differs: "Confirmed · suggestion differs"
        case .confirmedNoMatch: "Confirmed · no confident suggestion"
        case .suggested: "Suggested · check it"
        case .noMatch: "No confident suggestion"
        }
    }

    var symbol: String {
        switch self {
        case .agrees: "checkmark.circle"
        case .differs: "arrow.triangle.branch"
        case .confirmedNoMatch, .noMatch: "person.crop.rectangle"
        case .suggested: "sparkles"
        }
    }

    var message: String {
        switch self {
        case .agrees:
            "The suggestion agrees with your confirmation about which concepts are present. "
                + "Check the suggested locations below; your confirmed locations are unchanged."
        case .differs:
            "The suggestion differs from your confirmed concepts. Your confirmed locations are kept. "
                + "Review this sample before changing them."
        case .confirmedNoMatch:
            "No confident assignment was suggested. Your confirmed locations are kept."
        case .suggested:
            "Review the suggested locations against this sample, then confirm the assignments you choose."
        case .noMatch:
            "No confident assignment was suggested. Enter the visible concepts and their locations, then confirm."
        }
    }
}
