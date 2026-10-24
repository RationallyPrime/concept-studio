import ConceptCore
import Foundation
import Observation

@MainActor @Observable
final class GPUWorkspace {
    let demoMode: Bool
    var offers: [GPUOffer] = []
    var volumes: [GPUVolume] = []
    /// The chosen offer's `GPUOffer.id`, which names its cloud as well as its GPU type.
    var selectedGPU = ""
    /// Filters above the cloud GPU list. Each change keeps the selection on a GPU the list still offers.
    var includeCommunityCloud = false {
        didSet { selectAvailableOffer() }
    }

    var inStockOnly = false
    /// Graphics memory in decimal GB; 0 shows every size.
    var minimumMemoryFilter = 0 {
        didSet { selectAvailableOffer() }
    }

    var selectedVolume = ""
    @ObservationIgnored var hasLoadedVolumes = false
    var gpuCount = 1
    /// The limit for the next rental. While a pod runs, `activeBudget` is the one enforced.
    var budget = 10.0
    /// The cap selected for the next training run; separate from the whole-computer rental cap.
    var runBudget = 10.0
    var idleMinutes = 15 {
        didSet { persist() }
    }

    /// The person's choice to keep the cloud GPU running however long it sits idle; the spending limit still applies.
    var keepsRunningWhenIdle = false {
        didSet { persist() }
    }

    var pod: RentedPod? {
        didSet {
            if oldValue?.id != pod?.id || oldValue?.isRunning != pod?.isRunning {
                agentStartRevision += 1
                agentReadyAt = nil
                plan = nil
            }
            sleepGuard.hold(!demoMode && pod?.isRunning == true)
            if oldValue?.id != pod?.id { (captionServerActive, captionServerInstalled) = (nil, true) }
            if pod?.isRunning == false { captionServerActive = false }
        }
    }

    var plan: TrainingPlan?
    /// The first authenticated agent response for this start. Image pulling and boot time are never idle time.
    var agentReadyAt: Date?
    @ObservationIgnored var agentStartRevision = 0
    /// nil until this computer's service list has been read; never inferred from the GPU count.
    var captionServerActive: Bool?
    var captionServerInstalled = true // false once the agent reports no caption server in this image
    var rentsCaptionServer = false {
        didSet { selectAvailableOffer() }
    }

    /// The measured default caption model fits the 32 GB GPU recipe; custom models can set their requirement.
    var captionMemoryGB = 32 {
        didSet { selectAvailableOffer() }
    }

    var captionStartupProgress: String?
    var keptPods: [SavedPod] = []
    var storage: AgentStorageUsage?
    var message = "Refresh available cloud GPUs to see current prices."
    var isBusy = false
    var operationRevision = 0
    var isStopping = false
    var elapsedCost = 0.0
    /// The supported models. Every default below starts from its default model's row.
    @ObservationIgnored let modelTable: ModelTable
    var trainer: String {
        didSet {
            if oldValue != trainer {
                baseModel = modelTable.trainerDefault(trainer).modelRef
            }
        }
    }

    var baseModel: String
    /// The training length in the selected model's unit: steps, or passes over each item for an epochs row.
    var steps: Int
    var rank: Int
    var alpha: Int
    var batchSize: Int
    var accumulation: Int
    var nativeRecipe: NativeTrainingRecipe?
    var nativeRecipeOriginal: URL?
    var initialCheckpoint: URL?
    var learningRate: Double
    var checkpointEvery: Int
    var checkpointRetention: Int
    var checkpointPrecision: String
    /// Advanced's trainer settings, defaulting to the selected row's values.
    var trainerSettings: TrainerSettings
    var guidanceLoss = false
    /// The project's choice for H3 clip audio; still images never train audio.
    var trainAudio = true
    /// Advanced's H3 training adapter; nil follows the imported recipe, the repeated run or automatic.
    var trainingAdapterChoice: H3TrainingAdapter?
    var guidanceTargetText = GPUWorkspace.defaultGuidanceTarget

    /// Training resolution in pixels; one of `resolutionChoices`. Shown under Advanced.
    var trainingResolutions: [Int]

