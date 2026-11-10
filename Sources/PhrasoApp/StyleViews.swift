import AppKit
import PhrasoKit
import SwiftUI

private let sampleStep = RenderStep(words: ["ALL", "WITHOUT", "READING"], highlight: 1, first: 0, last: 1)

/// A thumbnail of a style: the sample card on dark grey, a 32:9 band drawn at half the
/// style's scale so the look reads at grid size.
func thumbnail(_ style: Style) -> CGImage? {
    var s = style
    s.position = [0, 0]
    s.size = min(s.size * 1.6, 170)
    let r = Renderer(style: s, width: 1920, height: 540)
    let ctx = r.makeContext()
    ctx.setFillColor(CGColor(gray: 0.28, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: r.width, height: r.height))
    guard let card = try? r.image(sampleStep) else { return nil }
    ctx.draw(card, in: CGRect(x: 0, y: 0, width: r.width, height: r.height))
    return ctx.makeImage()
}

/// The measurements of Keynote's Format sidebar, read from its inspector nibs
/// (TMATextInspector, TMAPositionInspector, TMARotateInspector, TMAShadowDrop…,
/// TMAStrokeBasic…, TMATextSpacingInspector). Every pane here is laid out on them.
enum Pane {
    static let width: CGFloat = 270        // a pane
    static let margin: CGFloat = 16        // leading and trailing
    static let content: CGFloat = 238      // width - 2 * margin
    static let control: CGFloat = 24       // the height of a control row
    static let rowGap: CGFloat = 9         // between control rows
    static let titleTop: CGFloat = 13      // pane top to its title
    static let titleBottom: CGFloat = 12   // title to the first control
    static let bottom: CGFloat = 13        // last control to the pane's end
    static let field: CGFloat = 50         // a value field
    static let wideField: CGFloat = 65     // X, Y, Angle
    static let stepperGap: CGFloat = 3     // field to its stepper
    static let well = CGSize(width: 66, height: 23)
    static let slider: CGFloat = 151       // a slider beside a field and stepper
    static let label = Font.system(size: 13)
    static let title = Font.system(size: 13, weight: .semibold)
    static let caption = Font.system(size: 11)
    /// The sidebar's grey, under white fields and wells.
    static let background = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 0.925, alpha: 1)
    })
    /// The width a scroll bar takes when the system always shows them (none when they overlay).
    @MainActor static var scroller: CGFloat {
        NSScroller.preferredScrollerStyle == .legacy ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
    }
}

/// The presets, as thumbnails. Click one to take its style.
struct StyleGrid: View {
    @EnvironmentObject var doc: Document
    @State private var thumbs: [String: CGImage] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("Styles").font(Pane.title)
                Spacer()
                Button("Presets Folder") { doc.revealPresets() }.controlSize(.small)
                Button { doc.reloadPresets(); thumbs = [:] } label: { Image(systemName: "arrow.clockwise") }.controlSize(.small)
            }
            .padding(.horizontal, Pane.margin).padding(.top, Pane.titleTop).padding(.bottom, Pane.titleBottom)
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(doc.presets, id: \.stem) { p in
                        VStack(spacing: 3) {
                            ZStack {
                                Color(white: 0.28)
                                if let img = thumbs[p.stem] {
                                    Image(decorative: img, scale: 2).resizable().aspectRatio(32 / 9, contentMode: .fit)
                                }
                            }
                            .aspectRatio(32 / 9, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(doc.presetName == p.stem ? Color.accentColor : .clear, lineWidth: 2))
                            Text(p.style.name).font(Pane.caption).lineLimit(1)
                        }
                        .onTapGesture { doc.choosePreset(p.stem) }
                        .task(id: p.stem + p.style.font) {
                            if thumbs[p.stem] == nil, let t = thumbnail(p.style) { thumbs[p.stem] = t }
                        }
                    }
                }
                .padding(.horizontal, Pane.margin).padding(.bottom, Pane.bottom).padding(.top, 2)
            }
        }
    }
}

// MARK: - The inspector

