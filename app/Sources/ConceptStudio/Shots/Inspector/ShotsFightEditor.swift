import PrevisCore
import SwiftUI

struct ShotsFightEditor: View {
    let store: ShotsStore
    let shot: Shot
    @State private var preset = FightBlocking.swordExchange
    @State private var firstActor = ""
    @State private var secondActor = ""
    @State private var duration = 1.0

    var body: some View {
        let people = store.currentScene?.entities.filter {
            $0.formation == nil && store.catalog.asset($0.assetID)?.rig == .person
        } ?? []
        if people.count >= 2 {
            DisclosureGroup("Fight blocking") {
                VStack(alignment: .leading, spacing: 6) {
                    Picker("Exchange", selection: $preset) {
                        ForEach(FightBlocking.allCases, id: \.self) { item in
                            Text(item.name).tag(item)
                        }
                    }
                    person("First performer", selection: $firstActor, people: people)
                    person("Second performer", selection: $secondActor, people: people)
                    ShotsNumberField(
                        title: "Duration (s)", value: $duration,
                        range: 0.084 ... FrameGrid.time(ofFrame: max(3, shot.frameCount))
                    )
                    let last = store.playhead + FrameGrid.frame(atTime: duration)
                    Button("Add exchange at playhead") {
                        store.run(.stageFight(
                            shot.id, preset, actors: [firstActor, secondActor], first: store.playhead, last: last
                        ))
                    }
                    .disabled(firstActor.isEmpty || secondActor.isEmpty || firstActor == secondActor
                        || last >= shot.frameCount)
                    .help("Replace both performers’ marks within the exchange interval.")
                }
                .padding(.vertical, 6)
            }
        }
    }

    private func person(_ title: String, selection: Binding<String>, people: [PrevisEntity]) -> some View {
        Picker(title, selection: selection) {
            Text("Choose person").tag("")
            ForEach(people) { person in
                Text(person.name).tag(person.id)
            }
        }
    }
}
