import SwiftUI
import AppKit

// MARK: - TemplateField

/// One placeholder slot inside a mail-merge template.
///
/// `id` is the raw placeholder name (e.g. `"name"` from `[[name]]`) which we
/// also use as the dictionary key when calling back to the host. `label` is the
/// surface form (case preserved) we render in the UI. `value` is the live
/// input. `suggestions` is a pre-populated history list supplied by the caller
/// — this view itself does not touch `FieldHistoryStore`.
public struct TemplateField: Identifiable, Hashable {
    public let id: String
    public let label: String
    public var value: String
    public var suggestions: [String]

    public init(id: String,
                label: String,
                value: String = "",
                suggestions: [String] = []) {
        self.id = id
        self.label = label
        self.value = value
        self.suggestions = suggestions
    }
}

// MARK: - TemplateFieldParser

/// Extracts and re-injects `[[name]]` mail-merge placeholders.
///
/// The grammar is intentionally narrow — identifiers must start with a letter
/// or underscore — so we don't accidentally swallow markdown `[[wiki]]` links
/// or other bracket-heavy content.
enum TemplateFieldParser {
    private static let pattern: NSRegularExpression = {
        // [[ <ws> identifier <ws> ]]
        return try! NSRegularExpression(
            pattern: #"\[\[\s*([a-zA-Z_][a-zA-Z0-9_]*)\s*\]\]"#,
            options: []
        )
    }()

    /// Extracts every `[[name]]` in source order, dedupes by identifier, and
    /// returns one `TemplateField` per unique placeholder.
    static func parse(_ template: String) -> [TemplateField] {
        let ns = template as NSString
        let matches = pattern.matches(in: template, range: NSRange(location: 0, length: ns.length))

        var seen = Set<String>()
        var fields: [TemplateField] = []
        for m in matches {
            let nameRange = m.range(at: 1)
            guard nameRange.location != NSNotFound else { continue }
            let name = ns.substring(with: nameRange)
            // Dedupe by identifier so `[[name]] ... [[name]]` collapses to one
            // input. We keep the *first* occurrence's casing for the label.
            if seen.insert(name).inserted {
                fields.append(TemplateField(id: name, label: name))
            }
        }
        return fields
    }

    /// Substitutes every `[[name]]` occurrence (including repeats) with the
    /// matching value. Unknown placeholders are left untouched so the user can
    /// see what's still missing in the preview.
    static func apply(_ template: String, values: [String: String]) -> String {
        let ns = template as NSString
        let matches = pattern.matches(in: template, range: NSRange(location: 0, length: ns.length))

        // Walk back-to-front so NSRange offsets stay valid as we mutate.
        var output = template
        for m in matches.reversed() {
            let nameRange = m.range(at: 1)
            guard nameRange.location != NSNotFound else { continue }
            let name = (template as NSString).substring(with: nameRange)
            guard let replacement = values[name] else { continue }
            output = (output as NSString).replacingCharacters(in: m.range, with: replacement)
        }
        return output
    }
}

// MARK: - TemplateFieldDialog

/// Modal-ish input sheet shown right before a templated clip is pasted.
///
/// The view owns its editing state — we copy the caller's fields into a local
/// `@State` array so SwiftUI can drive per-row bindings, then hand the result
/// back to the host via `onConfirm`.
@MainActor
struct TemplateFieldDialog: View {
    let template: String
    let fields: [TemplateField]
    let onCancel: () -> Void
    let onConfirm: (_ filledTemplate: String, _ values: [String: String]) -> Void

    @State private var editing: [TemplateField]
    @FocusState private var focusedField: String?

