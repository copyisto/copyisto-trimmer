import SwiftUI

/// One page with its boxes. Drag on empty paper to draw a box, drag a box to move it, drag a handle to resize it.
struct CanvasView: View {
    @Environment(Store.self) private var store
    let image: String
    let url: URL

    @State private var loaded: (url: URL, preview: Preview)?
    @State private var full: (url: URL, image: CGImage)?
    @State private var drag: Drag?
    @State private var pointer: PointerStyle?
    @State private var hoveredBox: Int?
    @State private var scroll = ScrollPosition()
    @State private var visible = CGRect.zero
    @State private var pinch: (startZoom: CGFloat, anchor: ZoomAnchor)?

    private static let padding: CGFloat = 24
    private static let handleSize: CGFloat = 8
    private static let handleHitRadius: CGFloat = 9

    /// What the current mouse drag is doing; `draft` is the box as it would be if the mouse were released now.
    private struct Drag {
        enum Kind {
            case create(start: CGPoint)
            case move(id: Int, original: CGRect)
            case resize(id: Int, handle: Handle, original: CGRect)
        }
        var kind: Kind
        var draft: CGRect

        var boxId: Int? {
            switch kind {
            case .create: nil
            case .move(let id, _), .resize(let id, _, _): id
            }
        }
    }

    /// The image point that stays put on screen while zooming: under the fingers for a pinch, the middle for ⌘+.
    private struct ZoomAnchor {
        var image: CGPoint
        var screen: CGPoint
    }

