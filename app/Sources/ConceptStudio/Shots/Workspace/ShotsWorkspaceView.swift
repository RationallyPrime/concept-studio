import PrevisCore
import SwiftUI

struct ShotsWorkspaceView: View {
    @Bindable var session: StudioSession

    var body: some View {
        if let store = session.shots {
            ShotsWorkspaceContent(store: store, projectDirectory: session.project?.directory, session: session)
        } else {
            ContentUnavailableView(
                "Shots is unavailable", systemImage: "film",
                description: Text("Close and reopen the project to try again.")
            )
        }
    }
}

private struct ShotsWorkspaceContent: View {
    @Bindable var store: ShotsStore
    let projectDirectory: URL?
    let session: StudioSession
    @State private var showsShotCamera = false
    /// The scene view and the shot camera next to each other: block in one and see the plate in the other.
    @State private var sideBySide = false
    @State private var viewportSession = ViewportLiveSession()
    @State private var preserveViewportFocusOnToggle = false

    var body: some View {
        VSplitView {
            HSplitView {
                // The split view starts its panes at equal widths up to their maximums, so these caps leave the
                // viewport the most room: about 330 points at the 980-point minimum window.
                sceneColumn.frame(minWidth: 160, idealWidth: 180, maxWidth: 200)
                viewport.frame(minWidth: 260, maxWidth: .infinity, minHeight: 220)
                inspector.frame(minWidth: 200, idealWidth: 220, maxWidth: 230)
            }
            // Capped so the panes above keep most of the height; lanes scroll beyond four people.
            ShotsTimelineView(store: store).frame(minHeight: 150, idealHeight: 210, maxHeight: 250)
        }
        .background(ShotsUndoBridge(store: store))
        .onKeyPress(keys: [.space]) { press in
            guard press.modifiers.isDisjoint(with: [.command, .control, .option, .shift]),
                  !ShotsTimelineView.editingText,
                  store.currentShot != nil else { return .ignored }
            store.toggleShotsPlayback()
            return .handled
        }
    }

    private var sceneColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            ShotsSceneList(store: store, projectDirectory: projectDirectory, session: session)
            Divider()
            ShotsAssetLibrary(store: store)
        }
    }

    private var viewport: some View {
        VStack(spacing: 0) {
            Picker("View", selection: Binding(
                get: { sideBySide ? 2 : showsShotCamera ? 1 : 0 },
                set: { choice in
                    viewportSession.cancelActiveHandleDrag(in: store)
                    sideBySide = choice == 2
                    showsShotCamera = choice == 1
                }
            )) {
                Text("Scene view").tag(0)
                Text("Shot camera").tag(1)
                Text("Side by side").tag(2)
            }
            .pickerStyle(.segmented).padding(12)
            .help("Scene view: move freely around the stage. Shot camera: what the shot sees, over its plate. "
                + "Side by side: both at once, so the plate follows while you block.")
            if sideBySide {
                HStack(spacing: 8) {
                    ShotsViewport(
                        store: store,
                        externalSession: viewportSession,
                        onToggleLookThrough: toggleLookThroughFromViewport,
                        claimFocusOnAppear: preserveViewportFocusOnToggle,
                        onClaimedFocus: { preserveViewportFocusOnToggle = false }
                    )
                    ShotCameraView(store: store)
                }
            } else if showsShotCamera {
                ShotCameraView(
                    store: store,
                    externalSession: viewportSession,
                    onToggleLookThrough: toggleLookThroughFromViewport,
                    claimFocusOnAppear: preserveViewportFocusOnToggle,
                    onClaimedFocus: { preserveViewportFocusOnToggle = false }
                )
            } else {
                ShotsViewport(
                    store: store,
                    externalSession: viewportSession,
                    onToggleLookThrough: toggleLookThroughFromViewport,
                    claimFocusOnAppear: preserveViewportFocusOnToggle,
                    onClaimedFocus: { preserveViewportFocusOnToggle = false }
                )
            }
        }
    }

    private func toggleLookThroughFromViewport() {
        viewportSession.cancelActiveHandleDrag(in: store)
        preserveViewportFocusOnToggle = true
        // From side by side, the key goes to the shot camera alone.
        showsShotCamera = sideBySide ? true : !showsShotCamera
        sideBySide = false
    }

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Inspector").font(.headline).accessibilityAddTraits(.isHeader)
                if store.isReadOnly {
                    Label(ShotsEditingError.readOnly.localizedDescription, systemImage: "lock")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                ShotsInspectorView(store: store, session: session)
                Divider()
                ShotsExportView(
                    store: store, projectDirectory: projectDirectory,
                    folders: ShotsExportFolders(preferences: session.preferences)
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Shot inspector")
    }
}