    /// Regularisation images drawn from the base model and trained beside the person's own (the row's
    /// `regularization` field). Only meaningful while the selected model offers it.
    var trainingAugmentation = TrainingAugmentation.none
    var squareAugmentationAllowed = false
    var regularizationOn = false
    var ownRegularizationImages = false
    var regularizationFolder: URL?
    /// A saved run may reuse its already captioned class folder on retained cloud storage.
    var regularizationRemotePath: String?
    var regularizationImages: Int
    var regularizationWeight: Double
    /// The offer the count and strength last followed, to tell a value the person edited from one still at a default.
    @ObservationIgnored var regularizationAligned: ModelRow.Regularization?
    /// Representation alignment (the row's `repa` field); off unless a row turns it on by default.
    var repaOn = false
    /// The open project's concepts as trigger → class noun. Regularisation images show the class nouns.
    var conceptClassNouns: [String: String] = [:]
    /// Set while the pod draws regularisation images, before the trainer reports its first measurement.
    var regularizationProgress: RegularizationProgress?

    /// Sample images during training. Off by default: sample generation is unverified (POD-SPEC 4.2).
    var samplesEnabled = false
    var runID = ""
    static let defaultSeed = 42
    var seed = GPUWorkspace.defaultSeed
    var datasetRevision = ""
    var datasetContainsVideo = false
    /// How many images and clips the next run trains on; an epochs row turns passes into steps with it.
    var datasetItemCount = 0
    var runHistory: [TrainingRun] = []
    var selectedHistoryRunID = ""
    var repeatSourceRunID = ""
    var generations: [GeneratedComparison] = []
    var reportGroups: [TrainingReportGroup] = []
    var trainingReports: [TrainingReport] = []
    var selectedReportGroupID = ""
    var reportSetupFailure: String?
    var activeReportRunID: String?
    @ObservationIgnored var reportTask: Task<Void, Never>?
    var generation: GeneratedComparison?
    var triggerWords = "NORA7"
    var profile: String
    var keepCaptionServer = false
    /// The model the caption server starts: Captioning's "My cloud GPU / custom server" model, remembered.
    var captionModel = ProviderChoices.defaultModel(for: "vllm") {
        didSet { if !demoMode { preferences.set(captionModel, forKey: Self.captionModelKey) } }
    }

    var points: [TrainingPoint] = []
    var logs = ""
    var trainingState = "Not started"
    /// The latest run's result and where it went.
    var result: TrainingResult?
    /// Running pods this app created that are not the one under its control (found on launch).
    var strayPods: [RentedPod] = []
    /// The open project; results without a Hub token are saved under `<project>/results/<run-id>/`.
    var projectFolder: URL? {
        didSet { if oldValue != projectFolder { loadProjectRecord() } }
    }

    /// The pod agent's bearer (also its vLLM key). Set only by renting, restoring or reconciling.
    private(set) var agentToken = ""
    /// A failure the window alert should show even when the GPU screen is not open.
    var failure: String?

    @ObservationIgnored let transport: any HTTPTransport
    @ObservationIgnored let preferences: UserDefaults
    @ObservationIgnored let saveAgentToken: (String, String) throws -> Void
    @ObservationIgnored let readAgentToken: (String) throws -> String?
    @ObservationIgnored let deleteAgentToken: (String) throws -> Void
    @ObservationIgnored let uploader: any FileUploading
    @ObservationIgnored let downloader: any FileDownloading
    @ObservationIgnored let sleepGuard: SleepAssertion
    @ObservationIgnored var provider: (any GPUProvider)?
    @ObservationIgnored var agent: (any PodAgent)?
    /// Observed: whether training reads a published dataset or uploads directly depends on it.
    var hubToken = ""
    @ObservationIgnored var imageName = ""
    @ObservationIgnored var saved: SavedPod?
    @ObservationIgnored var lastActivity = Date()
    /// The status line a failed refresh wrote; the next refresh that succeeds clears it.
    @ObservationIgnored var refreshFailureMessage: String?
    /// Work the app does for the computer outside `perform`, such as publishing the dataset it trains on.
    /// The idle stop waits for it and counts idle time from when it ends.
    @ObservationIgnored var appWorkInFlight = 0
    /// The stopped computer's host had no free GPU when asked to start; Remove and rent is the way out.
    var restartBlockedByHost = false
    @ObservationIgnored var monitorTask: Task<Void, Never>?
    @ObservationIgnored var operationTask: Task<Void, Never>?
    @ObservationIgnored var refreshTask: Task<Void, Never>?
    @ObservationIgnored var retrievalTask: Task<Void, Never>?
    @ObservationIgnored var lastAutomaticRetrieval = Date.distantPast
    /// Minimum gap between automatic retrieval attempts after one fails.
    @ObservationIgnored var automaticRetrievalInterval: TimeInterval = 60
    @ObservationIgnored var historyRunID: String?
    @ObservationIgnored var reconciled = false

