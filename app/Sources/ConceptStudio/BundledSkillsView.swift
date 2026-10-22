import ConceptCore
import SwiftUI

/// A captioning skill that ships with the app, read for display: every directory beside the bundled default
/// skill that holds a SKILL.md, so a skill added to the bundle appears without code changes.
struct BundledSkill: Identifiable, Equatable {
    struct File: Identifiable, Equatable {
        let skill: String
        /// Relative to the skill directory, e.g. `references/profiles/flux-image.md`.
        let path: String
        let text: String
        var id: String {
            skill + "/" + path
        }
    }

    let name: String
    let files: [File]
    var id: String {
        name
    }

    /// The skills under `root` (the bundle's Skills folder by default), sorted by name.
    static func all(in root: URL = ConceptCore.defaultSkillURL.deletingLastPathComponent()) -> [BundledSkill] {
        let manager = FileManager.default
        let directories = (try? manager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        )) ?? []
        return directories
            .filter { manager.fileExists(atPath: $0.appendingPathComponent("SKILL.md").path(percentEncoded: false)) }
            .map { BundledSkill(name: $0.lastPathComponent, files: files(in: $0, skill: $0.lastPathComponent)) }
            .sorted { $0.name < $1.name }
    }

    /// SKILL.md first, then the readable text files below it, shallower folders before deeper ones.
    private static func files(in directory: URL, skill: String) -> [File] {
        let base = directory.standardizedFileURL.path(percentEncoded: false)
        let prefix = base.hasSuffix("/") ? base : base + "/"
        let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: .skipsHiddenFiles
        )
        var files: [File] = []
        while let url = enumerator?.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8)
            else { continue }
            let path = url.standardizedFileURL.path(percentEncoded: false)
            let relative = path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
            files.append(File(skill: skill, path: relative, text: text))
        }
        // SKILL.md has rank 0; every other file ranks by its depth, so references come before their profiles.
        func rank(_ file: File) -> Int {
            file.path == "SKILL.md" ? 0 : file.path.split(separator: "/").count
        }
        return files.sorted { rank($0) == rank($1) ? $0.path < $1.path : rank($0) < rank($1) }
    }
}

/// Read-only view of the captioning skills that ship with the app.
struct BundledSkillsView: View {
    let skills: [BundledSkill]
    @Environment(\.dismiss) private var dismiss
    @State private var selection: String?

    private var selectedFile: BundledSkill.File? {
        skills.lazy.flatMap(\.files).first { $0.id == selection }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Built-in captioning skills").font(.title3.weight(.semibold))
            Text("These caption-writing instructions ship with the app. They are shown here to read, not to edit.")
                .font(.callout).foregroundStyle(StudioStyle.supportingText)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 0) {
                List(selection: $selection) {
                    ForEach(skills) { skill in
                        Section(skill.name) {
                            ForEach(skill.files) { file in
                                Text(file.path).tag(file.id)
                            }
                        }
                    }
                }
                .frame(width: 260)
                Divider()
                ScrollView {
                    Text(selectedFile?.text ?? "Choose a file to read it.")
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                }
            }
            .frame(minHeight: 420)
            .border(.separator)
            if skills.isEmpty {
                Text("No built-in skills were found in this copy of the app.")
                    .font(.callout).foregroundStyle(StudioStyle.supportingText)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 820, minHeight: 560)
        .onAppear {
            if selection == nil { selection = skills.first?.files.first?.id }
        }
    }
}
