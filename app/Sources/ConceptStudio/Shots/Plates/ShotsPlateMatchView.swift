import PrevisCore
import ShotsMedia
import SwiftUI

/// The camera-match screen: the plate with lines to drag along its edges, and over it the floor grid and a
/// person-sized figure that show at a glance whether the camera is right. Every handle is also a number field,
/// and the camera itself can be typed, so nothing here needs a pointer.
struct ShotsPlateMatchView: View {
    let plate: LocationPlate
    let image: CGImage?
    let onSave: (LocationPlate) -> Void
    let onCancel: () -> Void

    @State private var model: PlateMatchModel
    @State private var showsGrid = true
    @FocusState private var focused: PlateMatchModel.Handle?

    init(
        plate: LocationPlate, image: CGImage?, onSave: @escaping (LocationPlate) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.plate = plate
        self.image = image
        self.onSave = onSave
        self.onCancel = onCancel
        _model = State(initialValue: PlateMatchModel(plate: plate))
    }

    static let colorA = Color(red: 1.0, green: 0.78, blue: 0.2)
    static let colorB = Color(red: 0.35, green: 0.85, blue: 1.0)
    static let colorHeight = Color(red: 1.0, green: 0.45, blue: 0.75)
    static let colorFigure = Color(red: 0.45, green: 1.0, blue: 0.55)

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                plateArea.frame(minWidth: 380, minHeight: 560).padding(12)
                Divider()
                ScrollView { controls.padding(14) }.frame(width: 320)
            }
            Divider()
            HStack {
                Text(model.problem ?? model.summary)
                    .font(.callout).foregroundStyle(model.problem == nil ? .secondary : InstantPrint.attentionText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(model.problem.map { "Problem: \($0)" } ?? model.summary)
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save camera match") { onSave(model.result(for: plate)) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.problem != nil)
                    .help("Keep this camera for the plate. Every shot blocked over the plate starts from it.")
            }
            .padding(12)
        }
        .frame(minWidth: 820, idealWidth: 900, minHeight: 680, idealHeight: 760)
    }

    // MARK: The plate

    private var plateArea: some View {
        GeometryReader { geometry in
            let rect = ShotCameraView.letterboxRect(
                in: geometry.size, canvas: ShotCanvas(width: plate.size.width, height: plate.size.height)
            )
            ZStack(alignment: .topLeading) {
                Group {
                    if let image {
                        Image(decorative: image, scale: 1).resizable().interpolation(.high)
                    } else {
                        Rectangle().fill(Color.primary.opacity(0.08))
                            .overlay { Text("The plate's image is missing.").foregroundStyle(.secondary) }
                    }
                }
                .frame(width: rect.width, height: rect.height)
                Canvas { context, size in draw(in: &context, size: size) }
                    .frame(width: rect.width, height: rect.height)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                ForEach(visibleHandles, id: \.self) { handle in
                    if let point = model.position(of: handle) {
                        handleView(handle, size: rect.size)
                            .position(x: point.x * rect.width, y: point.y * rect.height)
                    }
                }
            }
            .frame(width: rect.width, height: rect.height)
            .coordinateSpace(name: "plate")
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .offset(x: rect.minX, y: rect.minY)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Plate \(plate.name) with match handles")
    }

    private var visibleHandles: [PlateMatchModel.Handle] {
        var handles: [PlateMatchModel.Handle] = []
        if model.usesLinesA { handles += [.lineA(0, end: 0), .lineA(0, end: 1), .lineA(1, end: 0), .lineA(1, end: 1)] }
        if model.usesLinesB { handles += [.lineB(0, end: 0), .lineB(0, end: 1), .lineB(1, end: 0), .lineB(1, end: 1)] }
        if model.heightFromReference { handles += [.foot, .top] }
        handles.append(.figure)
        return handles
    }

    private func handleView(_ handle: PlateMatchModel.Handle, size: CGSize) -> some View {
        let color = Self.color(of: handle)
        return Circle()
            .fill(color.opacity(focused == handle ? 0.9 : 0.35))
            .overlay { Circle().strokeBorder(color, lineWidth: 2) }
            .overlay { Circle().strokeBorder(Color.black.opacity(0.55), lineWidth: 1).padding(-1) }
            .frame(width: 16, height: 16)
            .contentShape(Circle().inset(by: -8))
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("plate")).onChanged { drag in
                guard size.width > 0, size.height > 0 else { return }
                focused = handle
                model.move(handle, to: Point2(x: drag.location.x / size.width, y: drag.location.y / size.height))
            })
            .focusable()
            .focused($focused, equals: handle)
            .onMoveCommand { direction in nudge(handle, direction) }
            .help(Self.help(for: handle))
            .accessibilityElement()
            .accessibilityLabel(Self.name(of: handle))
            .accessibilityValue(accessibilityValue(of: handle))
            .accessibilityAdjustableAction { direction in
                nudge(handle, direction == .increment ? .right : .left)
            }
    }

    /// Arrow keys move the focused handle by a five-hundredth of the plate.
    private func nudge(_ handle: PlateMatchModel.Handle, _ direction: MoveCommandDirection) {
        guard let point = model.position(of: handle) else { return }
        let step = 0.002
        let moved = switch direction {
        case .left: Point2(x: point.x - step, y: point.y)
        case .right: Point2(x: point.x + step, y: point.y)
        case .up: Point2(x: point.x, y: point.y - step)
        case .down: Point2(x: point.x, y: point.y + step)
        @unknown default: point
        }
        model.move(handle, to: moved)
    }

    private func accessibilityValue(of handle: PlateMatchModel.Handle) -> String {
        guard let point = model.position(of: handle) else { return "Out of view" }
        return "\(Int((point.x * 100).rounded())) percent across, \(Int((point.y * 100).rounded())) percent down"
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        func point(_ p: Point2) -> CGPoint {
            CGPoint(x: p.x * size.width, y: p.y * size.height)
        }
        func stroke(_ a: Point2, _ b: Point2, _ color: Color, width: CGFloat = 2) {
            var path = Path()
            path.move(to: point(a))
            path.addLine(to: point(b))
            context.stroke(path, with: .color(.black.opacity(0.5)), lineWidth: width + 2)
            context.stroke(path, with: .color(color), lineWidth: width)
        }
        if showsGrid, model.problem == nil {
            var grid = Path()
            for run in model.floorGrid() {
                grid.addLines(run.map(point))
            }
            context.stroke(grid, with: .color(.black.opacity(0.35)), lineWidth: 2)
            context.stroke(grid, with: .color(.white.opacity(0.75)), lineWidth: 0.8)
            if let horizon = model.horizon {
                var path = Path()
                path.move(to: point(horizon.left))
                path.addLine(to: point(horizon.right))
                context.stroke(path, with: .color(.white.opacity(0.9)), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
                context.draw(
                    Text("Horizon").font(.caption2).foregroundStyle(.white),
                    at: CGPoint(x: 30, y: point(horizon.left).y - 8)
                )
            }
        }
        if model.usesLinesA { for line in model.linesA {
            stroke(line.a, line.b, Self.colorA)
        } }
        if model.usesLinesB { for line in model.linesB {
            stroke(line.a, line.b, Self.colorB)
        } }
        if model.heightFromReference {
            stroke(model.reference.foot, model.reference.top, Self.colorHeight, width: 3)
        }
        if model.problem == nil, let span = model.figureSpan {
            let foot = point(span.foot), head = point(span.head)
            let tall = hypot(head.x - foot.x, head.y - foot.y)
            let wide = tall * 0.26
            // A person-sized slab standing on the floor: a body and a head.
            var body = Path()
            body.addRoundedRect(
                in: CGRect(x: foot.x - wide / 2, y: head.y + tall * 0.14, width: wide, height: tall * 0.86),
                cornerSize: CGSize(width: wide * 0.3, height: wide * 0.3)
            )
            body.addEllipse(in: CGRect(x: foot.x - tall * 0.065, y: head.y, width: tall * 0.13, height: tall * 0.14))
            context.fill(body, with: .color(Self.colorFigure.opacity(0.2)))
            context.stroke(body, with: .color(.black.opacity(0.6)), lineWidth: 3)
            context.stroke(body, with: .color(Self.colorFigure), lineWidth: 1.5)
            context.draw(
                Text(String(format: "%.2f m", model.figureHeight)).font(.caption2.bold()).foregroundStyle(.white),
                at: CGPoint(x: foot.x, y: head.y - 9)
            )
        }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Match the camera").font(.title3).accessibilityAddTraits(.isHeader)
            Text(
                "Drag each pair of lines onto edges of the set that are parallel in real life and level with the "
                    + "floor: a table's long edges, a row of flagstones. The white grid is the floor as this camera "
                    + "sees it, in one-metre squares. The match is right when the grid lies flat on the plate's floor "
                    + "and the green figure looks like a person standing there."
            )
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            Divider()
            Toggle(isOn: $model.usesLinesA) { swatchLabel("Two lines along the set", Self.colorA) }
                .help("Use the yellow pair: two edges that run the same way in the set, such as a table's long edges.")
            Toggle(isOn: $model.usesLinesB) { swatchLabel("Two lines across it", Self.colorB) }
                .disabled(!model.usesLinesA)
                .help("Use the blue pair: two edges square to the yellow ones on the floor, such as the table's ends.")
            Toggle("Find the lens from the lines", isOn: $model.lensFromLines)
                .disabled(!(model.usesLinesA && model.usesLinesB))
                .help("With both pairs the lens follows from them. Turn this off to type a lens you know.")

            Divider()
            number(
                "Lens (mm)",
                \.lens,
                6 ... 400,
                enabled: !model.lensIsSolved,
                "The focal length the plate was made with. A smaller number sees wider."
            )
            if let note = model.lensNote {
                Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Picker("Film format", selection: $model.sensor) {
                ForEach(Sensor.allCases, id: \.self) { Text($0.formatName).tag($0) }
            }
            .help("The camera's film format. Shots on this plate use it too. Leave it if you don't know.")

            Divider()
            Toggle(isOn: $model.heightFromReference) { swatchLabel(
                "Find the height from a known height",
                Self.colorHeight
            ) }
            .help("Mark something whose height you know: drag the pink line's foot to where it meets the floor "
                + "and its top to its top.")
            if model.heightFromReference {
                ShotsNumberField(title: "Known height (m)", value: Binding(
                    get: { model.reference.height },
                    set: { model.reference.height = $0; model.solve() }
                ), range: 0.05 ... 50, explanation: "How tall the marked thing is in metres. A table is about 0.76.")
            }
            number(
                "Camera height (m)",
                \.height,
                0.05 ... 200,
                enabled: !model.heightFromReference,
                "How high the camera is above the plate's floor, in metres. Eye height is about 1.6."
            )

            Divider()
            number(
                "Tilt (°)",
                \.tiltDegrees,
                -89 ... 89,
                enabled: !model.anglesAreSolved,
                "How far the camera looks down (negative) or up. The lines set it when they are on."
            )
            number(
                "Roll (°)",
                \.rollDegrees,
                -45 ... 45,
                enabled: !(model.usesLinesA),
                "How far the horizon leans. Two pairs of lines set it; one pair assumes a level horizon."
            )
            number(
                "Turn (°)",
                \.panDegrees,
                -180 ... 180,
                enabled: !model.anglesAreSolved,
                "Which way the camera faces across the set. The lines turn the grid to run along the set."
            )
            DisclosureGroup("Camera position in the set") {
                number(
                    "X (m)",
                    \.cameraX,
                    -10000 ... 10000,
                    enabled: true,
                    "Where this plate's camera stands, left and right. Leave 0 for a set with one plate."
                )
                number(
                    "Z (m)",
                    \.cameraZ,
                    -10000 ... 10000,
                    enabled: true,
                    "Where this plate's camera stands, front to back. Leave 0 for a set with one plate."
                )
                Text("A second plate of the same set gets its own position, so one blocking serves both.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            swatchLabel("Reference figure", Self.colorFigure).font(.headline)
            Text("Drag the green dot at its feet across the floor to check sizes near and far.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ShotsNumberField(
                title: "Height (m)", value: $model.figureHeight, range: 0.2 ... 30,
                explanation: "How tall the green figure is, in metres."
            )
            number(
                "Along X (m)",
                \.figureX,
                -10000 ... 10000,
                enabled: true,
                "Where the figure stands on the floor, left and right, in metres."
            )
            number(
                "Along Z (m)",
                \.figureZ,
                -10000 ... 10000,
                enabled: true,
                "Where the figure stands on the floor, front to back, in metres."
            )
            Button("Bring the figure back in front") { model.recallFigure() }
                .help("Stand the figure six metres in front of the camera.")
            Toggle("Show the floor grid", isOn: $showsGrid)

            if visibleHandles.count > 1 {
                DisclosureGroup("Line ends as numbers") {
                    ForEach(visibleHandles.filter { $0 != .figure }, id: \.self) { handle in
                        handleFields(handle)
                    }
                }
                .help("Each end of each line, as a percentage across and down the plate, for typing them.")
            }
        }
    }

    private func swatchLabel(_ title: String, _ color: Color) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10).accessibilityHidden(true)
            Text(title)
        }
    }

    /// A number that solves again when typed. Disabled fields report what the lines found.
    private func number(
        _ title: String, _ key: WritableKeyPath<PlateMatchModel, Double>, _ range: ClosedRange<Double>,
        enabled: Bool, _ explanation: String
    ) -> some View {
        ShotsNumberField(title: title, value: Binding(
            get: { model[keyPath: key] },
            set: { model[keyPath: key] = $0; model.solve() }
        ), range: range, explanation: explanation)
            .disabled(!enabled)
    }

    private func handleFields(_ handle: PlateMatchModel.Handle) -> some View {
        let point = model.position(of: handle) ?? Point2(x: 0.5, y: 0.5)
        return VStack(alignment: .leading, spacing: 2) {
            Text(Self.name(of: handle)).font(.caption)
            HStack {
                ShotsNumberField(title: "Across (%)", value: Binding(
                    get: { point.x * 100 }, set: { model.move(handle, to: Point2(x: $0 / 100, y: point.y)) }
                ), range: 0 ... 100)
                ShotsNumberField(title: "Down (%)", value: Binding(
                    get: { point.y * 100 }, set: { model.move(handle, to: Point2(x: point.x, y: $0 / 100)) }
                ), range: 0 ... 100)
            }
        }
    }

    // MARK: Words

    static func color(of handle: PlateMatchModel.Handle) -> Color {
        switch handle {
        case .lineA: colorA
        case .lineB: colorB
        case .foot, .top: colorHeight
        case .figure: colorFigure
        }
    }

    static func name(of handle: PlateMatchModel.Handle) -> String {
        func end(_ index: Int) -> String {
            index == 0 ? "start" : "end"
        }
        switch handle {
        case let .lineA(line, index): return "Along the set, line \(line + 1), \(end(index))"
        case let .lineB(line, index): return "Across the set, line \(line + 1), \(end(index))"
        case .foot: return "Known height, foot"
        case .top: return "Known height, top"
        case .figure: return "Reference figure's feet"
        }
    }

    static func help(for handle: PlateMatchModel.Handle) -> String {
        switch handle {
        case .lineA, .lineB: "Drag this end onto the edge the line should follow. Arrow keys move it finely."
        case .foot: "Drag to where the thing of known height meets the floor."
        case .top: "Drag to the top of the thing of known height."
        case .figure: "Drag the figure across the floor to check that it looks person-sized everywhere."
        }
    }
}