    static let keptPodsKey = "ConceptStudio.keptPods"
    static let activePodKey = "ConceptStudio.activePod"
    static let pendingResultKey = "ConceptStudio.pendingResult"
    /// Set when the person chose "No saved storage", so later launches do not select a network volume.
    static let noSavedStorageKey = "ConceptStudio.noSavedStorage"

    init(
        demoMode: Bool,
        transport: any HTTPTransport = URLSessionTransport(timeout: 45),
        preferences: UserDefaults = .standard,
        readAgentToken: @escaping (String) throws -> String? = { try KeychainStore().read($0) },
        saveAgentToken: @escaping (String, String) throws -> Void = { token, account in
            try KeychainStore().save(token, account: account)
        },
        // KeychainStore.save with an empty value deletes the item (SecItemDelete).
        deleteAgentToken: @escaping (String) throws -> Void = { try KeychainStore().save("", account: $0) },
        downloader: any FileDownloading = URLSessionDownloader(),
        uploader: any FileUploading = URLSessionUploader(),
        keepAwake: SleepAssertion? = nil,
        modelTable: ModelTable = .shared
    ) {
        self.demoMode = demoMode
        self.modelTable = modelTable
        let start = modelTable.defaultRow
        trainer = start.trainer
        baseModel = start.modelRef
        steps = start.recipe.length
        rank = start.recipe.rank
        alpha = start.recipe.alpha
        batchSize = start.recipe.batchSize
        accumulation = start.recipe.gradientAccumulation
        learningRate = start.recipe.learningRate
        checkpointEvery = start.recipe.checkpoints.every
        checkpointRetention = start.recipe.checkpoints.keep
        checkpointPrecision = modelTable.checkpointPrecision(for: start)
        trainerSettings = TrainerSettings(start)
        trainingResolutions = start.resolution.defaults
        let reference = modelTable.models.lazy.compactMap(\.regularization).first
        regularizationImages = reference?.images ?? 1
        regularizationWeight = reference?.weight ?? 1
        regularizationAligned = reference
        regularizationOn = start.regularization?.defaultOn ?? false
        ownRegularizationImages = start.regularization?.mode == .folder
        profile = start.captions.imageProfile
        self.transport = transport
        self.preferences = preferences
        self.saveAgentToken = saveAgentToken
        self.readAgentToken = readAgentToken
        self.deleteAgentToken = deleteAgentToken
        self.downloader = downloader
        self.uploader = uploader
        sleepGuard = keepAwake ?? .system()
        captionModel = Self.rememberedCaptionModel(preferences) ?? captionModel
        if demoMode {
            provider = DemoGPUProvider()
            imageName = "demo"
            message = "Demo cloud GPUs are simulated. No account, network or money is used."
        }
    }

