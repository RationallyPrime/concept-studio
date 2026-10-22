import ConceptCore
import Foundation

extension StudioSession {
    // MARK: Confirmations

    /// Ask the user and wait for the answer, through the window's one prompt (`ask(_:)`). A newer
    /// question replaces (and declines) an older one.
    func confirm(_ confirmation: StudioConfirmation) async -> Bool {
        switch confirmation {
        case .discardCaptionDrafts:
            await ask(.discardCaptionDrafts(warning: confirmation.message)) == .confirm
        case .stopAndClose:
            await ask(.stopWork(runningWork(for: .closeProject))) == .confirm
        }
    }

    /// Run `action` now when nothing needs confirming, otherwise after the user confirms.
    func whenConfirmed(_ confirmation: StudioConfirmation?, _ action: @escaping @MainActor () -> Void) {
        guard let confirmation else { return action() }
        Task { if await confirm(confirmation) { action() } }
    }

    var discardDraftsConfirmation: StudioConfirmation? {
        unsavedCaptionCount > 0 ? .discardCaptionDrafts(count: unsavedCaptionCount) : nil
    }

    // MARK: Startup and projects

    static func startupNeedsPodRecovery(_ data: Data?) -> Bool {
        guard let data, let saved = try? JSONDecoder().decode(SavedPod.self, from: data) else { return false }
        return saved.pod.isRunning
    }

    func restoreStartupComputer() {
        guard !startupRestored else { return }
        startupRestored = true
        guard !demoMode, Self.startupNeedsPodRecovery(preferences.data(forKey: "ConceptStudio.activePod"))
        else { return }
        do {
            // Restore the known running state before credentials can fail or Welcome actions can replace it.
            try gpu.configure(runpodKey: "", hubToken: "", imageName: podImageName)
        } catch {
            errorMessage = Self.describe(error)
            gpu.message = "A retained cloud GPU may still be billing. Add your RunPod key in Settings and stop it."
        }
        configureGPU()
    }

    private func refuseWhileComputerBusy(_ reason: String) -> Bool {
        guard gpu.hasRunningPod || gpu.isBusy else { return false }
        errorMessage = reason
        return true
    }

    func useDemo() {
        restoreStartupComputer()
        guard !refuseWhileComputerBusy("Stop the cloud GPU before switching to the demo.") else { return }
        whenConfirmed(discardDraftsConfirmation) {
            self.perform("Opening the offline demo…") {
                await self.releaseProject()
                self.demoMode = true
                self.showChatGPTPlanNotice = false
                self.gpu = self.makeGPUWorkspace(demoMode: true)
                self.project = try await DemoProject.create(at: self.demoDirectory)
                self.gpu.projectFolder = self.project?.directory
                self.projectState = ProjectAppState(dataset: HubDestination(repo: "demo/concept-studio"))
                self.selectedImageID = self.project?.images.first?.id
                self.step = .images
                self.message = "Offline demo: synthetic photos, prepared captions and simulated services."
                self.startImageAnalysis()
            }
        }
    }

    func createProject(at url: URL, importing location: HubDatasetLocation? = nil) {
        guard !refuseWhileComputerBusy(
            "Finish the current cloud GPU action or Stop everything before changing projects."
        ) else { return }
        whenConfirmed(discardDraftsConfirmation) {
            self.perform("Creating your project…") {
                // Validate before closing the current project or writing into the chosen folder.
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                let existing = try ProjectAccess.existingProject(at: url)
                let opened: StudioProject = if existing {
                    try await StudioProject.open(at: url)
                } else {
                    try StudioProject.create(at: url)
                }
                await self.releaseProject()
                self.demoMode = false
                self.loadSavedChoices()
                self.gpu = self.makeGPUWorkspace(demoMode: false)
                self.projectAccess = url
                _ = url.startAccessingSecurityScopedResource()
                self.project = opened
                self.gpu.projectFolder = opened.directory
                self.projectState = existing ? ProjectAppState.load(from: url) : ProjectAppState()
                self.rememberRecent(url)
                if existing { self.applyJobChoices(opened.job) }
                self.selectedImageID = opened.images.first?.id
                self.step = .images
                self.message = existing ? "Project opened."
                    : "Project created. Import the images or clips for your concept."
                if existing { self.startImageAnalysis() }
                // An existing project is opened as-is, never silently appended to by New project.
                if let location, !existing { try await self.downloadHub(location) }
            }
        }
    }

