import Foundation
@testable import PrevisCore
import Testing

struct PlateTests {
    private let size = PixelSize(width: 1440, height: 2560)

    /// The line a camera sees between two world points, as the user would draw it over the plate.
    private func line(_ a: Vec3, _ b: Vec3, through camera: CameraFrame) throws -> PlateLine {
        let start = try #require(camera.project(a, size: size)), end = try #require(camera.project(b, size: size))
        func fraction(_ pixel: Point2) -> Point2 {
            Point2(x: pixel.x / Double(size.width), y: pixel.y / Double(size.height))
        }
        return PlateLine(a: fraction(start), b: fraction(end))
    }

    @Test func linesAndAHeightReferenceRecoverTheCameraThatTookThePlate() throws {
        let truth = PlateMatch(
            position: Vec3(0, 1.7, 0), pan: 0.3, tilt: -0.15, roll: 0.03, focalLength: 30, sensor: .super35
        )
        let camera = truth.camera(aspect: size.aspect)
        let guides = try PlateGuides(
            linesA: [
                line(Vec3(-2, 0, -4), Vec3(2, 0, -4), through: camera),
                line(Vec3(-2, 0, -7), Vec3(2, 0, -7), through: camera),
            ],
            linesB: [
                line(Vec3(-1, 0, -3), Vec3(-1, 0, -8), through: camera),
                line(Vec3(1.5, 0, -3), Vec3(1.5, 0, -8), through: camera),
            ],
            heightReference: PlateHeightReference(
                foot: line(Vec3(0.5, 0, -5), Vec3(0.5, 2, -5), through: camera).a,
                top: line(Vec3(0.5, 0, -5), Vec3(0.5, 2, -5), through: camera).b,
                height: 2
            )
        )
        let solved = try PlateSolve.match(guides: guides, size: size, sensor: .super35)
        #expect(abs(solved.focalLength - 30) < 0.05)
        #expect(abs(solved.tilt - truth.tilt) < 1e-4)
        #expect(abs(solved.roll - truth.roll) < 1e-4)
        #expect(abs(solved.pan - truth.pan) < 1e-4)
        #expect(abs(solved.position.y - 1.7) < 1e-3)
        // The proof that matters: a point on the floor lands on the same pixel through the solved camera.
        let probe = Vec3(-1.2, 0, -6.5)
        let expected = try #require(camera.project(probe, size: size))
        let got = try #require(solved.camera(aspect: size.aspect).project(probe, size: size))
        #expect(abs(expected.x - got.x) < 0.5 && abs(expected.y - got.y) < 0.5)
    }

    @Test func oneSetOfLinesWithAGivenLensFindsTheTiltOfALevelCamera() throws {
        let truth = PlateMatch(
            position: Vec3(0, 1.4, 0), pan: 0, tilt: -0.2, roll: 0, focalLength: 24, sensor: .super35
        )
        let camera = truth.camera(aspect: size.aspect)
        let guides = try PlateGuides(linesA: [
            line(Vec3(-1, 0, -3), Vec3(-1, 0, -9), through: camera),
            line(Vec3(1, 0, -3), Vec3(1, 0, -9), through: camera),
        ])
        let solved = try PlateSolve.match(
            guides: guides, size: size, sensor: .super35, focalLength: 24, cameraHeight: 1.4
        )
        #expect(abs(solved.tilt - truth.tilt) < 1e-4)
        #expect(abs(solved.pan) < 1e-4)
        #expect(solved.position.y == 1.4)
    }

    @Test func aCameraLookingStraightAlongTheSetKeepsItsLensAndStillFindsItsTilt() throws {
        // One pair is parallel in the picture, so no lens follows from the lines; the tilt and height still do.
        let truth = PlateMatch(
            position: Vec3(0, 1.5, 0), pan: 0, tilt: -0.2, roll: 0, focalLength: 28, sensor: .super35
        )
        let camera = truth.camera(aspect: size.aspect)
        let guides = try PlateGuides(
            linesA: [
                line(Vec3(-0.5, 0, -4), Vec3(0.5, 0, -4), through: camera),
                line(Vec3(-0.5, 0, -8), Vec3(0.5, 0, -8), through: camera),
            ],
            linesB: [
                line(Vec3(-0.5, 0, -4), Vec3(-0.5, 0, -8), through: camera),
                line(Vec3(0.5, 0, -4), Vec3(0.5, 0, -8), through: camera),
            ]
        )
        #expect(!PlateSolve.linesGiveLens(guides, size: size))
        var typed = PlateMatch.unmatched
        typed.focalLength = 28
        typed.position.y = 1.5
        let solved = try PlateSolve.match(guides: guides, size: size, sensor: .super35, current: typed)
        #expect(solved.focalLength == 28)
        #expect(abs(solved.tilt - truth.tilt) < 1e-4 && abs(solved.pan) < 1e-4 && abs(solved.roll) < 1e-4)
    }

    @Test func linesThatCannotBeSquareAreRefusedInWords() throws {
        // Both sets converge to the same side of the picture: no lens makes them square on a floor.
        let guides = PlateGuides(
            linesA: [
                PlateLine(a: Point2(x: 0.1, y: 0.6), b: Point2(x: 0.6, y: 0.5)),
                PlateLine(a: Point2(x: 0.1, y: 0.9), b: Point2(x: 0.6, y: 0.7)),
            ],
            linesB: [
                PlateLine(a: Point2(x: 0.2, y: 0.6), b: Point2(x: 0.7, y: 0.52)),
                PlateLine(a: Point2(x: 0.2, y: 0.95), b: Point2(x: 0.7, y: 0.78)),
            ]
        )
        #expect(throws: ShotsError.self) { try PlateSolve.match(guides: guides, size: size, sensor: .super35) }
    }

    @Test func aPlateCoversACanvasOfItsOwnShapeAndNotAWiderOne() {
        let same = PlateFit.rect(plate: size, canvas: PixelSize(width: 576, height: 1024), sensor: .super35)
        #expect(abs(same.x) < 1e-9 && abs(same.width - 576) < 1e-9 && abs(same.height - 1024) < 1e-9)
        let wider = PlateFit.widthMismatch(plate: size, canvas: PixelSize(width: 544, height: 960), sensor: .super35)
        #expect(wider > 0.007 && wider < 0.008)
    }
}