    func configure(runpodKey: String, hubToken: String, imageName: String, networkVolumeID: String? = nil) throws {
        guard !demoMode else { return }
        provider = runpodKey.isEmpty ? nil : RunPodProvider(key: runpodKey, transport: transport)
        self.hubToken = hubToken
        self.imageName = imageName
        if let networkVolumeID, !prefersNoSavedStorage { selectedVolume = networkVolumeID }
        if result == nil, let data = preferences.data(forKey: Self.pendingResultKey) {
            result = try? JSONDecoder().decode(TrainingResult.self, from: data)
            if let result, !RunArtifacts.validRunID(result.runID) { self.result = nil }
        }
        if keptPods.isEmpty, let data = preferences.data(forKey: Self.keptPodsKey) {
            keptPods = (try? JSONDecoder().decode([SavedPod].self, from: data)) ?? []
        }
        if pod == nil, let data = preferences.data(forKey: Self.activePodKey),
           let previous = try? JSONDecoder().decode(SavedPod.self, from: data) {
            saved = previous
            pod = previous.pod
            agentReadyAt = previous.pod.isRunning ? previous.agentReadyAt : nil
            budget = previous.budget
            if repeatSourceRunID.isEmpty, previous.pod.isRunning { trainer = previous.trainer }
            runID = previous.runID
            points = previous.points
            result = previous.result ?? result
            // The loaded project record owns history. The global pod record owns billing
            // and pending-output custody, including while Welcome or another project is open.
            generation = previous.generation
            idleMinutes = previous.idleMinutes
            keepsRunningWhenIdle = previous.keepsRunningWhenIdle
            watch()
        }
        if provider != nil, !reconciled {
            reconciled = true
            Task { await self.reconcile() }
        }
        if let pod, agent == nil {
            agentToken = try readAgentToken("pod.\(pod.id)") ?? ""
            connectAgent(pod)
        }
    }

    /// Reads a pod's agent token from the Keychain; an unreadable token leaves the provider-level
    /// budget and idle stop working.
    func restoreAgentToken(podID: String) {
        agentToken = (try? readAgentToken("pod.\(podID)")) ?? ""
    }

    func rent() async {
        await perform {
            guard !self.hasRunningPod else {
                throw StudioError
                    .message(
                        "Stop your running cloud GPU before renting another. Its files will be kept."
                    )
            }
            guard let provider = self.provider,
                  let offer = self.availableOffers.first(where: { $0.id == self.selectedGPU }),
                  self.selectedVolume.isEmpty || self.volumes.contains(where: { $0.id == self.selectedVolume }),
                  self.budget.isFinite, self.budget > 0 else {
                throw StudioError
                    .message(
                        "Choose an available cloud GPU and a positive budget."
                    )
            }
            let volume = self.volumes.first { $0.id == self.selectedVolume }
            let started = Date()
            self.message = "Reserving your cloud GPU…"
            await self.keepStoppedPod()
            self.agentToken = try Self.newAgentToken()
            // Credentials go to the account's secret store; the pod only ever sees placeholders.
            let credentials = try await self.storeCredentials(provider, cloud: offer.cloud)
            self.message = "Creating your cloud GPU and attaching its storage…"
            let created = try await self.createPod(provider, offer: offer, volume: volume, credentials: credentials)
            self.pod = created
            self.plan = nil
            self.storage = nil
            self.runID = ""
            self.trainingState = "Not started"
            self.points = []
            self.regularizationProgress = nil
            self.logs = ""
            self.elapsedCost = 0
            self.saved = SavedPod(
                pod: created, started: started, hourlyRate: max(created.cost, self.quotedHourlyRate),
                budget: self.budget, trainer: self.trainer, runID: "", runpodKey: self.runpodKeyFingerprint,
                idleMinutes: self.idleMinutes, keepsRunningWhenIdle: self.keepsRunningWhenIdle,
                volumeID: volume?.id ?? "pod:" + created.id,
                agentSecret: credentials.agentSecret, hubTokenOnPod: credentials.holdsHubToken
            )
            self.saved?.networkVolume = volume
            self.connectAgent(created)
            self.lastActivity = Date()
            self.watch()
            if !self.demoMode {
                self.persist()
                do {
                    try self.saveAgentToken(self.agentToken, "pod.\(created.id)")
                } catch {
                    try await provider.stop(id: created.id)
                    throw error
                }
            }
            self.message = "Your cloud GPU is rented and its control agent is connecting. "
                + "Its cost is visible below; you can stop it at any time."
        }
    }

