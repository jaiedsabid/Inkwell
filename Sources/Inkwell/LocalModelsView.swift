import SwiftUI

/// The "Local model" part of Settings → AI Engine: this Mac's specs, the model cards, and adding any GGUF from Hugging Face.
struct LocalModelsSection: View {
    @ObservedObject var store = ModelStore.shared
    @ObservedObject var settings = AppSettings.shared
    @Loc private var hfInput = ""
    @Loc private var hfResults: [LocalModel] = []
    @Loc private var hfSearching = false
    @Loc private var hfError: String?
    @Loc private var confirmDelete: LocalModel?

    private let recommended = MacInfo.recommendedID()
    private let ram = MacInfo.memoryGB

    var body: some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: "laptopcomputer").font(.title3).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Your Mac has \(ram) GB of memory")
                    Text(MacInfo.chip).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            if !MacInfo.isAppleSilicon {
                Label("Local models run slowly on Intel Macs. Cloud AI will feel much faster.", systemImage: "tortoise")
                    .font(.callout).foregroundStyle(.orange)
            }
        } header: {
            Text("Local model")
        } footer: {
            Text("Models download once from Hugging Face and then run entirely on your Mac. Nothing you write leaves it. Memory is freed after 15 minutes without use.")
        }

        Section("Models") {
            ForEach(LocalModel.catalog) { m in card(m) }
        }

        Section {
            ForEach(settings.customModels) { m in card(m) }
            HStack {
                TextField("", text: $hfInput, prompt: Text("Hugging Face repo, like bartowski/Qwen2.5-7B-Instruct-GGUF"))
                    .textFieldStyle(.roundedBorder).labelsHidden()
                    .onSubmit(search)
                Button("Find", action: search).disabled(hfInput.trimmingCharacters(in: .whitespaces).isEmpty || hfSearching)
                if hfSearching { ProgressView().controlSize(.small) }
            }
            if let hfError { Text(hfError).font(.caption).foregroundStyle(.red) }
            ForEach(hfResults.prefix(12)) { m in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(m.file).font(.callout).lineLimit(1).truncationMode(.middle)
                        Text("\(m.sizeText) · \(m.tagline)").font(.caption).foregroundStyle(m.minRAM <= ram ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                    }
                    Spacer()
                    Button("Add") { add(m) }
                        .disabled(settings.customModels.contains { $0.id == m.id })
                }
            }
        } header: {
            Text("Add from Hugging Face")
        } footer: {
            Text("Any GGUF instruct model works. Q4_K_M files are a good balance of size and quality.")
        }
        .confirmationDialog("Delete \(confirmDelete?.name ?? "")?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Delete", role: .destructive) {
                if let m = confirmDelete {
                    store.delete(m)
                    if m.isCustom { settings.customModels.removeAll { $0.id == m.id } }
                }
                confirmDelete = nil
            }
        } message: {
            Text("Frees \(confirmDelete?.sizeText ?? ""). You can download it again later.")
        }
    }

    @ViewBuilder
    private func card(_ m: LocalModel) -> some View {
        let installed = store.installed.contains(m.id)
        let inUse = installed && settings.localModelID == m.id
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(m.name).fontWeight(.semibold)
                if m.id == recommended { Badge(text: "Recommended for your Mac", color: Theme.accent) }
                else if m.minRAM > ram { Badge(text: "Needs \(m.minRAM) GB+", color: .orange) }
                Spacer()
                action(m, installed: installed, inUse: inUse)
            }
            Text("\(m.vendor) · \(m.license)\(m.tagline.isEmpty || m.isCustom ? "" : " · " + m.tagline)")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 16) {
                if m.accuracy > 0 { Meter(label: "Accuracy", value: m.accuracy) }
                Meter(label: "Speed", value: m.speed)
                Spacer()
                Text("\(m.sizeText) download · about \(m.memoryText) in use").font(.caption).foregroundStyle(.tertiary)
            }
            if let p = store.progress[m.id] {
                VStack(alignment: .leading, spacing: 3) {
                    ProgressView(value: p).tint(Theme.accent)
                    Text(p >= 1 ? "Checking the file…" : "\(Int(p * 100))% of \(m.sizeText)").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                }
            } else if let err = store.errors[m.id] {
                Text(err).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func action(_ m: LocalModel, installed: Bool, inUse: Bool) -> some View {
        if store.progress[m.id] != nil {
            Button("Cancel") { store.cancel(m) }.controlSize(.small)
        } else if inUse {
            Label("In use", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
            deleteButton(m)
        } else if installed {
            Button("Use") { settings.localModelID = m.id; Coordinator.shared.checker.invalidate() }.controlSize(.small)
            deleteButton(m)
        } else {
            let resumed = store.partialBytes(m) > 0
            Button(resumed ? "Resume" : "Download") { store.download(m) }.controlSize(.small)
            if m.isCustom { deleteButton(m) }
        }
    }

    private func deleteButton(_ m: LocalModel) -> some View {
        Button { confirmDelete = m } label: { Image(systemName: "trash") }
            .buttonStyle(.borderless).foregroundStyle(.secondary).help("Delete this model")
    }

    private func search() {
        hfError = nil
        hfSearching = true
        let input = hfInput
        Task {
            do {
                let found = try await ModelStore.findGGUF(in: input)
                hfResults = found
                if found.isEmpty { hfError = "No GGUF files in that repo." }
            } catch {
                hfResults = []
                hfError = "Couldn't find that repo. Use the form owner/name, like bartowski/Qwen2.5-7B-Instruct-GGUF."
            }
            hfSearching = false
        }
    }

    private func add(_ m: LocalModel) {
        settings.customModels.append(m)
        store.refresh()
        hfResults = []
        hfInput = ""
        store.download(m)
    }
}

struct Badge: View {
    var text: String
    var color: Color
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.14), in: Capsule())
    }
}

struct Meter: View {
    var label: String
    var value: Int
    var body: some View {
        HStack(spacing: 5) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 2) {
                ForEach(1...3, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(i <= value ? Theme.accent : Color.secondary.opacity(0.25))
                        .frame(width: 12, height: 5)
                }
            }
        }
    }
}
