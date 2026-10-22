import Foundation

/// Why a listed cloud GPU cannot be chosen.
enum GPUUnavailability: Equatable {
    case notEnoughMemory(model: String)
    case gatedModelNeedsHubTokenInSettings(model: String)
    case gatedModelNeedsHubToken(model: String)
    case notOffered(count: Int)
    case storageNotFound
    case savedStorageIsSecureOnly
    case noStockBesideStorage(dataCenter: String)
    case noStock

    var explanation: String {
        switch self {
        case let .notEnoughMemory(model): "Not enough graphics memory for \(model)"
        case let .gatedModelNeedsHubTokenInSettings(model): "\(model) needs a Hugging Face token in Settings"
        case let .gatedModelNeedsHubToken(model): "\(model) needs your Hugging Face token, kept off Community Cloud"
        case let .notOffered(count): "Not available as \(count) GPUs"
        case .storageNotFound: "Your saved storage was not found. Refresh the list."
        case .savedStorageIsSecureOnly: "Saved storage is Secure Cloud only"
        case let .noStockBesideStorage(dataCenter): "No stock in \(dataCenter), where your saved storage is"
        case .noStock: "No stock right now"
        }
    }
}

/// One row of the cloud GPU list.
struct GPUChoice: Identifiable {
    let offer: GPUOffer
    /// The price for the chosen number of GPUs.
    let hourlyPrice: Double
    /// Stock where this GPU would run: beside the saved storage, or anywhere without it.
    let stock: GPUStock
    let unavailability: GPUUnavailability?

    var id: String {
        offer.id
    }

    var memory: Int {
        offer.memory
    }

    var label: String {
        offer.cloud == .community ? "\(offer.name) · Community" : offer.name
    }

    var isSelectable: Bool {
        unavailability == nil
    }

    var availabilityText: String {
        if let unavailability { return unavailability.explanation }
        return switch stock {
        case .high: "High"
        case .medium: "Medium"
        case .low: "Low"
        case .none: GPUUnavailability.noStock.explanation
        }
    }
}

extension GPUWorkspace {
    /// Every offer the filters let through, including those that can't be chosen now, in the provider's order.
    var gpuChoices: [GPUChoice] {
        let volume = volumes.first { $0.id == selectedVolume }
        return offers.compactMap { offer in
            guard includeCommunityCloud || offer.cloud == .secure, offer.memory >= minimumMemoryFilter else {
                return nil
            }
            let stock = offer.stock(in: volume?.dataCenter)
            guard !inStockOnly || stock != .none else { return nil }
            return GPUChoice(
                offer: offer, hourlyPrice: offer.price * Double(gpuCount), stock: stock,
                unavailability: unavailability(of: offer, volume: volume, stock: stock)
            )
        }
    }

    /// The list as shown: GPUs that can be chosen first, then the rest, each part in `order`.
    func gpuChoices(sortedBy order: [KeyPathComparator<GPUChoice>]) -> [GPUChoice] {
        let sorted = gpuChoices.sorted(using: order + [KeyPathComparator(\.label), KeyPathComparator(\.id)])
        return sorted.filter(\.isSelectable) + sorted.filter { !$0.isSelectable }
    }

    /// The offers that can be rented now, cheapest first.
    var availableOffers: [GPUOffer] {
        gpuChoices.filter(\.isSelectable).map(\.offer)
    }

    /// Sizes for the minimum graphics memory filter; 0 means any.
    var memoryFilterChoices: [Int] {
        Set([0, minimumMemoryFilter] + offers.map(\.memory)).sorted()
    }

    var quotedHourlyRate: Double {
        (availableOffers.first { $0.id == selectedGPU }?.price ?? 0) * Double(gpuCount)
    }

    func selectAvailableOffer() {
        if !availableOffers.contains(where: { $0.id == selectedGPU }) {
            selectedGPU = availableOffers.first?.id ?? ""
        }
    }

    private func unavailability(of offer: GPUOffer, volume: GPUVolume?, stock: GPUStock) -> GPUUnavailability? {
        if offer.memory < requiredGPUMemoryGB { return .notEnoughMemory(model: effectiveModelRow.shortName) }
        // A gated model downloads only with the Hub token: none is configured, or Community Cloud GPUs never
        // get it. A rental made from Captioning trains nothing, so neither applies to it.
        if !rentsCaptionServer, let row = gatedModelWithoutHubToken {
            return .gatedModelNeedsHubTokenInSettings(model: row.shortName)
        }
        if offer.cloud == .community, !rentsCaptionServer, let row = exactModelRow, row.source.gated {
            return .gatedModelNeedsHubToken(model: row.shortName)
        }
        if offer.maxCount < gpuCount { return .notOffered(count: gpuCount) }
        if !selectedVolume.isEmpty {
            // RunPod network volumes live only in Secure Cloud data centres.
            guard let volume else { return .storageNotFound }
            if offer.cloud == .community { return .savedStorageIsSecureOnly }
            if stock == .none { return .noStockBesideStorage(dataCenter: volume.dataCenter) }
        }
        return stock == .none ? .noStock : nil
    }
}
