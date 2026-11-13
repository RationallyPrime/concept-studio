import PrevisCore
import SwiftUI

/// Calibration marks are editor chrome. They never enter the exported composition.
struct ShotsPlateOverlay: View {
    let frame: SceneFrame

    var body: some View {
        Canvas { context, size in
            if let plate = frame.plate {
                let rect = plate.imageRect(in: frame.canvas.pixelSize)
                context.clip(to: Path(CGRect(
                    x: rect.x / Double(frame.canvas.width) * size.width,
                    y: rect.y / Double(frame.canvas.height) * size.height,
                    width: rect.width / Double(frame.canvas.width) * size.width,
                    height: rect.height / Double(frame.canvas.height) * size.height
                )))
            }
            func project(_ point: Vec3) -> CGPoint? {
                guard let point = frame.project(point, size: frame.canvas.pixelSize) else { return nil }
                return CGPoint(
                    x: point.x / Double(frame.canvas.width) * size.width,
                    y: point.y / Double(frame.canvas.height) * size.height
                )
            }
            func line(_ start: Vec3, _ end: Vec3, color: Color, width: CGFloat = 1) {
                let clipped = Self.clip(start, end, camera: frame.camera)
                guard let clipped, let a = project(clipped.0), let b = project(clipped.1) else { return }
                var path = Path()
                path.move(to: a)
                path.addLine(to: b)
                context.stroke(path, with: .color(.black.opacity(0.7)), lineWidth: width + 2)
                context.stroke(path, with: .color(color), lineWidth: width)
            }
            for index in -12 ... 12 {
                let distance = Double(index)
                line(Vec3(distance, 0, -12), Vec3(distance, 0, 4), color: .white.opacity(0.6))
                line(Vec3(-12, 0, distance), Vec3(12, 0, distance), color: .white.opacity(0.6))
            }
            line(.zero, Vec3(0, 1.8, 0), color: .yellow, width: 3)
            if let top = project(Vec3(0, 1.8, 0)) {
                context.draw(Text("1.8 m").font(.caption.bold()).foregroundColor(.yellow), at: top, anchor: .bottom)
            }
            for piece in frame.setPieces {
                let x = piece.size.x / 2, z = piece.size.z / 2
                let p = piece.position
                let lower = [
                    Vec3(p.x - x, p.y, p.z - z),
                    Vec3(p.x + x, p.y, p.z - z),
                    Vec3(p.x + x, p.y, p.z + z),
                    Vec3(p.x - x, p.y, p.z + z),
                ]
                let upper = lower.map { Vec3($0.x, $0.y + piece.size.y, $0.z) }
                for index in 0 ..< 4 {
                    line(lower[index], lower[(index + 1) % 4], color: .cyan)
                    line(upper[index], upper[(index + 1) % 4], color: .cyan)
                    line(lower[index], upper[index], color: .cyan)
                }
                if let point = project(Vec3(p.x, p.y + piece.size.y, p.z)) {
                    context.draw(Text(piece.name).font(.caption.bold()).foregroundColor(.cyan), at: point)
                }
            }
        }
    }

    /// Keeps both vanishing-line families when a grid segment crosses behind the camera.
    nonisolated static func clip(_ start: Vec3, _ end: Vec3, camera: CameraFrame) -> (Vec3, Vec3)? {
        let view = camera.viewMatrix()
        let startDepth = -view.transform(start).z, endDepth = -view.transform(end).z
        guard startDepth >= CameraFrame.near || endDepth >= CameraFrame.near else { return nil }
        func point(_ fraction: Double) -> Vec3 {
            Vec3(
                start.x + (end.x - start.x) * fraction,
                start.y + (end.y - start.y) * fraction,
                start.z + (end.z - start.z) * fraction
            )
        }
        let clippedStart = startDepth >= CameraFrame.near ? start
            : point((CameraFrame.near - startDepth) / (endDepth - startDepth))
        let clippedEnd = endDepth >= CameraFrame.near ? end
            : point((CameraFrame.near - startDepth) / (endDepth - startDepth))
        return (clippedStart, clippedEnd)
    }
}