/// Every field of the style, live, as a column of Keynote-style panes. Edits mark the
/// style as modified from its preset.
struct StyleInspector: View {
    @EnvironmentObject var doc: Document

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                presetPane
                Rule()
                fontPane
                Rule()
                colourPane
                Rule()
                borderPane
                Rule()
                shadowPane
                Rule()
                boxPane
                Rule()
                popPane
                Rule()
                positionPane
                rotatePane
                Rule()
                cardsPane
            }
            .padding(.horizontal, Pane.margin)
            .frame(width: Pane.width)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: doc.style.rotation) { _, r in
            // keep the field in -180...180 however the dial or the stepper turns
            if r > 180 || r <= -180 { doc.style.rotation = (r + 180).truncatingRemainder(dividingBy: 360) - 180 + (r <= -180 ? 360 : 0) }
        }
        .onChange(of: doc.style) { _, _ in
            if let p = doc.presetName, let preset = doc.presets.first(where: { $0.stem == p })?.style, preset != doc.style { doc.presetName = nil }
        }
    }

    /// The style's name in a well, the way Keynote names the paragraph style at the top
    /// of the Text pane; a star marks a preset edited away from its file.
    private var presetPane: some View {
        HStack(spacing: 4) {
            TextField("Style name", text: $doc.style.name)
                .textFieldStyle(.plain)
                .font(.system(size: 17, weight: .bold))
            if doc.presetName == nil { Text("*").font(.system(size: 17, weight: .bold)) }
            Spacer(minLength: 4)
            Button("Save…") { doc.savePreset() }.controlSize(.small)
        }
        .padding(.leading, 12).padding(.trailing, 10)
        .frame(height: 45)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.08)))
        .padding(.vertical, 11)
    }

    private var fontPane: some View {
        PaneStack("Font") {
            FontPicker(font: $doc.style.font, size: $doc.style.size)
            Segments(["AA", "aa", "Aa", "Spoken"], values: [TextCase.upper, .lower, .title, .asis], selection: $doc.style.textCase)
                .frame(width: Pane.content, height: Pane.control)
                .help("Letter case: all capitals, all lower case, title case, or as spoken")
            LabelRow("Tracking") { ValueField(value: $doc.style.tracking, in: -5...20, suffix: "pt") }
        }
    }

    private var colourPane: some View {
        PaneStack {
            LabelRow("Text Color") { ColorWell($doc.style.fill) }
            LabelRow("Spoken Word") { ColorWell($doc.style.highlight) }
            LabelRow("Spoken Scale") {
                ValueField(value: Binding(get: { doc.style.highlightScale * 100 }, set: { doc.style.highlightScale = $0 / 100 }), in: 100...140, suffix: "%")
            }
        }
    }

    /// One row per border the way Keynote lays out a stroke: which, colour, width.
    /// One field of border `i`, safe to read after that border has been removed (a row's
    /// binding is asked once more before the row goes).
    private func stroke<T>(_ i: Int, _ field: WritableKeyPath<Stroke, T>) -> Binding<T> {
        Binding(get: { (doc.style.strokes.indices.contains(i) ? doc.style.strokes[i] : Stroke(color: .black, width: 0))[keyPath: field] },
                set: { if doc.style.strokes.indices.contains(i) { doc.style.strokes[i][keyPath: field] = $0 } })
    }

    private var borderPane: some View {
        PaneStack {
            HStack(spacing: 0) {
                Text("Border").font(Pane.title)
                Spacer()
                ControlGroup {
                    Button { if !doc.style.strokes.isEmpty { doc.style.strokes.removeLast() } } label: { Image(systemName: "minus") }
                        .disabled(doc.style.strokes.isEmpty).help("Remove the innermost border")
                    Button { doc.style.strokes.append(Stroke(color: doc.style.strokes.isEmpty ? .black : Color(r: 0.92, g: 0.05, b: 0.05), width: doc.style.strokes.isEmpty ? 22 : 10)) } label: { Image(systemName: "plus") }
                        .disabled(doc.style.strokes.count >= 3).help("Add a border inside the last one")
                }
                .controlSize(.small).frame(width: 56)
            }
            .frame(height: Pane.control)
            ForEach(doc.style.strokes.indices, id: \.self) { i in
                HStack(spacing: 0) {
                    Text(i == 0 ? "Outer" : (doc.style.strokes.count > 2 && i == 1 ? "Middle" : "Inner")).font(Pane.label)
                        .frame(width: 66, alignment: .leading)
                    Spacer(minLength: 0)
                    ColorWell(stroke(i, \.color))
                    Spacer(minLength: 0)
                    ValueField(value: stroke(i, \.width), in: 0...40, width: 60, suffix: "pt")
                }
                .frame(height: Pane.control)
            }
        }
    }

    // What switching a part on gives it, and what its rows show, disabled, while it is
    // off: the rows stay where they are, so a getter must never unwrap the part.
    private static let newShadow = Shadow(color: Color(r: 0, g: 0, b: 0, a: 0.6), offset: [0, -6], blur: 12)
    private static let newBox = Box(color: Color(r: 0, g: 0, b: 0, a: 0.75), pad: [28, 14], radius: 18)
    private static let newPop = Pop(frames: 3, from: 0.8)
    private var shadow: Shadow { doc.style.shadow ?? Self.newShadow }
    private var box: Box { doc.style.box ?? Self.newBox }
    private var pop: Pop { doc.style.pop ?? Self.newPop }

    private var shadowPane: some View {
        PaneStack {
            CheckTitle("Shadow", isOn: Binding(get: { doc.style.shadow != nil },
                                               set: { doc.style.shadow = $0 ? Self.newShadow : nil }))
            Group {
                SliderRow("Blur", value: Binding(get: { shadow.blur }, set: { doc.style.shadow?.blur = $0 }), in: 0...40, suffix: "pt")
                SliderRow("Offset", value: Binding(get: { -shadow.offset[1] }, set: { doc.style.shadow?.offset = [shadow.offset[0], -$0] }), in: -20...20, suffix: "pt")
                LabelRow("Color") { ColorWell(Binding(get: { shadow.color }, set: { doc.style.shadow?.color = $0 })) }
            }
            .disabled(doc.style.shadow == nil)
        }
    }

    private var boxPane: some View {
        PaneStack {
            CheckTitle("Box", isOn: Binding(get: { doc.style.box != nil },
                                            set: { doc.style.box = $0 ? Self.newBox : nil }))
            Group {
                SliderRow("Padding", value: Binding(get: { box.pad[0] }, set: { doc.style.box?.pad = [$0, $0 / 2] }), in: 0...80, suffix: "pt")
                SliderRow("Corner Radius", value: Binding(get: { box.radius }, set: { doc.style.box?.radius = $0 }), in: 0...60, suffix: "pt")
                LabelRow("Color") { ColorWell(Binding(get: { box.color }, set: { doc.style.box?.color = $0 })) }
            }
            .disabled(doc.style.box == nil)
        }
    }

    private var popPane: some View {
        PaneStack {
            CheckTitle("Pop In", isOn: Binding(get: { doc.style.pop != nil }, set: { doc.style.pop = $0 ? Self.newPop : nil }))
            Group {
                SliderRow("Start Size", value: Binding(get: { pop.from * 100 }, set: { doc.style.pop?.from = $0 / 100 }), in: 30...100, suffix: "%")
                LabelRow("Frames") {
                    ValueField(value: Binding(get: { CGFloat(pop.frames) }, set: { doc.style.pop?.frames = Int($0) }), in: 1...12)
                }
            }
            .disabled(doc.style.pop == nil)
        }
    }

    /// Keynote's Position pane: the title on the left, X and Y right-aligned with their
    /// names centred under the fields.
    private var positionPane: some View {
        PaneStack("Position", gap: 10) {
            HStack(alignment: .top, spacing: 9) {
                Spacer(minLength: 0)
                Captioned("X", width: Pane.wideField) { ValueField(value: coordinate(0), in: -960...960, width: Pane.wideField, suffix: "pt") }
                Captioned("Y", width: Pane.wideField) { ValueField(value: coordinate(1), in: -540...540, width: Pane.wideField, suffix: "pt") }
            }
        }
    }

    /// Keynote's Rotate pane: knob, angle, and the two flips, with names underneath.
    private var rotatePane: some View {
        PaneStack("Rotate", gap: 10) {
            HStack(alignment: .top, spacing: 0) {
                Spacer(minLength: 0)
                AngleDial(angle: $doc.style.rotation).frame(width: 32, height: Pane.control)
                Spacer().frame(width: 11)
                Captioned("Angle", width: Pane.wideField) { ValueField(value: $doc.style.rotation, in: -180...180, width: Pane.wideField, suffix: "°", stepperGap: 6) }
                Spacer().frame(width: 9)
                Captioned("Flip", width: 80) {
                    HStack(spacing: 6) {
                        FlipButton(isOn: $doc.style.flipH, symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right", help: "Flip horizontally")
                        FlipButton(isOn: $doc.style.flipV, symbol: "arrow.up.and.down.righttriangle.up.righttriangle.down", help: "Flip vertically")
                    }
                }
            }
        }
    }

    private var cardsPane: some View {
        PaneStack("Cards") {
            LabelRow("Words per Card") {
                ValueField(value: Binding(get: { CGFloat(doc.style.cards.words) }, set: { doc.style.cards.words = Int($0) }), in: 1...8)
            }
            LabelRow("New Card after Pause") {
                ValueField(value: Binding(get: { CGFloat(doc.style.cards.gap) }, set: { doc.style.cards.gap = Double($0) }), in: 0.2...2, step: 0.1, fraction: 1, suffix: "s")
            }
            LabelRow("Clear after Pause") {
                ValueField(value: Binding(get: { CGFloat(doc.style.cards.linger) }, set: { doc.style.cards.linger = Double($0) }), in: 0.5...4, step: 0.1, fraction: 1, suffix: "s")
            }
        }
    }

    /// One coordinate of the position, with a two-element array behind it.
    private func coordinate(_ i: Int) -> Binding<CGFloat> {
        Binding(get: { doc.style.position.count > i ? doc.style.position[i] : (i == 1 ? -380 : 0) },
                set: { v in
                    var p = doc.style.position
                    while p.count < 2 { p.append(p.count == 1 ? -380 : 0) }
                    p[i] = v
                    doc.style.position = p
                })
    }
}

