import Foundation

/// The inspector links each duplicate to an earlier sample; collect the full chain into one group.
enum DuplicateCuration {
    static func groups(images: [ProjectImage], analyses: [String: ImageAnalysis]) -> [[ProjectImage]] {
        var groups: [String: [ProjectImage]] = [:]
        for image in images {
            var root = image.id
            var seen: Set<String> = []
            while let previous = analyses[root]?.duplicateOf, seen.insert(root).inserted {
                root = previous
            }
            groups[root, default: []].append(image)
        }
        return groups.values.filter { $0.count > 1 }.map { $0.sorted { $0.id < $1.id } }
            .sorted { $0[0].id < $1[0].id }
    }

    static func recommendedExclusions(groups: [[ProjectImage]], analyses: [String: ImageAnalysis]) -> Set<String> {
        Set(groups.flatMap { group in
            let ranked = group.sorted {
                let lhs = analyses[$0.id], rhs = analyses[$1.id]
                let leftPixels = Int64(lhs?.width ?? 0) * Int64(lhs?.height ?? 0)
                let rightPixels = Int64(rhs?.width ?? 0) * Int64(rhs?.height ?? 0)
                return leftPixels == rightPixels ? $0.id < $1.id : leftPixels > rightPixels
            }
            return ranked.dropFirst().map(\.id)
        })
    }
}

@MainActor
extension StudioSession {
    func excludeDuplicates(_ ids: Set<String>) {
        guard !busy, !editing else { return }
        do {
            for id in ids.sorted() {
                try project?.setIncluded(id, false)
            }
            invalidateMappingUndo()
            startImageAnalysis()
            message = "Excluded \(ids.count) duplicate samples. Undo can restore them."
        } catch { errorMessage = Self.describe(error) }
    }
}
