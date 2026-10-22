import SwiftUI

struct PhotoAdjustmentControls: View {
    @Binding var adjustments: PhotoAdjustments

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Toggle("Apple auto-enhance", isOn: $adjustments.autoEnhance).toggleStyle(.checkbox)
                Spacer()
                Button("Reset adjustments") { adjustments = PhotoAdjustments(crop: adjustments.crop) }
            }
            adjustment("Exposure", value: $adjustments.exposure, range: -3 ... 3, suffix: "EV")
            adjustment("Highlights", value: $adjustments.highlights, range: 0 ... 1)
            adjustment("Shadows", value: $adjustments.shadows, range: 0 ... 1)
            adjustment("White balance", value: $adjustments.temperature, range: 2500 ... 10000, suffix: "K")
            adjustment("Tint", value: $adjustments.tint, range: -100 ... 100)
            HStack {
                Button("Rotate left", systemImage: "rotate.left") {
                    adjustments.quarterTurns -= 1; adjustments.crop = CGRect(x: 0, y: 0, width: 1, height: 1)
                }
                Button("Rotate right", systemImage: "rotate.right") {
                    adjustments.quarterTurns += 1; adjustments.crop = CGRect(x: 0, y: 0, width: 1, height: 1)
                }
            }
            adjustment("Straighten", value: $adjustments.straightenDegrees, range: -15 ... 15, suffix: "°")
        }
    }

    private func adjustment(
        _ title: String, value: Binding<Double>, range: ClosedRange<Double>, suffix: String = ""
    ) -> some View {
        HStack {
            Text(title).frame(width: 100, alignment: .leading)
            Slider(value: value, in: range).accessibilityLabel(title)
            Text("\(value.wrappedValue.formatted(.number.precision(.fractionLength(suffix == "K" ? 0 : 1))))\(suffix)")
                .monospacedDigit().frame(width: 75, alignment: .trailing)
        }
    }
}

struct InteractivePhotoCrop: View {
    let image: CGImage
    @Binding var rectangle: CGRect
    var masksInside = false
    var otherRectangles: [CGRect] = []
    @State private var dragStart: CGRect?

    var body: some View {
        GeometryReader { geometry in
            let layout = CropPreviewGeometry(
                imageSize: CGSize(width: image.width, height: image.height),
                availableSize: geometry.size, crop: rectangle
            )
            ZStack(alignment: .topLeading) {
                Image(decorative: image, scale: 1).resizable()
                    .frame(width: layout.imageRect.width, height: layout.imageRect.height)
                    .position(x: layout.imageRect.midX, y: layout.imageRect.midY)
                ForEach(otherRectangles.indices, id: \.self) { index in
                    let region = otherRectangles[index]
                    Rectangle().fill(.black.opacity(0.65))
                        .frame(
                            width: region.width * layout.imageRect.width,
                            height: region.height * layout.imageRect.height
                        )
                        .position(
                            x: layout.imageRect.minX + region.midX * layout.imageRect.width,
                            y: layout.imageRect.minY + region.midY * layout.imageRect.height
                        )
                        .allowsHitTesting(false)
                }
                if masksInside {
                    Rectangle().fill(.black.opacity(0.65))
                        .frame(width: layout.cropRect.width, height: layout.cropRect.height)
                        .position(x: layout.cropRect.midX, y: layout.cropRect.midY).allowsHitTesting(false)
                } else {
                    layout.excludedPixels.fill(.black.opacity(0.5), style: FillStyle(eoFill: true))
                        .allowsHitTesting(false)
                }
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .overlay { Rectangle().strokeBorder(StudioStyle.actionTint, lineWidth: 2) }
                    .frame(width: layout.cropRect.width, height: layout.cropRect.height)
                    .position(x: layout.cropRect.midX, y: layout.cropRect.midY)
                    .gesture(drag(layout: layout, corner: nil))
                    .accessibilityLabel(masksInside ? "Training loss mask; use the sliders for keyboard adjustments" :
                        "Crop selection; use the crop sliders for keyboard adjustments")
                ForEach(0 ..< 4, id: \.self) { corner in
                    RoundedRectangle(cornerRadius: 2).fill(.white)
                        .overlay { RoundedRectangle(cornerRadius: 2).strokeBorder(StudioStyle.actionTint, lineWidth: 2)
                        }
                        .frame(width: 14, height: 14)
                        .position(
                            x: corner.isMultiple(of: 2) ? layout.cropRect.minX : layout.cropRect.maxX,
                            y: corner < 2 ? layout.cropRect.minY : layout.cropRect.maxY
                        )
                        .gesture(drag(layout: layout, corner: corner))
                        .accessibilityHidden(true)
                }
            }
        }
    }

    private func drag(layout: CropPreviewGeometry, corner: Int?) -> some Gesture {
        DragGesture(minimumDistance: 0).onChanged { value in
            if dragStart == nil { dragStart = rectangle }
            guard let start = dragStart else { return }
            let dx = value.translation.width / max(1, layout.imageRect.width)
            let dy = value.translation.height / max(1, layout.imageRect.height)
            rectangle = Self.dragged(start, dx: dx, dy: dy, corner: corner)
        }.onEnded { _ in dragStart = nil }
    }

    nonisolated static let minimumFraction: CGFloat = 0.02

    nonisolated static func sizeRange(after origin: CGFloat) -> ClosedRange<CGFloat> {
        minimumFraction ... max(minimumFraction, 1 - origin)
    }

    nonisolated static func dragged(_ start: CGRect, dx: Double, dy: Double, corner: Int?) -> CGRect {
        guard let corner else {
            return CGRect(
                x: min(1 - start.width, max(0, start.minX + dx)),
                y: min(1 - start.height, max(0, start.minY + dy)), width: start.width, height: start.height
            )
        }
        let left = corner.isMultiple(of: 2) ? min(start.maxX - minimumFraction, max(0, start.minX + dx)) : start.minX
        let right = corner.isMultiple(of: 2) ? start.maxX : max(start.minX + minimumFraction, min(1, start.maxX + dx))
        let top = corner < 2 ? min(start.maxY - minimumFraction, max(0, start.minY + dy)) : start.minY
        let bottom = corner < 2 ? start.maxY : max(start.minY + minimumFraction, min(1, start.maxY + dy))
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }
}