// MARK: - The pieces

/// A pane: an optional bold title, then control rows a fixed gap apart, with Keynote's
/// top and bottom margins.
struct PaneStack<Content: View>: View {
    let title: String?
    let gap: CGFloat
    @ViewBuilder let content: Content
    init(_ title: String? = nil, gap: CGFloat = Pane.rowGap, @ViewBuilder content: () -> Content) {
        self.title = title; self.gap = gap; self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let t = title {
                Text(t).font(Pane.title).frame(height: 16).padding(.bottom, gap == Pane.rowGap ? Pane.titleBottom : gap)
            }
            VStack(alignment: .leading, spacing: gap) { content }
        }
        .padding(.top, Pane.titleTop).padding(.bottom, Pane.bottom)
        .frame(width: Pane.content, alignment: .leading)
    }
}

/// The line between panes.
struct Rule: View {
    var body: some View { Divider().frame(width: Pane.content) }
}

/// A pane title that is also the switch for the pane (Keynote's Shadow, Reflection).
struct CheckTitle: View {
    let text: String
    @Binding var isOn: Bool
    init(_ text: String, isOn: Binding<Bool>) { self.text = text; _isOn = isOn }
    var body: some View {
        Toggle(isOn: $isOn) { Text(text).font(Pane.title).padding(.leading, 2) }
            .toggleStyle(.checkbox)
            .frame(height: 16)
    }
}