    func openProject(url selected: URL) {
        guard !refuseWhileComputerBusy(
            "Finish the current cloud GPU action or Stop everything before changing projects."
        ) else { return }
        whenConfirmed(discardDraftsConfirmation) {
            self.perform("Opening your project…") {
                await self.releaseProject()
                self.demoMode = false
                self.loadSavedChoices()
                self.gpu = self.makeGPUWorkspace(demoMode: false)
                self.projectAccess = selected
                _ = selected.startAccessingSecurityScopedResource()
                self.project = try await StudioProject.open(at: selected)
                self.gpu.projectFolder = self.project?.directory
                self.projectState = ProjectAppState.load(from: selected)
                self.rememberRecent(selected)
                if let job = self.project?.job { self.applyJobChoices(job) }
                self.selectedImageID = self.project?.images.first?.id
                self.message = "Project opened. Your saved choices and final captions are preserved."
                self.migrateOutsideSkill()
                self.startImageAnalysis()
            }
        }
    }

    func releaseProject() async {
        activePublishID = nil
        chatGPTWorkGeneration += 1
        await chatGPT.cancelAndWait()
        await openRouter.cancelAndWait()
        stopImageAnalysis()
        editTask?.cancel()
        await editTask?.value
        if let prompt = pendingPrompt { answer(prompt, .cancel) }
        if demoMode, let directory = project?.directory,
           directory.standardizedFileURL == demoDirectory.standardizedFileURL {
            DemoProject.remove(at: directory)
        }
        projectAccess?.stopAccessingSecurityScopedResource()
        projectAccess = nil
        project = nil
        projectState = ProjectAppState()
        analyses = [:]
        mappingProposals = [:]
        datasetAdvice = ""
        comparison = ""
        captionDrafts = [:]
        runPendingIDs = []
        usingPodCaptioner = false
        requestBaseURL = ""
        mappingUndo = []
    }

    func closeProject() async {
        if demoMode {
            activePublishID = nil
            task?.cancel()
            editTask?.cancel()
            await task?.value
            await editTask?.value
            let closingDemoWorkspace = gpu.demoMode
            if closingDemoWorkspace { await gpu.stopEverything() }
            await releaseProject()
            demoMode = false
            if closingDemoWorkspace {
                gpu = makeGPUWorkspace(demoMode: false)
                configureGPU()
            } else {
                // A crossed/stale demo flag must never stop or detach a real rented computer.
                gpu.projectFolder = nil
            }
            return
        }
        await stopEverything()
        guard !gpu.hasRunningPod else { errorMessage = gpu.message; return }
        await releaseProject()
    }

    func stopEverything() async {
        chatGPTWorkGeneration += 1
        await chatGPT.cancelAndWait()
        await openRouter.cancelAndWait()
        task?.cancel()
        editTask?.cancel()
        stopImageAnalysis()
        await task?.value
        await editTask?.value
        await gpu.stopEverything()
    }

    func saveProject() {
        do {
            try project?.save()
            message = unsavedCaptionCount > 0
                ? "Project configuration saved. "
                + "Save your \(unsavedCaptionCount) caption drafts on Review before closing."
                : "Project saved."
        } catch { errorMessage = Self.describe(error) }
    }

    // MARK: Photos and analysis

    func importImages(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        perform("Importing training data…") {
            guard var project = self.project else { return }
            let projectDirectory = project.directory.standardizedFileURL
            defer {
                if self.project?.directory.standardizedFileURL == projectDirectory { self.project = project }
            }
            for url in urls {
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                try await project.importFiles([url], fromFolder: false)
                try Task.checkCancellation()
                guard self.busy, self.project?.directory.standardizedFileURL == projectDirectory else {
                    throw CancellationError()
                }
                self.project = project
                self.completed += 1
            }
            self.selectedImageID = self.project?.images.first?.id
            self.startImageAnalysis()
            self.message = "Training data imported. Review the selected images and clips before captioning."
        }
    }

    func importFolder(_ folder: URL) {
        perform("Importing folder contents…") {
            guard var project = self.project else { return }
            let projectDirectory = project.directory.standardizedFileURL
            defer {
                if self.project?.directory.standardizedFileURL == projectDirectory { self.project = project }
            }
            let accessed = folder.startAccessingSecurityScopedResource()
            defer { if accessed { folder.stopAccessingSecurityScopedResource() } }
            let files = try MediaEditor.importableFiles(in: folder)
            try await project.importFiles(files)
            try Task.checkCancellation()
            guard self.busy, self.project?.directory.standardizedFileURL == projectDirectory else {
                throw CancellationError()
            }
            self.project = project
            self.selectedImageID = self.project?.images.first?.id
            self.startImageAnalysis()
            self.message = "Imported \(files.count) images and clips, including subfolders."
        }
    }
}
