import ConceptCore
@testable import ConceptStudio
import Foundation
import Testing

@Suite("model and trainer pairings")
@MainActor
struct MultiTrainerModelTests {
    @Test func oneModelHasTwoIndependentRecipes() throws {
        let table = ModelTable.shared
        let krea = "krea/Krea-2-Raw"
        #expect(table.models.filter { $0.modelRef == krea }.count == 1)
        #expect(table.row(modelRef: krea)?.trainer == "musubi")
        #expect(table.pairings(modelRef: krea).map(\.trainer) == ["musubi", "aitoolkit"])
        let old = try #require(table.exact(trainer: "musubi", baseModel: krea))
        let added = try #require(table.exact(trainer: "aitoolkit", baseModel: krea))
        #expect(old.recipeStatus == .verified)
        #expect(added.recipeStatus == .unverified)
        #expect(old.regularization?.mode == .unsupported)
        #expect(added.regularization?.defaultOn == true)
        #expect(added.regularization?.weight == 1)
        #expect(old.recipe.rank == added.recipe.rank)
        #expect(old.recipe.learningRate == added.recipe.learningRate)
        #expect(old.resolution == added.resolution)
        #expect(added.recipe.captionDropout == 0)
    }

    @Test func trainerChoiceChangesPlanAndPreservesExplicitEdits() throws {
        let preferences = IsolatedDefaults()
        defer { preferences.remove() }
        let workspace = GPUWorkspace(demoMode: false, preferences: preferences.defaults)
        workspace.chooseTrainingModel("krea/Krea-2-Raw")
        #expect(workspace.trainer == "musubi")
        #expect(!workspace.usesRegularization)
        workspace.rank = 48
        workspace.chooseTrainingTrainer("aitoolkit")
        #expect(workspace.baseModel == "krea/Krea-2-Raw")
        #expect(workspace.trainer == "aitoolkit")
        #expect(workspace.rank == 48)
        #expect(workspace.usesRegularization)
        #expect(workspace.trainerSettings.captionDropout == 0)
        #expect(workspace.steps == 1600)
        #expect(workspace.effectiveModelRow.recipeStatus == .unverified)
        #expect(workspace.trainingModelOptions(advancedUser: false).filter {
            $0.tag == "krea/Krea-2-Raw"
        }.count == 1)
        workspace.chooseTrainingTrainer("musubi")
        #expect(!workspace.usesRegularization)
        #expect(workspace.exactModelRow?.recipeStatus == .verified)
    }
}
