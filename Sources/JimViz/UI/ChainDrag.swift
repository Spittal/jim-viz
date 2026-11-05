import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The kinds of device a scene's chain holds, left to right.
enum DeviceKind: String, CaseIterable {
    case input, modulation, camera, palette, generator, effect
}

/// Something being dragged onto the device chain: a browser item, an effect being moved,
/// or a tool output on its way to a knob.
///
/// Drag sources set `Engine.activeDrag` when the drag starts, so drop targets know what is
/// coming while it hovers (to draw the insertion point) instead of waiting for the async
/// pasteboard read. The pasteboard carries a matching token, checked on drop, so a stale
/// `activeDrag` from a cancelled drag can't be applied to text dragged in from another app.
enum ChainDrag: Equatable {
    /// A tool from the browser, optionally with one of its presets.
    case device(DeviceKind, tool: String, preset: String?)
    case move(effectID: String)
    /// An output key (`audio.kick`), dropped onto a knob to map it.
    case output(String)

    /// The kind of device it places, or nil for an output.
    var kind: DeviceKind? {
        switch self {
        case .device(let k, _, _): return k
        case .move: return .effect
        case .output: return nil
        }
    }

    var token: String {
        switch self {
        case .device(let k, let tool, let preset): return "jimviz.device:\(k.rawValue):\(tool):\(preset ?? "")"
        case .move(let id): return "jimviz.move:\(id)"
        case .output(let key): return "jimviz.output:\(key)"
        }
    }
}

extension View {
    /// Makes this view a drag source for the chain. Uses AppKit's drag session (`onDrag`),
    /// which starts on the first mouse movement and doesn't fight sibling click handlers.
    func chainDragSource(_ drag: ChainDrag, engine: Engine) -> some View {
        onDrag {
            engine.activeDrag = drag
            // Dragging a stream output enters map mode, which shows the inputs to drop on.
            if case .output(let key) = drag, engine.kind(of: key).isStream {
                DispatchQueue.main.async { engine.mapSource = key }
            }
            return NSItemProvider(object: drag.token as NSString)
        }
    }
}

/// Where a hovering drag would land.
enum ChainDropTarget: Equatable {
    /// Replaces a single-slot device in the chain (cardinality == .one: camera, palette).
    case replace(DeviceKind)
    /// Appends a multi-instance device to the chain (cardinality == .many: generator, modulation, input).
    case append(DeviceKind)
    /// Inserts an effect before the effect at this index (count = at the end).
    case effectIndex(Int)
    /// Maps an output to the knob, or video input, with this target key.
    case knob(String)
}

/// Frames of chain devices in the chain's coordinate space, keyed by effect id or slot name.
struct ChainFrameKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

extension View {
    func chainFrame(_ key: String) -> some View {
        background(GeometryReader { g in
            Color.clear.preference(key: ChainFrameKey.self, value: [key: g.frame(in: .named(ChainDropDelegate.space))])
        })
    }
}

/// One drop target for the whole chain. Single-slot kinds drop anywhere and replace their slot;
/// effects insert at the gap nearest the pointer.
struct ChainDropDelegate: DropDelegate {
    static let space = "chain"
    static let endKey = "effects.end"
    static func knobKey(_ target: String) -> String { "knob:\(target)" }

    let engine: Engine
    let effectIDs: [String]
    let frames: [String: CGRect]
    @Binding var target: ChainDropTarget?

    func validateDrop(info: DropInfo) -> Bool {
        engine.activeDrag != nil && info.hasItemsConforming(to: [.plainText])
    }

    func dropEntered(info: DropInfo) { target = resolve(info.location) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        target = resolve(info.location)
        guard target != nil else { return DropProposal(operation: .forbidden) }
        if case .move = engine.activeDrag { return DropProposal(operation: .move) }
        
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) { target = nil }

    func performDrop(info: DropInfo) -> Bool {
        let landing = resolve(info.location)
        target = nil
        guard let drag = engine.activeDrag, let landing,
              let provider = info.itemProviders(for: [.plainText]).first else { return false }
        engine.activeDrag = nil
        let token = drag.token
        let engine = self.engine
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let text = object as? NSString, text as String == token else { return }
            DispatchQueue.main.async { engine.drop(drag, at: landing) }
        }
        return true
    }

    private func resolve(_ location: CGPoint) -> ChainDropTarget? {
        guard let drag = engine.activeDrag else { return nil }
        if case .output(let source) = drag {
            // Only inputs of the same kind: knobs take values, video inputs take video.
            let kind = engine.kind(of: source)
            let hit = frames.first {
                $0.key.hasPrefix("knob:") && $0.value.contains(location) && engine.kind(of: String($0.key.dropFirst(5))) == kind
            }
            return hit.map { .knob(String($0.key.dropFirst(5))) }
        }
        if case .move(let id) = drag {
            let index = effectIDs.filter { (frames[$0]?.midX ?? .infinity) < location.x }.count
            // Moving an effect into the gap on either side of itself changes nothing.
            if let from = effectIDs.firstIndex(of: id), index == from || index == from + 1 {
                return nil
            }
            return .effectIndex(index)
        }
        if case .device(let kind, let tool, _) = drag {
            if kind == .effect {
                let index = effectIDs.filter { (frames[$0]?.midX ?? .infinity) < location.x }.count
                return .effectIndex(index)
            }
            let cardinality = Tools.cardinality(kind, tool)
            return cardinality == .one ? .replace(kind) : .append(kind)
        }
        return nil
    }

    /// x of the insertion marker for an effect drop.
    static func markerX(_ index: Int, ids: [String], frames: [String: CGRect]) -> CGFloat? {
        let key = index < ids.count ? ids[index] : endKey
        return frames[key].map { $0.minX - 4.5 }
    }
}

extension Engine {
    func drop(_ drag: ChainDrag, at target: ChainDropTarget) {
        switch (drag, target) {
        case (.move(let id), .effectIndex(let i)):
            moveEffect(id: id, to: i)
        case (.device(.effect, let tool, let preset), .effectIndex(let i)):
            apply(.effect, tool, preset: preset, at: i)
        case (.device(let kind, let tool, let preset), .replace):
            apply(kind, tool, preset: preset, replaceSelected: true)
        case (.device(let kind, let tool, let preset), .append):
            apply(kind, tool, preset: preset, replaceSelected: false)
        case (.output(let key), .knob(let target)):
            addMapping(source: key, target: target)
            if mapSource == key, kind(of: key).isStream { mapSource = nil }
        default:
            break
        }
    }
}