    init(template: String,
         fields: [TemplateField],
         onCancel: @escaping () -> Void,
         onConfirm: @escaping (_ filledTemplate: String, _ values: [String: String]) -> Void) {
        self.template = template
        self.fields = fields
        self.onCancel = onCancel
        self.onConfirm = onConfirm
        _editing = State(initialValue: fields)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            Divider().opacity(0.5)

            fieldList

            Divider().opacity(0.5)

            previewBlock

            footer
        }
        .padding(18)
        .frame(width: 480)
        .frame(minHeight: 280)
        .background(
            VisualEffectBackground()
                .clipShape(RoundedRectangle(cornerRadius: PastyTheme.cornerRadius, style: .continuous))
        )
        .overlay(
            RoundedRectangle(cornerRadius: PastyTheme.cornerRadius, style: .continuous)
                .stroke(Color.primary.opacity(PastyTheme.strokeOpacity), lineWidth: 1)
        )
        .onAppear { focusFirstEmpty() }
        .onExitCommand(perform: onCancel)
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 8) {
            Text("\u{2728}")
                .font(.system(size: 16))
            Text("テンプレートの値を入力")
                .font(PastyTheme.titleFont)
                .foregroundColor(.primary)
            Spacer()
        }
    }

    private var fieldList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(editing.enumerated()), id: \.element.id) { index, field in
                fieldRow(index: index, field: field)
            }
        }
    }

    @ViewBuilder
    private func fieldRow(index: Int, field: TemplateField) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text("\(field.label):")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 80, alignment: .trailing)
                .foregroundColor(.secondary)

            TextField("", text: Binding(
                get: { editing[safe: index]?.value ?? "" },
                set: { newValue in
                    guard editing.indices.contains(index) else { return }
                    editing[index].value = newValue
                }
            ))
            .textFieldStyle(.roundedBorder)
            .focused($focusedField, equals: field.id)
            .onSubmit { handleReturn() }

            if !field.suggestions.isEmpty {
                suggestionMenu(for: index, suggestions: field.suggestions)
            }
        }
    }

    @ViewBuilder
    private func suggestionMenu(for index: Int, suggestions: [String]) -> some View {
        Menu {
            // History menu — cap at 5 per spec so we don't blow up the popup.
            ForEach(Array(suggestions.prefix(5).enumerated()), id: \.offset) { _, suggestion in
                Button(suggestion) {
                    guard editing.indices.contains(index) else { return }
                    editing[index].value = suggestion
                }
            }
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var previewBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("プレビュー:")
                .font(PastyTheme.subtitleFont)
                .foregroundColor(.secondary)

            ScrollView {
                Text(previewText)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(minHeight: 64, maxHeight: 140)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.primary.opacity(PastyTheme.strokeOpacity), lineWidth: 1)
            )
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()
            Button("キャンセル", action: onCancel)
                .keyboardShortcut(.cancelAction)

            Button("貼付", action: handleConfirm)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!allFieldsFilled)
        }
    }

    // MARK: Derived

    private var valuesDict: [String: String] {
        var out: [String: String] = [:]
        for field in editing { out[field.id] = field.value }
        return out
    }

    /// Live preview: apply user values, then run through `SnippetEngine` so
    /// `{{date}}` and friends also render in their final form.
    private var previewText: String {
        let withFields = TemplateFieldParser.apply(template, values: valuesDict)
        let expanded = SnippetEngine.expand(withFields, customVariables: [:])
        return expanded.text
    }

    private var allFieldsFilled: Bool {
        editing.allSatisfy { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private var firstEmptyFieldID: String? {
        editing.first(where: { $0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?.id
    }

    // MARK: Actions

    private func focusFirstEmpty() {
        // Slight delay so the focus binding latches after the window settles.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            focusedField = firstEmptyFieldID ?? editing.first?.id
        }
    }

    /// Return key behavior:
    /// - If everything is filled → confirm.
    /// - Otherwise jump to the next empty field so the user can keep typing.
    private func handleReturn() {
        if allFieldsFilled {
            handleConfirm()
        } else if let next = firstEmptyFieldID {
            focusedField = next
        }
    }

    private func handleConfirm() {
        guard allFieldsFilled else {
            if let next = firstEmptyFieldID { focusedField = next }
            return
        }
        let values = valuesDict
        let filled = TemplateFieldParser.apply(template, values: values)
        onConfirm(filled, values)
    }
}

// MARK: - Array safe subscript

private extension Array {
    /// Bounds-safe read — avoids crashes if SwiftUI re-renders mid-edit while
    /// `editing` is being mutated from a binding closure.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
