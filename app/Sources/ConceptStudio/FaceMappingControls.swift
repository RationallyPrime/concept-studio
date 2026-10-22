import SwiftUI

struct FaceMappingControls: View {
    @Bindable var session: StudioSession
    var heldDraftIDs: Set<String>
    var didConfirm: () -> Void
    var selectSample: (String) -> Void
    @State private var detailsExpanded = true

    private var peopleCount: Int {
        session.project?.job.concepts.count(where: \.targetConcept.isPersonIdentity) ?? 0
    }

    var body: some View {
        if peopleCount > 0 {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Button("Match faces on this Mac", systemImage: "faceid") { session.matchFacesOnMac() }
                        .disabled(session.busy || session.editing || session.faceMappingPending.isEmpty)
                    if let concept = session.project?.job.concepts.first,
                       session.project?.job.concepts.count == 1, concept.targetConcept.isPersonIdentity {
                        let matches = session.faceMappingPending.filter {
                            !heldDraftIDs.contains($0.id)
                                && session.faceRecognitionResults[$0.id]?.singleMatch(for: concept.trigger) == true
                        }.count
                        Button("Confirm \(matches) matches as \(concept.trigger)") {
                            session.confirmRemainingSinglePerson(except: heldDraftIDs)
                            didConfirm()
                        }
                        .disabled(matches == 0 || session.busy || session.editing)
                        .help("Confirm only single-face samples in the match band. All other samples stay for review.")
                    }
                }
                if session.personReferences.count < peopleCount {
                    Button("Choose reference photos in Concepts") { session.step = .concepts }
                        .buttonStyle(.link)
                }
                ForEach(session.faceReferenceWarnings.keys.sorted(), id: \.self) { trigger in
                    if let warnings = session.faceReferenceWarnings[trigger], !warnings.isEmpty {
                        StudioNotice(
                            "\(trigger): " + warnings.joined(separator: " "),
                            symbol: "exclamationmark.triangle"
                        )
                    }
                }
                DisclosureGroup(detailsTitle, isExpanded: $detailsExpanded) {
                    Text("Photos stay on this Mac. First use downloads the 39 MB SFace 2021dec model from OpenCV.")
                        .font(.callout).foregroundStyle(StudioStyle.supportingText)
                    HStack {
                        Link("SFace by OpenCV Zoo", destination: SFaceRecognizer.modelPage)
                        Link("Apache 2.0 license", destination: SFaceRecognizer.licenseURL)
                    }.font(.caption)
                    if !session.faceReviewIDs.isEmpty {
                        Text("\(session.faceReviewIDs.count) samples need face review").font(.callout)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(session.faceReviewIDs, id: \.self) { id in
                                    Button {
                                        selectSample(id)
                                    } label: {
                                        Text(id + " · " + (session.faceRecognitionResults[id]?.mappingBand.title
                                                ?? "Not checked"))
                                    }.buttonStyle(.link)
                                }
                            }
                        }.frame(maxHeight: 100)
                    }
                }
            }
            .onAppear { detailsExpanded = session.faceRecognitionResults.isEmpty }
            .onChange(of: session.faceRecognitionResults.isEmpty) { _, empty in
                if !empty { detailsExpanded = false }
            }
        }
    }

    private var detailsTitle: String {
        session.faceReviewIDs.isEmpty ? "Face matching details" :
            "Face matching details · \(session.faceReviewIDs.count) to review"
    }
}

struct FaceMatchResultView: View {
    let result: FaceRecognitionResult

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("On this Mac · \(result.mappingBand.title)", systemImage: "faceid").fontWeight(.medium)
            if let reason = result.reviewReason { Text(reason).font(.callout) }
            ForEach(Array(result.faces.enumerated()), id: \.offset) { index, face in
                VStack(alignment: .leading, spacing: 3) {
                    if let reason = face.reviewReason { Text("Face \(index + 1): \(reason)") }
                    ForEach(face.scores, id: \.trigger) { score in
                        Text("Face \(index + 1) · \(score.trigger): \(score.band.title) "
                            + String(format: "(%.3f)", score.similarity))
                            .monospacedDigit().textSelection(.enabled)
                    }
                }.font(.callout)
            }
            Text("Similarity scores guide review. Confirmed assignments are saved only when you approve them.")
                .font(.caption).foregroundStyle(StudioStyle.supportingText)
        }
    }
}