    var body: some View {
        GeometryReader { geometry in
            if let loaded, loaded.url == url {
                zoomable(loaded.preview, viewport: geometry.size)
            } else {
                DelayedSpinner()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.sunken)
        .overlay(alignment: .top) {
            if let loaded, loaded.url == url, store.sizeChanged(image, actual: loaded.preview.pixelSize) {
                Label(
                    "To zdjęcie ma inne wymiary niż przy zaznaczaniu boxów – sprawdź je przed eksportem.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(Theme.text(12, weight: .medium))
                .foregroundStyle(Theme.warning)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Theme.warningSoft, in: .rect(cornerRadius: 8))
                .padding(.top, 8)
            }
        }
        .task(id: url) {
            // Box ids repeat across pages, so a hover left over from the previous page must not reach the context menu.
            drag = nil
            hoveredBox = nil
            if let preview = await store.previews.preview(for: url) {
                loaded = (url, preview)
            } else {
                store.error = "Nie udało się odczytać zdjęcia „\(image)”."
            }
        }
        // The downsampled preview goes soft when zoomed in, so the full scan is decoded for the current page only.
        .task(id: store.zoom > 1 ? url : nil) {
            guard store.zoom > 1 else { full = nil; return }
            guard full?.url != url else { return }
            let target = url
            let image = await Task.detached(priority: .userInitiated) { PreviewCache.decodeFull(target) }.value
            if let image, target == url { full = (target, image) }
        }
    }

    /// Fits the page at zoom 1; above that the page grows and the canvas scrolls.
    private func layout(_ size: CGSize, viewport: CGSize, zoom: CGFloat) -> (mapping: Mapping, content: CGSize) {
        let scale = Mapping(imageSize: size, canvas: viewport, padding: Self.padding).scale * zoom
        let scaled = CGSize(width: size.width * scale, height: size.height * scale)
        let content = CGSize(
            width: max(viewport.width, scaled.width + Self.padding * 2),
            height: max(viewport.height, scaled.height + Self.padding * 2))
        let origin = CGPoint(x: (content.width - scaled.width) / 2, y: (content.height - scaled.height) / 2)
        return (Mapping(scale: scale, origin: origin), content)
    }

    private func zoomable(_ preview: Preview, viewport: CGSize) -> some View {
        let size = preview.pixelSize
        let (mapping, content) = layout(size, viewport: viewport, zoom: store.zoom)
        return ScrollView([.horizontal, .vertical]) {
            page(preview, mapping: mapping)
                .frame(width: content.width, height: content.height)
                .simultaneousGesture(
                    MagnifyGesture()
                        .onChanged { value in
                            if pinch == nil {
                                let anchor = ZoomAnchor(
                                    image: mapping.toImage(value.startLocation),
                                    screen: CGPoint(
                                        x: value.startLocation.x - visible.minX,
                                        y: value.startLocation.y - visible.minY))
                                pinch = (store.zoom, anchor)
                            }
                            if let pinch { store.setZoom(pinch.startZoom * value.magnification) }
                        }
                        .onEnded { _ in pinch = nil })
        }
        .scrollIndicators(store.zoom > 1 ? .automatic : .never)
        .scrollBounceBehavior(.basedOnSize)
        .scrollPosition($scroll)
        .onScrollGeometryChange(for: CGRect.self, of: \.visibleRect) { _, rect in visible = rect }
        .onChange(of: store.zoom) { old, new in
            let before = layout(size, viewport: viewport, zoom: old).mapping
            let after = layout(size, viewport: viewport, zoom: new).mapping
            let anchor = pinch?.anchor ?? ZoomAnchor(
                image: before.toImage(CGPoint(x: visible.midX, y: visible.midY)),
                screen: CGPoint(x: visible.width / 2, y: visible.height / 2))
            let target = after.toView(anchor.image)
            scroll.scrollTo(point: CGPoint(x: max(target.x - anchor.screen.x, 0), y: max(target.y - anchor.screen.y, 0)))
        }
    }

    private func page(_ preview: Preview, mapping: Mapping) -> some View {
        let size = preview.pixelSize
        let frame = mapping.toView(CGRect(origin: .zero, size: size))
        let source = full.flatMap { $0.url == url ? $0.image : nil } ?? preview.image
        return ZStack(alignment: .topLeading) {
            Image(decorative: source, scale: 1)
                .resizable()
                .interpolation(.high)
                .frame(width: frame.width, height: frame.height)
                // Turned inside the page's own frame, with white corners, exactly as the export renders it.
                .rotationEffect(.degrees(store.rotation(of: image)))
                .frame(width: frame.width, height: frame.height)
                .background(.white)
                .clipped()
                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                .offset(x: frame.minX, y: frame.minY)
            Canvas { context, _ in draw(in: &context, mapping: mapping) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(dragGesture(mapping: mapping, size: size))
        .onContinuousHover { phase in
            if case .active(let location) = phase {
                pointer = pointerStyle(at: location, mapping: mapping, size: size)
                hoveredBox = switch hit(at: location, mapping: mapping) {
                case .handle(let box, _), .box(let box): box.id
                case .empty: nil
                }
            } else {
                // hoveredBox is kept: opening the context menu ends the hover, and the menu still needs the box.
                pointer = nil
            }
        }
        .contextMenu {
            // Right-click acts on the box under the pointer, otherwise on the selected one.
            if let id = hoveredBox ?? store.selectedBox {
                Button("Usuń box", systemImage: "trash", role: .destructive) { store.deleteBox(id, on: image) }
            }
        }
        .pointerStyle(drag.map(pointerStyle(for:)) ?? pointer)
    }

    // MARK: Drawing

    private func draw(in context: inout GraphicsContext, mapping: Mapping) {
        let all = store.boxes(for: image)
        let numbers = Dictionary(uniqueKeysWithValues: all.enumerated().map { ($1.id, $0 + 1) })
        // The selected box is drawn last, so it stays on top where its handles can be grabbed.
        var boxes = (all.filter { $0.id != store.selectedBox } + all.filter { $0.id == store.selectedBox })
            .map { (id: Optional($0.id), rect: $0.rect) }
        if let drag {
            if let id = drag.boxId, let index = boxes.firstIndex(where: { $0.id == id }) {
                boxes[index].rect = drag.draft
            } else if drag.boxId == nil {
                boxes.append((nil, drag.draft))
            }
        }

        for box in boxes {
            let rect = mapping.toView(box.rect)
            let isSelected = box.id != nil && box.id == store.selectedBox
            let path = Path(rect)
            context.fill(path, with: .color(Theme.accent.opacity(isSelected ? 0.14 : 0.08)))
            if let id = box.id {
                context.stroke(path, with: .color(Theme.accent), lineWidth: isSelected ? 2.5 : 1.5)
                drawLabel(numbers[id] ?? 0, at: rect, in: &context)
            } else {
                // A box being drawn is dashed until the mouse is released.
                context.stroke(path, with: .color(Theme.accent), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            }
            if isSelected {
                for handle in Handle.allCases {
                    let center = handle.point(on: rect)
                    let square = Path(CGRect(
                        x: center.x - Self.handleSize / 2, y: center.y - Self.handleSize / 2,
                        width: Self.handleSize, height: Self.handleSize))
                    context.fill(square, with: .color(Theme.surface))
                    context.stroke(square, with: .color(Theme.accent), lineWidth: 1.5)
                }
            }
        }
    }

    /// The box number in its top-left corner: the same number as in the exported file name.
    private func drawLabel(_ number: Int, at rect: CGRect, in context: inout GraphicsContext) {
        let text = context.resolve(
            Text(String(format: "%03d", number))
                .font(Theme.text(10, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.onAccent))
        let size = text.measure(in: CGSize(width: 200, height: 50))
        let badge = CGRect(x: rect.minX, y: rect.minY, width: size.width + 8, height: size.height + 2)
        guard badge.width < rect.width, badge.height < rect.height else { return }
        context.fill(Path(badge), with: .color(Theme.accent))
        context.draw(text, at: CGPoint(x: badge.midX, y: badge.midY))
    }

    // MARK: Interaction

    private func dragGesture(mapping: Mapping, size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let point = mapping.toImage(value.location)
                if drag == nil { drag = begin(at: value.startLocation, mapping: mapping, size: size) }
                guard var current = drag else { return }
                switch current.kind {
                case .create(let start):
                    current.draft = clamped(spanning(start, point), to: size)
                case .move(_, let original):
                    let delta = CGSize(
                        width: value.translation.width / mapping.scale,
                        height: value.translation.height / mapping.scale)
                    current.draft = moved(original, by: delta, within: size)
                case .resize(_, let handle, let original):
                    current.draft = clamped(resized(original, handle: handle, to: point), to: size)
                }
                drag = current
            }
            .onEnded { _ in
                guard let finished = drag else { return }
                drag = nil
                switch finished.kind {
                case .create:
                    if isUsable(finished.draft) {
                        store.addBox(finished.draft, on: image, imageSize: size)
                    }
                case .move(let id, let original), .resize(let id, _, let original):
                    // A resize squeezed below the minimum snaps back instead of deleting the box.
                    if finished.draft != original, isUsable(finished.draft) {
                        store.updateBox(id, rect: finished.draft, on: image, imageSize: size)
                    }
                }
            }
    }

    private func begin(at location: CGPoint, mapping: Mapping, size: CGSize) -> Drag {
        switch hit(at: location, mapping: mapping) {
        case .handle(let box, let handle):
            return Drag(kind: .resize(id: box.id, handle: handle, original: box.rect), draft: box.rect)
        case .box(let box):
            store.selectedBox = box.id
            return Drag(kind: .move(id: box.id, original: box.rect), draft: box.rect)
        case .empty:
            store.selectedBox = nil
            // Starting in the margin around the page begins the box at the page edge.
            let point = mapping.toImage(location)
            let start = CGPoint(x: min(max(point.x, 0), size.width), y: min(max(point.y, 0), size.height))
            return Drag(kind: .create(start: start), draft: .zero)
        }
    }

    private enum Hit {
        case handle(Box, Handle)
        case box(Box)
        case empty
    }

    private func hit(at location: CGPoint, mapping: Mapping) -> Hit {
        let boxes = store.boxes(for: image)
        if let selected = boxes.first(where: { $0.id == store.selectedBox }) {
            let rect = mapping.toView(selected.rect)
            for handle in Handle.allCases {
                let center = handle.point(on: rect)
                if hypot(center.x - location.x, center.y - location.y) <= Self.handleHitRadius {
                    return .handle(selected, handle)
                }
            }
            if rect.contains(location) { return .box(selected) }
        }
        // Later boxes are drawn on top, so they win when boxes overlap.
        if let box = boxes.last(where: { mapping.toView($0.rect).contains(location) }) {
            return .box(box)
        }
        return .empty
    }

    private func pointerStyle(at location: CGPoint, mapping: Mapping, size: CGSize) -> PointerStyle? {
        switch hit(at: location, mapping: mapping) {
        case .handle(_, let handle): .frameResize(position: handle.resizePosition)
        case .box: .grabIdle
        case .empty:
            mapping.toView(CGRect(origin: .zero, size: size)).contains(location) ? .rectSelection : nil
        }
    }

    private func pointerStyle(for drag: Drag) -> PointerStyle {
        switch drag.kind {
        case .create: .rectSelection
        case .move: .grabActive
        case .resize(_, let handle, _): .frameResize(position: handle.resizePosition)
        }
    }
}

extension Handle {
    var resizePosition: FrameResizePosition {
        switch self {
        case .topLeft: .topLeading
        case .top: .top
        case .topRight: .topTrailing
        case .right: .trailing
        case .bottomRight: .bottomTrailing
        case .bottom: .bottom
        case .bottomLeft: .bottomLeading
        case .left: .leading
        }
    }
}

/// Only shows up when a page takes a moment to decode, so cached pages never flash a spinner.
private struct DelayedSpinner: View {
    @State private var visible = false

    var body: some View {
        ProgressView()
            .controlSize(.small)
            .opacity(visible ? 1 : 0)
            .task {
                try? await Task.sleep(for: .milliseconds(250))
                visible = true
            }
    }
}