/// Label on the left, its control against the right margin, on one control row.
struct LabelRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content
    @Environment(\.isEnabled) private var isEnabled
    init(_ label: String, @ViewBuilder content: () -> Content) { self.label = label; self.content = content() }

    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(Pane.label).lineLimit(1).foregroundStyle(isEnabled ? .primary : .tertiary)
            Spacer(minLength: 0)
            content
        }
        .frame(height: Pane.control)
    }
}

/// Keynote's slider row: the name on its own line, then the slider with its field and
/// stepper against the right margin.
struct SliderRow: View {
    let label: String
    @Binding var value: CGFloat
    let range: ClosedRange<CGFloat>
    var suffix: String = ""
    @Environment(\.isEnabled) private var isEnabled
    init(_ label: String, value: Binding<CGFloat>, in range: ClosedRange<CGFloat>, suffix: String = "") {
        self.label = label; _value = value; self.range = range; self.suffix = suffix
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(Pane.label).frame(height: 16).foregroundStyle(isEnabled ? .primary : .tertiary)
            HStack(spacing: 0) {
                Slider(value: $value, in: range).controlSize(.small).frame(width: Pane.slider)
                Spacer(minLength: 0)
                ValueField(value: $value, in: range, suffix: suffix)
            }
            .frame(height: Pane.control)
        }
    }
}

