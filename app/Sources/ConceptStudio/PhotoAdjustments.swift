import CoreGraphics
import CoreImage
import Foundation

struct PhotoAdjustments: Codable, Equatable, Sendable {
    var autoEnhance = false
    var exposure = 0.0
    var highlights = 1.0
    var shadows = 0.0
    var temperature = 6500.0
    var tint = 0.0
    var quarterTurns = 0
    var straightenDegrees = 0.0
    var crop = CGRect(x: 0, y: 0, width: 1, height: 1)
    /// Per-image colour-outlier correction, kept with the editable recipe.
    var redGain = 1.0
    var blueGain = 1.0
}

struct PhotoEditRecord: Codable, Equatable, Sendable {
    var originalFile: String
    var originalName: String
    var adjustments: PhotoAdjustments
}

enum PhotoEditing {
    static func render(_ image: CGImage, adjustments: PhotoAdjustments, crop: Bool = true) throws -> CGImage {
        var result = CIImage(cgImage: image)
        if adjustments.autoEnhance {
            for filter in result.autoAdjustmentFilters(options: [
                .enhance: true, .redEye: false, .crop: false, .level: false,
            ]) {
                filter.setValue(result, forKey: kCIInputImageKey)
                if let enhanced = filter.outputImage { result = enhanced }
            }
        }
        result = result.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: adjustments.exposure])
        result = result.applyingFilter("CIHighlightShadowAdjust", parameters: [
            "inputHighlightAmount": adjustments.highlights, "inputShadowAmount": adjustments.shadows,
        ])
        result = result.applyingFilter("CITemperatureAndTint", parameters: [
            "inputNeutral": CIVector(x: 6500, y: 0),
            "inputTargetNeutral": CIVector(x: adjustments.temperature, y: adjustments.tint),
        ])
        result = result.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: adjustments.redGain, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: adjustments.blueGain, w: 0),
        ])
        let turns = ((adjustments.quarterTurns % 4) + 4) % 4
        for _ in 0 ..< turns {
            result = result.oriented(.right)
        }
        if adjustments.straightenDegrees != 0 {
            result = result.applyingFilter("CIStraightenFilter", parameters: [
                kCIInputAngleKey: adjustments.straightenDegrees * .pi / 180,
            ])
        }
        let extent = result.extent
        result = result.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        var target = result.extent
        if crop {
            let rectangle = adjustments.crop
            guard rectangle.minX >= 0, rectangle.minY >= 0, rectangle.maxX <= 1, rectangle.maxY <= 1,
                  rectangle.width > 0, rectangle.height > 0 else {
                throw StudioError.message("Keep the crop inside the photo.")
            }
            target = CGRect(
                x: rectangle.minX * target.width, y: (1 - rectangle.maxY) * target.height,
                width: rectangle.width * target.width, height: rectangle.height * target.height
            ).integral.intersection(result.extent)
        }
        guard let output = CIContext().createCGImage(result, from: target) else {
            throw StudioError.message("These photo adjustments could not be rendered.")
        }
        return output
    }

    /// Measures each image independently; no image is changed during the dataset scan.
    static func statistics(_ image: CGImage) throws -> PhotoStatistics {
        var rgba = [UInt8](repeating: 0, count: 64 * 64 * 4)
        let success = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 64, height: 64))
            return true
        }
        guard success else { throw StudioError.message("This photo could not be measured.") }
        var red = 0.0, green = 0.0, blue = 0.0, count = 0.0
        for pixel in stride(from: 0, to: rgba.count, by: 4) where rgba[pixel + 3] > 127 {
            red += Double(rgba[pixel]) / 255
            green += Double(rgba[pixel + 1]) / 255
            blue += Double(rgba[pixel + 2]) / 255
            count += 1
        }
        guard count > 0 else { throw StudioError.message("This photo has no visible pixels.") }
        red = max(0.01, red / count); green = max(0.01, green / count); blue = max(0.01, blue / count)
        return PhotoStatistics(
            exposure: log2(0.2126 * red + 0.7152 * green + 0.0722 * blue),
            redBalance: log(red / green), blueBalance: log(blue / green)
        )
    }
}

struct PhotoStatistics: Equatable, Sendable {
    var exposure: Double
    var redBalance: Double
    var blueBalance: Double
}

struct PhotoOutlier: Identifiable, Sendable {
    var id: String
    var exposure: Double
    var redGain: Double
    var blueGain: Double
    var reason: String

    func applying(to adjustments: PhotoAdjustments) -> PhotoAdjustments {
        var result = adjustments
        result.exposure += exposure
        result.redGain *= redGain
        result.blueGain *= blueGain
        return result
    }
}

enum PhotoOutliers {
    /// Robust per-dataset centre and spread. Only outliers receive a correction;
    /// the floor prevents near-identical measurements from flagging ordinary variation.
    static func suggestions(_ samples: [String: PhotoStatistics]) -> [PhotoOutlier] {
        guard samples.count >= 4 else { return [] }
        let values = Array(samples.values)
        let exposure = median(values.map(\.exposure)), red = median(values.map(\.redBalance))
        let blue = median(values.map(\.blueBalance))
        let exposureLimit = max(0.6, 3.5 * median(values.map { abs($0.exposure - exposure) }))
        let redLimit = max(0.2, 3.5 * median(values.map { abs($0.redBalance - red) }))
        let blueLimit = max(0.2, 3.5 * median(values.map { abs($0.blueBalance - blue) }))
        return samples.sorted { $0.key < $1.key }.compactMap { id, sample in
            let exposureOutlier = abs(sample.exposure - exposure) > exposureLimit
            let redOutlier = abs(sample.redBalance - red) > redLimit
            let blueOutlier = abs(sample.blueBalance - blue) > blueLimit
            guard exposureOutlier || redOutlier || blueOutlier else { return nil }
            return PhotoOutlier(
                id: id,
                exposure: exposureOutlier ? min(1.5, max(-1.5, exposure - sample.exposure)) : 0,
                redGain: redOutlier ? min(1.4, max(0.7, exp(red - sample.redBalance))) : 1,
                blueGain: blueOutlier ? min(1.4, max(0.7, exp(blue - sample.blueBalance))) : 1,
                reason: exposureOutlier && (redOutlier || blueOutlier) ? "Exposure and colour stand apart" :
                    exposureOutlier ? "Exposure stands apart" : "Colour stands apart"
            )
        }
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted(), middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}
