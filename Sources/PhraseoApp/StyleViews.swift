import AppKit
import PhraseoKit
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

/// The presets, shipped and the user's own, as thumbnails. Click one to take its style.
struct StyleGrid: View {
    @EnvironmentObject var doc: Document
    @State private var thumbs: [String: CGImage] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Styles").font(.headline)
                Spacer()
                Button("Presets Folder") { doc.revealPresets() }.controlSize(.small)
                Button { doc.reloadPresets(); thumbs = [:] } label: { Image(systemName: "arrow.clockwise") }.controlSize(.small)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                    ForEach(doc.presets, id: \.stem) { p in
                        VStack(spacing: 3) {
                            ZStack {
                                Color(white: 0.28)
                                if let img = thumbs[p.stem] {
                                    Image(decorative: img, scale: 2).resizable().aspectRatio(32 / 9, contentMode: .fit)
                                }
                            }
                            .aspectRatio(32 / 9, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(doc.presetName == p.stem ? Color.accentColor : .clear, lineWidth: 2))
                            Text(p.style.name).font(.caption).lineLimit(1)
                        }
                        .onTapGesture { doc.choosePreset(p.stem) }
                        .task(id: p.stem + p.style.font) {
                            if thumbs[p.stem] == nil, let t = thumbnail(p.style) { thumbs[p.stem] = t }
                        }
                    }
                }
                .padding(10)
            }
        }
    }
}

/// Every field of the style, live. Edits mark the style as modified from its preset.
struct StyleInspector: View {
    @EnvironmentObject var doc: Document