/// A control with its name in small type centred beneath its first `width` points.
struct Captioned<Content: View>: View {
    let caption: String
    let width: CGFloat
    @ViewBuilder let content: Content
    init(_ caption: String, width: CGFloat, @ViewBuilder content: () -> Content) { self.caption = caption; self.width = width; self.content = content() }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            content.frame(height: Pane.control)
            Text(caption).font(Pane.caption).foregroundStyle(.secondary).frame(width: width, height: 14)
        }
    }
}

/// A number with its unit inside the field and a stepper beside it: Keynote's "120 pt".
struct ValueField: View {
    @Binding var value: CGFloat
    let range: ClosedRange<CGFloat>
    var step: CGFloat = 1
    var width: CGFloat = Pane.field
    var stepperGap: CGFloat = Pane.stepperGap
    private let formatter: NumberFormatter

    init(value: Binding<CGFloat>, in range: ClosedRange<CGFloat>, step: CGFloat = 1, fraction: Int = 0,
         width: CGFloat = Pane.field, suffix: String = "", stepperGap: CGFloat = Pane.stepperGap) {
        _value = value; self.range = range; self.step = step; self.width = width; self.stepperGap = stepperGap
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.usesGroupingSeparator = false
        f.minimumFractionDigits = fraction
        f.maximumFractionDigits = fraction
        f.isLenient = true
        let unit = suffix.isEmpty ? "" : (suffix == "°" || suffix == "%" ? suffix : " " + suffix)
        f.positiveSuffix = unit
        f.negativeSuffix = unit
        formatter = f
    }

    var body: some View {
        HStack(spacing: stepperGap) {
            NumberField(value: $value, range: range, step: step, formatter: formatter)
                .frame(width: width)
            Stepper("", value: $value, in: range, step: step).labelsHidden()
        }
        .frame(height: Pane.control)
    }
}

/// The field of a `ValueField`: a text field that also steps with the arrow keys, as
/// Keynote's do. Up and Down move the value by one step (ten with Shift) from whatever
/// is typed, and leave it selected so the next number typed replaces it.
private struct NumberField: NSViewRepresentable {
    @Binding var value: CGFloat
    let range: ClosedRange<CGFloat>
    let step: CGFloat
    let formatter: NumberFormatter

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.bezelStyle = .roundedBezel
        field.font = .systemFont(ofSize: 12)
        field.alignment = .right
        field.formatter = formatter
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.commit(_:))
        field.objectValue = NSNumber(value: Double(value))
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        field.isEnabled = context.environment.isEnabled
        // a field being typed in keeps its text; the arrow keys write it themselves
        if field.currentEditor() == nil, (field.objectValue as? NSNumber)?.doubleValue != Double(value) {
            field.objectValue = NSNumber(value: Double(value))
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: NumberField
        init(_ parent: NumberField) { self.parent = parent }

        private func clamp(_ v: CGFloat) -> CGFloat { min(max(v, parent.range.lowerBound), parent.range.upperBound) }

        @objc func commit(_ field: NSTextField) {
            let v = clamp(CGFloat(field.doubleValue))
            parent.value = v
            field.objectValue = NSNumber(value: Double(v))
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            let direction: CGFloat
            var steps: CGFloat = 1
            switch selector {
            case #selector(NSResponder.moveUp(_:)): direction = 1
            case #selector(NSResponder.moveDown(_:)): direction = -1
            case #selector(NSResponder.moveUpAndModifySelection(_:)): direction = 1; steps = 10
            case #selector(NSResponder.moveDownAndModifySelection(_:)): direction = -1; steps = 10
            default: return false
            }
            let typed = parent.formatter.number(from: textView.string).map { CGFloat($0.doubleValue) }
            let v = clamp((typed ?? parent.value) + direction * steps * parent.step)
            parent.value = v
            textView.string = parent.formatter.string(from: NSNumber(value: Double(v))) ?? ""
            textView.selectAll(nil)
            return true
        }
    }
}

