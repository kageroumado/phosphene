import SwiftUI

struct ConversionToolView: View {
    let pairRequest: PairConverterRequest
    @Environment(\.locale) private var locale
    @State private var model: ConversionToolModel
    @State private var drafts: [NumberField: String] = [:]
    @State private var librarySlot: SourceSlot?
    @FocusState private var focusedNumber: NumberField?

    init(mode: ConversionMode, pairRequest: PairConverterRequest = .blank) {
        self.pairRequest = pairRequest
        _model = State(initialValue: ConversionToolModel(mode: mode))
    }

    private var isPair: Bool {
        model.mode == .pair
    }
    private var isBusy: Bool {
        model.isLoading || model.isRunning
    }
    private var invalidFields: Set<NumberField> {
        Set(drafts.compactMap { field, text in field.number(from: text, locale: locale) == nil ? field : nil })
    }

    private var canStart: Bool {
        !isBusy && invalidFields.isEmpty && model.light != nil && (!isPair || model.dark != nil) &&
            model.validationMessage == nil
    }

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            Form {
                Section(isPair ? "Sources" : "Source") {
                    sourceRow(.light, source: model.light, assumeSDR: $model.assumeLightSDR)
                    if isPair {
                        sourceRow(.dark, source: model.dark, assumeSDR: $model.assumeDarkSDR)
                    }
                }

                Section("Output") {
                    LabeledContent("Preset") {
                        Menu("Apply Preset") {
                            ForEach(OptimizationPreset.allCases) { preset in
                                Button(preset.title) {
                                    focusedNumber = nil
                                    for field in [NumberField.width, .height, .fps, .bitrate] {
                                        drafts[field] = nil
                                    }
                                    model.applyPreset(preset)
                                }
                            }
                        }
                    }
                    LabeledContent("Resolution") {
                        HStack(spacing: 6) {
                            numberField(.width)
                            Text("×").accessibilityHidden(true)
                            numberField(.height)
                            Text("px").foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent("Frame Rate") { numberWithUnit(.fps, unit: "fps") }
                    LabeledContent("Bitrate") { numberWithUnit(.bitrate, unit: "Mbps") }

                    if model.needsFraming, invalidFields.isDisjoint(with: [.width, .height]) {
                        Picker("Framing", selection: $model.settings.framing) {
                            ForEach(ConversionFraming.allCases) { option in
                                Text(option.title).tag(option)
                            }
                        }
                    }
                    Picker("Dynamic Range", selection: $model.settings.range) {
                        ForEach(ConversionRange.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    Picker("Codec", selection: $model.settings.codec) {
                        ForEach(ConversionCodec.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .disabled(model.settings.range != .sdr)
                    .help("HDR output requires 10-bit HEVC.")
                    Text("The output contains video only.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Section("Destination") {
                    if isPair {
                        LabeledContent("Save To", value: "Library")
                    } else {
                        Picker("Save To", selection: $model.addToLibrary) {
                            Text("Save File").tag(false)
                            Text("Add to Library").tag(true)
                        }
                        .pickerStyle(.segmented)
                    }
                    TextField("Name", text: $model.name)
                }
            }
            .formStyle(.grouped)
            .disabled(isBusy)

            Divider()
            footer
        }
        .frame(minWidth: 540, minHeight: 480)
        .onChange(of: focusedNumber) { previous, _ in
            if let previous, let text = drafts[previous],
               previous.number(from: text, locale: locale) != nil {
                drafts[previous] = nil
            }
        }
        .sheet(item: $librarySlot) { slot in
            ConversionLibraryPicker { entry in
                model.selectSource(entry, dark: slot == .dark)
            }
        }
        .task(id: pairRequest) { model.loadPair(pairRequest) }
        .onDisappear {
            if isBusy {
                model.cancel()
            }
        }
    }

    private func sourceRow(_ slot: SourceSlot, source: ConversionSource?, assumeSDR: Binding<Bool>) -> some View {
        let title = slot.title(isPair: isPair)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                if isPair {
                    Text(title).fontWeight(.medium)
                }
                if let source {
                    Text(source.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(source.name)
                } else {
                    Text("No Video Selected").foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("Choose File…") { model.chooseFile(dark: slot == .dark) }
                    .accessibilityLabel("Choose file for \(title)")
                Button("From Library…") { librarySlot = slot }
                    .accessibilityLabel("Choose from the library for \(title)")
            }

            if let source {
                let precision = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0 ... 2))
                Text("\(source.width) × \(source.height) px · \(source.fps, format: precision) fps · \(source.duration, format: precision) s")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)

                if source.range == nil {
                    Toggle("Interpret as SDR (Rec. 709)", isOn: assumeSDR)
                }
                sourceTreatment(source, assumeSDR: assumeSDR.wrappedValue)
            }
        }
    }

    private func sourceTreatment(_ source: ConversionSource, assumeSDR: Bool) -> some View {
        let assumed = source.range == nil && assumeSDR
        let range = source.range ?? (assumed ? .sdr : nil)
        let sourceTitle = assumed ? String(localized: "SDR (interpreted as Rec. 709)") : (range?.title ?? String(localized: "Unknown"))
        let target = model.settings.range
        let duration = model.settings.duration

        return VStack(alignment: .leading, spacing: 3) {
            Text("\(sourceTitle) → \(target.title)")
                .accessibilityLabel("Dynamic range from \(sourceTitle) to \(target.title)")
            if let range, range != .sdr, target == .sdr {
                Text("HDR highlights will be tone-mapped to SDR.")
            } else if range == .sdr, target != .sdr {
                Text("Converting SDR to HDR cannot recover highlight detail.")
            }
            if isPair, model.light != nil, model.dark != nil, source.duration - duration >= 0.005 {
                Text("Trim the video to \(duration, format: .number.precision(.fractionLength(0 ... 2))) s.")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !isBusy {
                if !invalidFields.isEmpty {
                    Text("Enter positive output values. Width and height must be whole numbers.")
                        .foregroundStyle(.secondary)
                } else if let validation = model.validationMessage, model.errorMessage == nil {
                    Text(validation).foregroundStyle(.secondary)
                } else if let completion = model.completionMessage {
                    Label(completion, systemImage: "checkmark.circle")
                }
            }

            if model.isRunning {
                ProgressView(value: model.progress) {
                    Text("Converting…")
                } currentValueLabel: {
                    Text(model.progress, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                }
            }

            HStack {
                if model.isLoading, !model.isRunning {
                    ProgressView().controlSize(.small)
                    Text("Preparing…").foregroundStyle(.secondary)
                }
                Spacer()
                if model.isRunning {
                    Button("Cancel", role: .cancel) { model.cancel() }
                        .keyboardShortcut(.cancelAction)
                } else {
                    Button(isPair ? "Create Pair" : "Convert") { start() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canStart)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func numberWithUnit(_ field: NumberField, unit: LocalizedStringKey) -> some View {
        HStack(spacing: 6) {
            numberField(field)
            Text(unit).foregroundStyle(.secondary)
        }
    }

    private func numberField(_ field: NumberField) -> some View {
        let text = Binding(
            get: { drafts[field] ?? field.formatted(in: model.settings, locale: locale) },
            set: { value in
                drafts[field] = value
                applyNumber(value, to: field)
            },
        )
        return TextField(field.title, text: text)
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .frame(width: 94)
            .focused($focusedNumber, equals: field)
    }

    private func applyNumber(_ text: String, to field: NumberField) {
        guard let number = field.number(from: text, locale: locale) else { return }
        switch number {
        case let .integer(path, value): model.settings[keyPath: path] = value
        case let .decimal(path, value): model.settings[keyPath: path] = value
        }
    }

    private func start() {
        guard canStart else { return }
        // A source load or preset can update the model while a field has a draft.
        for (field, text) in drafts {
            applyNumber(text, to: field)
        }
        guard model.validationMessage == nil else { return }
        focusedNumber = nil
        model.start()
    }
}

private extension ConversionToolView {
    enum SourceSlot: String, Identifiable {
        case light
        case dark

        var id: Self {
            self
        }

        func title(isPair: Bool) -> String {
            if !isPair {
                return String(localized: "Source Video")
            }
            return self == .dark ? String(localized: "Dark Video") : String(localized: "Light Video")
        }
    }

    enum NumberField: Hashable {
        case width
        case height
        case fps
        case bitrate

        enum Value {
            case integer(WritableKeyPath<ConversionSettings, Int>, Int)
            case decimal(WritableKeyPath<ConversionSettings, Double>, Double)
        }

        var title: LocalizedStringKey {
            switch self {
            case .width: "Width"
            case .height: "Height"
            case .fps: "Frame Rate"
            case .bitrate: "Bitrate"
            }
        }

        private var integerPath: WritableKeyPath<ConversionSettings, Int>? {
            switch self {
            case .width: \.width
            case .height: \.height
            default: nil
            }
        }

        private var decimalPath: WritableKeyPath<ConversionSettings, Double>? {
            switch self {
            case .fps: \.fps
            case .bitrate: \.bitrateMbps
            default: nil
            }
        }

        func formatted(in settings: ConversionSettings, locale: Locale) -> String {
            if let integerPath {
                return settings[keyPath: integerPath].formatted(.number.grouping(.never).locale(locale))
            }
            guard let decimalPath else { return "" }
            return settings[keyPath: decimalPath].formatted(.number.grouping(.never).precision(.fractionLength(0 ... 8)).locale(locale))
        }

        func number(from text: String, locale: Locale) -> Value? {
            let parts = text.trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: locale.decimalSeparator ?? ".")
            guard parts.count == 1 || (integerPath == nil && parts.count == 2 && !parts[1].isEmpty) else { return nil }
            let digits = parts.joined()
            guard !digits.isEmpty, digits.unicodeScalars.allSatisfy({ $0.properties.generalCategory == .decimalNumber }) else { return nil }
            let spelling = parts.map { $0.compactMap(\.wholeNumberValue).map(String.init).joined() }.joined(separator: ".")
            if let integerPath, let value = Int(spelling), value > 0 {
                return .integer(integerPath, value)
            }
            if let decimalPath, let value = Double(spelling), value.isFinite, value > 0 {
                return .decimal(decimalPath, value)
            }
            return nil
        }
    }
}

private struct ConversionLibraryPicker: View {
    let choose: (VideoDeploymentService.EntryInfo) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var entries: [VideoDeploymentService.EntryInfo] = []
    @State private var pairRoles: [String: Bool] = [:]
    @State private var selectedID: String?
    @State private var search = ""
    @State private var isLoading = true

    private var visibleEntries: [VideoDeploymentService.EntryInfo] {
        guard !search.isEmpty else { return entries }
        return entries.filter { $0.name.localizedStandardContains(search) || $0.filename.localizedStandardContains(search) }
    }

    var body: some View {
        let entries = visibleEntries
        let selected = entries.first { $0.id == selectedID }
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose a Library Video").font(.headline)
            TextField("Search Library", text: $search)
                .disabled(isLoading || self.entries.isEmpty)

            List(entries, id: \.id, selection: $selectedID) { entry in
                HStack {
                    Text(entry.name).lineLimit(1)
                    Spacer()
                    if let dark = pairRoles[entry.id] {
                        Text(dark ? "Dark Member" : "Light Member")
                            .foregroundStyle(.secondary)
                    }
                }
                .tag(entry.id)
            }
            .overlay {
                if isLoading {
                    ProgressView().controlSize(.small)
                } else if self.entries.isEmpty {
                    ContentUnavailableView("No Videos in Library", systemImage: "film")
                } else if entries.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Choose") {
                    guard let selected else { return }
                    choose(selected)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected == nil)
            }
        }
        .padding(20)
        .frame(width: 460, height: 360)
        .task {
            self.entries = VideoDeploymentService.listEntries()
            for pair in (try? AppearancePair.read(in: VideoDeploymentService.videosFolderURL)) ?? [] where pair.deletionPending != true {
                pairRoles[pair.light] = false
                pairRoles[pair.dark] = true
            }
            isLoading = false
        }
    }
}