    func persist() {
        captureRunProgress()
        if var saved, let pod {
            saved.pod = pod
            saved.trainer = trainer
            saved.runID = runID
            saved.idleMinutes = idleMinutes
            saved.keepsRunningWhenIdle = keepsRunningWhenIdle
            saved.agentReadyAt = agentReadyAt
            saved.points = points
            saved.result = result
            if let run = runHistory.first(where: { $0.runID == runID }) {
                saved.run = run
            } else if saved.run?.runID != runID { saved.run = nil }
            saved.generation = generation
            saved.storage = storage ?? saved.storage
            self.saved = saved
            if !demoMode, let data = try? JSONEncoder().encode(saved) {
                preferences.set(data, forKey: Self.activePodKey)
            }
        }
    }

    func perform(_ action: @escaping @MainActor () async throws -> Void) async {
        guard !isBusy, !isStopping else { return }
        operationRevision += 1
        isBusy = true
        let work = Task {
            defer {
                self.isBusy = false
                // Waiting on the app's own work (an upload, a download) is not idle time.
                self.noteActivity()
            }
            do {
                try await action()
            } catch is CancellationError {
                self.message = "Action cancelled. Check the cloud GPU status before closing."
            } catch {
                self.message = error.localizedDescription
                if !self.restartBlockedByHost { self.failure = self.message }
            }
        }
        operationTask = work
        await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
    }
}

extension GPUWorkspace {
    var resolution: Int {
        get { trainingResolutions.max() ?? modelTable.defaultRow.resolution.defaults.max() ?? 0 }
        set { trainingResolutions = [newValue] }
    }

    func watch() {
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                guard self?.hasRunningPod == true else { return }
                do {
                    try await Task.sleep(for: .seconds(self?.demoMode == true ? 1 : 5))
                } catch { return }
            }
        }
    }

    /// Waits until the service has exited. `whileWaiting` runs after each check that finds it still running.
    func waitForService(
        _ name: String, allowStopped: Bool = false, whileWaiting: (() async -> Void)? = nil
    ) async throws {
        guard let agent else { return }
        while true {
            try Task.checkCancellation()
            let services = try await agent.services()
            updateCaptionServerState(services)
            let service = services.first(where: { $0.name == name })
            if let service, !service.active {
                guard service.state == "exited" || (allowStopped && service.state == "stopped") else {
                    throw StudioError
                        .message("\(name) did not finish. Read its logs and retry after correcting the cause.")
                }
                return
            }
            await whileWaiting?()
            try await Task.sleep(for: .seconds(demoMode ? 0.1 : 2))
        }
    }

    func noteActivity() {
        lastActivity = Date()
    }

    var prefersNoSavedStorage: Bool {
        !demoMode && preferences.bool(forKey: Self.noSavedStorageKey)
    }

    /// The person's storage choice, remembered across launches like the Settings volume ID.
    func chooseStorage(_ volumeID: String) {
        selectedVolume = volumeID
        if !demoMode { preferences.set(volumeID.isEmpty, forKey: Self.noSavedStorageKey) }
        selectAvailableOffer()
    }

    /// The pod's control agent, as the provider exposes its port.
    var agentURL: URL? {
        guard let pod, let provider else { return nil }
        return provider.url(for: pod, port: PodPort.agent)
    }

    var tensorBoardURL: URL? {
        agentURL?.appendingPathComponent("tensorboard/")
    }

    var captionEndpoint: URL? {
        guard let pod, pod.isRunning, let provider else { return nil }
        return provider.url(for: pod, port: PodPort.inference).appendingPathComponent("v1")
    }

    var hasRunningPod: Bool {
        pod?.isRunning == true
    }

    var isTraining: Bool {
        ["running", "stuck"].contains(trainingState)
    }

    /// The network volume mounted at /workspace on the current pod.
    var currentVolumeID: String {
        if let volume = saved?.volumeID, !volume.isEmpty { return volume }
        if let pod { return pod.volumeID ?? "pod:" + pod.id }
        return selectedVolume
    }

    /// Whether the Mac is being kept awake for the running pod.
    var keepsMacAwake: Bool {
        sleepGuard.isHeld
    }
}
