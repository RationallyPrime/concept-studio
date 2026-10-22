import Foundation

/// A dataset selection shared by new-project and existing-project imports.
public struct HubDatasetLocation: Sendable, Equatable {
    public let repo: RepoID
    public let revision: String
    public let subfolder: String

    public var suggestedProjectName: String {
        subfolder.split(separator: "/").last.map(String.init) ?? repo.name
    }

    public init(_ input: String, subfolder: String = "") throws {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var revision = "main"
        var folder = ""
        let repoText: String
        if text.contains("://") || text.hasPrefix("huggingface.co/") || text.hasPrefix("hf.co/") {
            let address = text.contains("://") ? text : "https://" + text
            guard let url = URLComponents(string: address), url.scheme == "https",
                  ["huggingface.co", "www.huggingface.co", "hf.co"].contains(url.host?.lowercased() ?? "")
            else { throw HubError.malformed("Paste a Hugging Face dataset URL or enter owner/dataset.") }
            let parts = url.percentEncodedPath.split(separator: "/").map {
                String($0).removingPercentEncoding ?? String($0)
            }
            guard parts.count >= 3, parts[0] == "datasets" else {
                throw HubError.malformed("Choose a dataset URL, such as https://huggingface.co/datasets/owner/name.")
            }
            repoText = parts[1] + "/" + parts[2]
            if parts.count > 3 {
                guard parts.count >= 5, parts[3] == "tree", !parts[4].isEmpty else {
                    throw HubError.malformed("Use the dataset's Files and versions URL, with /tree/revision/folder.")
                }
                revision = parts[4]
                folder = parts.dropFirst(5).joined(separator: "/")
            }
        } else {
            let parts = text.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count >= 2 else {
                throw HubError.malformed("Enter the dataset owner and name, such as owner/dataset.")
            }
            repoText = parts.prefix(2).joined(separator: "/")
            folder = parts.dropFirst(2).joined(separator: "/")
        }
        let chosenFolder = subfolder.trimmingCharacters(in: .whitespacesAndNewlines)
        if !chosenFolder.isEmpty { folder = chosenFolder }
        folder = folder.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard folder.split(separator: "/").allSatisfy({ $0 != "." && $0 != ".." }) else {
            throw HubError.malformed("Choose a subfolder inside the dataset without . or .. path components.")
        }
        repo = try RepoID(repoText)
        self.revision = revision
        self.subfolder = folder
    }
}