    var body: some View {
        Form {
            Section("Font") {
                TextField("Name", text: $doc.style.name)
                FontPicker(font: $doc.style.font, size: $doc.style.size)
                Picker("Case", selection: $doc.style.textCase) {
                    Text("UPPER").tag(TextCase.upper); Text("lower").tag(TextCase.lower)
                    Text("Title").tag(TextCase.title); Text("As spoken").tag(TextCase.asis)
                }
                HStack {
                    Text("Tracking"); Slider(value: $doc.style.tracking, in: -5...20)
                    Text(String(format: "%.0f", doc.style.tracking)).monospacedDigit().frame(width: 36, alignment: .trailing)
                }
            }
            Section("Position") {
                HStack(alignment: .top, spacing: 12) {
                    NumberField("X", value: coordinate(0), in: -960...960)
                    NumberField("Y", value: coordinate(1), in: -540...540)
                }
            }
            Section("Rotate") {
                HStack(alignment: .top, spacing: 12) {
                    AngleDial(angle: $doc.style.rotation)
                    NumberField("Angle", value: $doc.style.rotation, in: -180...180, suffix: "°")
                    VStack(spacing: 4) {
                        HStack(spacing: 4) {
                            Toggle(isOn: $doc.style.flipH) { Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
                                .help("Flip horizontally")
                            Toggle(isOn: $doc.style.flipV) { Image(systemName: "arrow.up.and.down.righttriangle.up.righttriangle.down") }
                                .help("Flip vertically")
                        }
                        .toggleStyle(.button)
                        Text("Flip").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section("Colour") {
                ColorRow("Fill", $doc.style.fill)
                ColorRow("Spoken word", $doc.style.highlight)
                HStack {
                    Text("Spoken word scale"); Slider(value: $doc.style.highlightScale, in: 1...1.4)
                    Text(String(format: "%.2f", doc.style.highlightScale)).monospacedDigit().frame(width: 36, alignment: .trailing)
                }
            }
            Section {
                ForEach(doc.style.strokes.indices, id: \.self) { i in
                    HStack {
                        ColorRow(i == 0 ? "Outer" : "Inner \(i)", $doc.style.strokes[i].color)
                        Slider(value: $doc.style.strokes[i].width, in: 0...40)
                        Text("\(Int(doc.style.strokes[i].width))").monospacedDigit().frame(width: 28, alignment: .trailing)
                        Button { doc.style.strokes.remove(at: i) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                    }
                }
                Button("Add Border") { doc.style.strokes.append(Stroke(color: doc.style.strokes.isEmpty ? .black : Color(r: 0.92, g: 0.05, b: 0.05), width: doc.style.strokes.isEmpty ? 22 : 10)) }
                    .disabled(doc.style.strokes.count >= 3)
            } header: { Text("Borders (outermost first)") }
            Section {
                Toggle("Shadow", isOn: Binding(get: { doc.style.shadow != nil },
                                               set: { doc.style.shadow = $0 ? Shadow(color: Color(r: 0, g: 0, b: 0, a: 0.6), offset: [0, -6], blur: 12) : nil }))
                if doc.style.shadow != nil {
                    ColorRow("Colour", Binding(get: { doc.style.shadow!.color }, set: { doc.style.shadow!.color = $0 }))
                    HStack { Text("Blur"); Slider(value: Binding(get: { doc.style.shadow!.blur }, set: { doc.style.shadow!.blur = $0 }), in: 0...40) }
                    HStack { Text("Drop"); Slider(value: Binding(get: { -doc.style.shadow!.offset[1] }, set: { doc.style.shadow!.offset = [doc.style.shadow!.offset[0], -$0] }), in: -20...20) }
                }
                Toggle("Box", isOn: Binding(get: { doc.style.box != nil },
                                            set: { doc.style.box = $0 ? Box(color: Color(r: 0, g: 0, b: 0, a: 0.75), pad: [28, 14], radius: 18) : nil }))
                if doc.style.box != nil {
                    ColorRow("Colour", Binding(get: { doc.style.box!.color }, set: { doc.style.box!.color = $0 }))
                    HStack { Text("Padding"); Slider(value: Binding(get: { doc.style.box!.pad[0] }, set: { doc.style.box!.pad = [$0, $0 / 2] }), in: 0...80) }
                    HStack { Text("Corner"); Slider(value: Binding(get: { doc.style.box!.radius }, set: { doc.style.box!.radius = $0 }), in: 0...60) }
                }
                Toggle("Pop in", isOn: Binding(get: { doc.style.pop != nil }, set: { doc.style.pop = $0 ? Pop(frames: 3, from: 0.8) : nil }))
                if doc.style.pop != nil {
                    HStack { Text("Frames"); Stepper("\(doc.style.pop!.frames)", value: Binding(get: { doc.style.pop!.frames }, set: { doc.style.pop!.frames = $0 }), in: 1...12) }
                    HStack { Text("From"); Slider(value: Binding(get: { doc.style.pop!.from }, set: { doc.style.pop!.from = $0 }), in: 0.3...1) }
                }
            } header: { Text("Effects") }
            Section("Cards") {
                Stepper("Words per card: \(doc.style.cards.words)", value: $doc.style.cards.words, in: 1...8)
                HStack { Text("New card after a pause of"); Spacer(); Text(String(format: "%.1f s", doc.style.cards.gap)).monospacedDigit() }
                Slider(value: $doc.style.cards.gap, in: 0.2...2)
                HStack { Text("Drop after a pause of"); Spacer(); Text(String(format: "%.1f s", doc.style.cards.linger)).monospacedDigit() }
                Slider(value: $doc.style.cards.linger, in: 0.5...4)
            }
        }
        .formStyle(.grouped)
        .onChange(of: doc.style.rotation) { _, r in
            // keep the field in -180...180 however the dial or the stepper turns
            if r > 180 || r <= -180 { doc.style.rotation = (r + 180).truncatingRemainder(dividingBy: 360) - 180 + (r <= -180 ? 360 : 0) }
        }
        .onChange(of: doc.style) { _, _ in
            if let p = doc.presetName, let preset = doc.presets.first(where: { $0.stem == p })?.style, preset != doc.style { doc.presetName = nil }
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

struct ColorRow: View {
    let label: String
    @Binding var color: PhraseoKit.Color
    init(_ label: String, _ color: Binding<PhraseoKit.Color>) { self.label = label; _color = color }

    var body: some View {
        ColorPicker(label, selection: Binding<CGColor>(
            get: { color.cgColor },
            set: { cg in
                let c = cg.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil) ?? cg
                let k = c.components ?? [0, 0, 0, 1]
                color = k.count >= 4 ? PhraseoKit.Color(r: k[0], g: k[1], b: k[2], a: k[3]) : PhraseoKit.Color(r: k[0], g: k[0], b: k[0], a: k.count > 1 ? k[1] : 1)
            }), supportsOpacity: true)
    }
}

/// A number with a stepper and its name underneath, the way Keynote lays out X and Y.
struct NumberField: View {
    let label: String
    @Binding var value: CGFloat
    let range: ClosedRange<CGFloat>
    var suffix: String = ""
    init(_ label: String, value: Binding<CGFloat>, in range: ClosedRange<CGFloat>, suffix: String = "") {
        self.label = label; _value = value; self.range = range; self.suffix = suffix
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 0) {
                HStack(spacing: 1) {
                    TextField("", value: $value, format: FloatingPointFormatStyle<CGFloat>().precision(.fractionLength(0)))
                        .labelsHidden().multilineTextAlignment(.trailing)
                    if !suffix.isEmpty { Text(suffix).foregroundStyle(.secondary) }
                }
                .frame(width: 70)
                Stepper("", value: $value, in: range, step: 1).labelsHidden()
            }
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Keynote's rotation knob: drag the handle round; the angle is where it points.
struct AngleDial: View {
    @Binding var angle: CGFloat
    private let d: CGFloat = 26

    var body: some View {
        ZStack {
            Circle().fill(Color.primary.opacity(0.08))
            Circle().stroke(Color.primary.opacity(0.25), lineWidth: 1)
            Capsule().fill(Color.primary.opacity(0.7)).frame(width: d * 0.42, height: 2.5)
                .offset(x: -d * 0.22)
                .rotationEffect(.degrees(-Double(angle)))
        }
        .frame(width: d, height: d)
        .padding(.top, 2)
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
