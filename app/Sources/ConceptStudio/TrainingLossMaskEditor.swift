import ConceptCore
import SwiftUI

struct TrainingLossMaskEditor: View {
    @Bindable var session: StudioSession
    let media: ProjectImage
    @Environment(\.dismiss) private var dismiss
    @State private var image: CGImage?
    @State private var rectangles = [CGRect(x: 0.05, y: 0.1, width: 0.25, height: 0.8)]
    @State private var selected = 0
    @State private var existingMask = false
    @State private var error = ""

    private var supported: Bool {
        session.gpu.effectiveModelRow.trainingTransforms.lossMask
    }

    private var rectangle: Binding<CGRect> {
        Binding(get: { rectangles[selected] }, set: { rectangles[selected] = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Leave other people out of training").font(.title2.bold())
            Text(media.id).lineLimit(1).foregroundStyle(StudioStyle.supportingText)
            if supported {
                Text(
                    "Cover each unwanted person, including their body, with a dark rectangle. "
                        + "The trainer ignores these pixels when calculating loss. The photo and caption stay intact."
                )
                .fixedSize(horizontal: false, vertical: true)
                if let image {
                    InteractivePhotoCrop(
                        image: image, rectangle: rectangle, masksInside: true,
                        otherRectangles: rectangles.enumerated().filter { $0.offset != selected }.map(\.element)
                    ).frame(height: 320)
                    HStack {
                        Picker("Masked region", selection: $selected) {
                            ForEach(rectangles.indices, id: \.self) { Text("Person \($0 + 1)").tag($0) }
                        }
                        Button("Add region") {
                            rectangles.append(CGRect(x: 0.5, y: 0.1, width: 0.25, height: 0.8))
                            selected = rectangles.count - 1
                        }
                        Button("Remove region") {
                            rectangles.remove(at: selected); selected = min(selected, rectangles.count - 1)
                        }.disabled(rectangles.count == 1)
                    }
                    HStack {
                        coordinate("Left", keyPath: \.origin.x, range: 0 ... (1 - InteractivePhotoCrop.minimumFraction))
                        coordinate("Top", keyPath: \.origin.y, range: 0 ... (1 - InteractivePhotoCrop.minimumFraction))
                    }
                    HStack {
                        coordinate(
                            "Width",
                            keyPath: \.size.width,
                            range: InteractivePhotoCrop.sizeRange(after: rectangles[selected].minX)
                        )
                        coordinate(
                            "Height",
                            keyPath: \.size.height,
                            range: InteractivePhotoCrop.sizeRange(after: rectangles[selected].minY)
                        )
                    }
                } else { ProgressView("Loading photo…").frame(maxWidth: .infinity, maxHeight: .infinity) }
                Text(existingMask
                    ? "This image already has a mask. Saving replaces it with the regions shown here."
                    : "Crop and colour edits change the training pixels and require a new mask.")
                    .font(.callout).foregroundStyle(StudioStyle.supportingText)
            } else {
                ContentUnavailableView(
                    "This trainer does not support loss masks", systemImage: "person.crop.rectangle.badge.xmark",
                    description: Text(session.gpu.effectiveModelRow.trainingTransforms
                        .note + " Crop out the other person, or exclude this photo.")
                ).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if !error.isEmpty { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
            Divider()
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Exclude photo") { session.includeMedia(media.id, included: false); dismiss() }
                if existingMask { Button("Remove saved mask") { removeMask() } }
                Spacer()
                if supported {
                    Button("Save loss mask") { save() }.buttonStyle(.borderedProminent).tint(StudioStyle.actionTint)
                        .disabled(image == nil || session.busy || session.editing)
                }
            }
        }.padding(24).frame(width: 720, height: 700)
            .task {
                do {
                    if let project = session.project {
                        existingMask = try TrainingLossMasks.validURL(for: media.url, in: project.directory) != nil
                    }
                    image = try await Task.detached { try MediaEditor.orientedImage(Data(contentsOf: media.url)) }.value
                } catch { self.error = error.localizedDescription }
            }
    }

    private func coordinate(
        _ title: String,
        keyPath: WritableKeyPath<CGRect, CGFloat>,
        range: ClosedRange<CGFloat>
    ) -> some View {
        HStack {
            Text(title).frame(width: 50, alignment: .leading)
            Slider(value: Binding(get: { rectangles[selected][keyPath: keyPath] }, set: {
                rectangles[selected][keyPath: keyPath] = $0
                rectangles[selected].size.width = min(rectangles[selected].width, 1 - rectangles[selected].minX)
                rectangles[selected].size.height = min(rectangles[selected].height, 1 - rectangles[selected].minY)
            }), in: range).accessibilityLabel(title + " masked fraction")
        }
    }

    private func save() {
        do {
            guard let project = session.project else { return }
            try TrainingLossMasks.save(rectangles: rectangles, imageURL: media.url, project: project)
            session.message = "Training loss mask saved for \(media.id)."
            dismiss()
        } catch { self.error = error.localizedDescription }
    }

    private func removeMask() {
        do {
            guard let project = session.project else { return }
            try FileManager.default.removeItem(at: TrainingLossMasks.url(for: media.url, in: project.directory))
            session.message = "Training loss mask removed from \(media.id)."
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
