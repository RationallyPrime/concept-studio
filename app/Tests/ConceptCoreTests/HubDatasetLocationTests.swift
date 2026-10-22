import ConceptCore
import Foundation
import Testing

@Suite("Hub dataset selections")
struct HubDatasetLocationTests {
    @Test func acceptsDatasetNamesURLsAndFolders() throws {
        let named = try HubDatasetLocation(" owner/dataset ")
        #expect(named.repo.id == "owner/dataset")
        #expect(named.revision == "main")
        #expect(named.suggestedProjectName == "dataset")
        let folder = try HubDatasetLocation("https://huggingface.co/datasets/owner/data/tree/v2/train/people?x=1")
        #expect(folder.repo.id == "owner/data")
        #expect(folder.revision == "v2")
        #expect(folder.subfolder == "train/people")
        #expect(folder.suggestedProjectName == "people")
        #expect(try HubDatasetLocation("owner/data/train/people").subfolder == "train/people")
        #expect(try HubDatasetLocation("hf.co/datasets/owner/data").repo.id == "owner/data")
        #expect(try HubDatasetLocation("owner/data", subfolder: " train/people/ ").subfolder == "train/people")
    }

    @Test func explicitFolderReplacesURLFolderAndEncodedRevisionSurvives() throws {
        let location = try HubDatasetLocation(
            "https://huggingface.co/datasets/ns/repo/tree/refs%2Fconvert%2Fparquet/old", subfolder: "new"
        )
        #expect(location.revision == "refs/convert/parquet")
        #expect(location.subfolder == "new")
    }

    @Test(arguments: [
        "",
        "dataset",
        "https://example.org/datasets/ns/repo",
        "https://huggingface.co/ns/model",
        "https://huggingface.co/datasets/ns/repo/tree",
        "owner/data/../other",
    ])
    func rejectsInvalidSelections(_ input: String) {
        #expect(throws: (any Error).self) { try HubDatasetLocation(input) }
    }

    @Test func importsOnlySelectedFolderAndPreservesItsMetadata() async throws {
        let transport = StubTransport { request in
            switch Hub.route(request) {
            case "GET /api/datasets/ns/name/tree/v2":
                try StubTransport.json([
                    Hub.file("train/a.png", size: 4, lfs: false),
                    Hub.file("train/nested/b.png", size: 4, lfs: false),
                    Hub.file("training/c.png", size: 4, lfs: false),
                    Hub.file("metadata.jsonl", size: 4, lfs: false),
                    Hub.file("train/metadata.jsonl", size: 4, lfs: false),
                ])
            case "GET /datasets/ns/name/resolve/v2/metadata.jsonl":
                HTTPResponse(status: 200, body: ImageFolderMetadata.serialize([
                    MetadataRow(fileName: "train/a.png", caption: "root caption"),
                    MetadataRow(fileName: "training/c.png", caption: "outside"),
                ]))
            case "GET /datasets/ns/name/resolve/v2/train/metadata.jsonl":
                HTTPResponse(status: 200, body: ImageFolderMetadata.serialize([
                    MetadataRow(fileName: "a.png", caption: "folder caption"),
                    MetadataRow(fileName: "nested/b.png", caption: "nested photo"),
                ]))
            default: HTTPResponse(status: 404)
            }
        }
        let source = try await HubFolderSource.open(
            client: Hub.client(transport), repo: RepoID(Hub.repo), revision: "v2", subfolder: "train"
        )
        #expect(source.files.map(\.path) == ["train/a.png", "train/nested/b.png"])
        #expect(source.rows.map(\.fileName) == ["train/a.png", "train/nested/b.png"])
        #expect(source.rows.first?.caption == "folder caption")
        let nested = try await HubFolderSource.open(
            client: Hub.client(transport), repo: RepoID(Hub.repo), revision: "v2", subfolder: "train/nested"
        )
        #expect(nested.files.map(\.path) == ["train/nested/b.png"])
        #expect(nested.rows.first?.caption == "nested photo")
    }
}