/// A segmented control that stays the width it is given, in equal segments. (SwiftUI's
/// segmented picker re-measures itself on an update and spills over the pane's margins.)
struct Segments<Value: Hashable>: NSViewRepresentable {
    let labels: [String]
    let values: [Value]
    @Binding var selection: Value
    init(_ labels: [String], values: [Value], selection: Binding<Value>) {
        self.labels = labels; self.values = values; _selection = selection
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: labels, trackingMode: .selectOne, target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        control.segmentDistribution = .fillEqually
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        control.isEnabled = context.environment.isEnabled
        control.selectedSegment = values.firstIndex(of: selection) ?? -1
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.fittingSize.width, height: proposal.height ?? nsView.fittingSize.height)
    }

    final class Coordinator: NSObject {
        var parent: Segments
        init(_ parent: Segments) { self.parent = parent }
        @objc func changed(_ control: NSSegmentedControl) {
            if parent.values.indices.contains(control.selectedSegment) { parent.selection = parent.values[control.selectedSegment] }
        }
    }
}

/// A colour well at Keynote's size: the swatch opens the palette, the wheel the panel.
struct ColorWell: NSViewRepresentable {
    @Binding var color: PhrasoKit.Color
    init(_ color: Binding<PhrasoKit.Color>) { _color = color }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSColorWell {
        let well = NSColorWell(style: .expanded)
        well.supportsAlpha = true
        well.target = context.coordinator
        well.action = #selector(Coordinator.changed(_:))
        return well
    }

    func updateNSView(_ well: NSColorWell, context: Context) {
        well.isEnabled = context.environment.isEnabled
        context.coordinator.parent = self
        let c = NSColor(srgbRed: color.r, green: color.g, blue: color.b, alpha: color.a)
        if well.color != c { well.color = c }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSColorWell, context: Context) -> CGSize? { Pane.well }

    final class Coordinator: NSObject {
        var parent: ColorWell
        init(_ p: ColorWell) { parent = p }
        @objc func changed(_ well: NSColorWell) {
            guard let c = well.color.usingColorSpace(.sRGB) else { return }
            parent.color = PhrasoKit.Color(r: c.redComponent, g: c.greenComponent, b: c.blueComponent, a: c.alphaComponent)
        }
    }
}

/// One of Keynote's two flip buttons: 37 by 24, lit while the flip is on.
struct FlipButton: View {
    @Binding var isOn: Bool
    let symbol: String
    let help: String

    var body: some View {
        Toggle(isOn: $isOn) { Image(systemName: symbol).frame(width: 37 - 14, height: 14) }
            .toggleStyle(.button)
            .frame(width: 37, height: Pane.control)
            .help(help)
    }
}

/// Keynote's rotation knob: drag the handle round; the angle is where it points.
struct AngleDial: View {
    @Binding var angle: CGFloat
    private let d: CGFloat = 24

    var body: some View {
        ZStack {
            Circle().fill(Color.primary.opacity(0.08))
            Circle().stroke(Color.primary.opacity(0.25), lineWidth: 1)
            Capsule().fill(Color.primary.opacity(0.7)).frame(width: d * 0.4, height: 2.5)
                .offset(x: -d * 0.22)
                .rotationEffect(.degrees(-Double(angle)))
        }
        .frame(width: d, height: d)
        .contentShape(Circle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { g in
            let v = CGPoint(x: g.location.x - d / 2, y: g.location.y - d / 2)
            guard hypot(v.x, v.y) > 2 else { return }
            var a = atan2(-v.y, -v.x) * 180 / .pi  // the handle starts on the left
            a = (a / 5).rounded() * 5
            angle = a
        })
        .help("Drag to rotate")
    }
}
