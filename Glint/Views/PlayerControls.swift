import SwiftUI

/// Controles sobre el vídeo. Todo tiene un sitio fijo: pausar solo cambia el
/// icono, nunca mueve nada. Se ocultan solos a los 3 s mientras se reproduce.
///
/// Gestos: toque = mostrar/ocultar · doble toque a los lados = ±10 s (se acumula)
/// · deslizar en horizontal = buscar · deslizar abajo = minimizar (o salir de
/// pantalla completa) · deslizar arriba = pantalla completa · pellizcar = rellenar.
struct PlayerControls: View {
    let engine: PlayerEngine
    let title: String
    let subtitle: String
    let problem: String?
    let landscape: Bool
    let safe: EdgeInsets
    let active: Bool
    let chatOpen: Bool
    let showsChatToggle: Bool
    let onMinimize: () -> Void
    let onFullscreen: () -> Void
    let onToggleChat: () -> Void
    let onRetry: () -> Void
    let onDrag: (CGFloat) -> Void
    let onDragEnd: (CGFloat, CGFloat) -> Void

    @State private var visible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var scrub: Double?
    @State private var panAxis: Axis?
    @State private var panOrigin: Double = 0
    @State private var jump: Jump?
    @State private var jumpTask: Task<Void, Never>?
    @State private var lastTap = Date.distantPast
    @State private var lastTapZone = 0

    private struct Jump: Equatable {
        var forward: Bool
        var seconds: Int
    }

    private var message: String? { problem ?? engine.error }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                gestureLayer(width: geo.size.width)

                if active {
                    chrome
                        .opacity(visible ? 1 : 0)
                        .allowsHitTesting(visible)

                    jumpIndicator(width: geo.size.width)
                        .allowsHitTesting(false)

                    if engine.skippingAd {
                        Label("Saltando anuncio…", systemImage: "forward.fill")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(.black.opacity(0.6), in: Capsule())
                            .frame(maxHeight: .infinity, alignment: .top)
                            .padding(.top, landscape ? max(safe.top, 12) + 44 : 48)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }

                    if let range = engine.currentMuted, message == nil, scrub == nil {
                        skipMutedButton(range)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                            .padding(.trailing, landscape ? max(safe.trailing, 16) : 12)
                            .padding(.bottom, landscape ? max(safe.bottom, 6) + 52 : 46)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }

                    if let message {
                        failure(message)
                    }
                }
            }
        }
        .animation(.easeOut(duration: 0.12), value: visible)
        .animation(.snappy, value: engine.currentMuted)
        .animation(.easeOut(duration: 0.2), value: engine.skippingAd)
        .sensoryFeedback(.impact(weight: .light), trigger: jump?.seconds)
        .onChange(of: engine.isPlaying) { _, playing in
            if playing { scheduleHide() } else { show(keep: true) }
        }
        .onAppear { scheduleHide() }
        .onChange(of: engine.demoScrub) { _, value in
            scrub = value
            if value != nil { show(keep: true) }
        }
    }

    // MARK: - Gestos

    private func gestureLayer(width: CGFloat) -> some View {
        Color.clear
            .contentShape(Rectangle())
            // Un solo reconocedor de toques: así no hay que esperar a descartar un doble toque
            .gesture(SpatialTapGesture().onEnded { tap(at: $0.location.x / max(width, 1)) })
            .simultaneousGesture(
                DragGesture(minimumDistance: 14, coordinateSpace: .global)
                    .onChanged { pan($0, width: width) }
                    .onEnded { endPan($0) }
            )
            .simultaneousGesture(
                MagnifyGesture().onEnded { value in
                    withAnimation(.snappy) { engine.fill = value.magnification > 1 }
                }
            )
    }

    /// El primer toque muestra/oculta los controles al instante. Si llega un segundo
    /// toque rápido en un lateral, se deshace eso y se salta 10 s; mientras se ve el
    /// indicador de salto, cada toque más en el mismo lado suma otros 10 s.
    private func tap(at x: CGFloat) {
        let zone = x < 0.38 ? -1 : x > 0.62 ? 1 : 0
        let now = Date()
        let isDouble = now.timeIntervalSince(lastTap) < 0.3 && zone == lastTapZone
        lastTap = isDouble ? .distantPast : now
        lastTapZone = zone

        if zone != 0, message == nil {
            let forward = zone > 0
            if jump?.forward == forward {
                seekJump(forward: forward)
                return
            }
            if isDouble {
                toggleVisible()
                seekJump(forward: forward)
                return
            }
        } else if zone == 0, isDouble, landscape {
            toggleVisible()
            withAnimation(.snappy) { engine.fill.toggle() }
            return
        }
        toggleVisible()
    }

    private func seekJump(forward: Bool) {
        if forward && engine.atLiveEdge { return }
        engine.skip(forward ? 10 : -10)
        let previous = jump?.forward == forward ? jump?.seconds ?? 0 : 0
        jump = Jump(forward: forward, seconds: previous + 10)
        jumpTask?.cancel()
        jumpTask = Task {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { jump = nil }
        }
    }

    private func pan(_ g: DragGesture.Value, width: CGFloat) {
        guard active || panAxis == .vertical else { return }
        if panAxis == nil {
            panAxis = abs(g.translation.width) > abs(g.translation.height) ? .horizontal : .vertical
            panOrigin = engine.position
        }
        switch panAxis {
        case .horizontal:
            guard engine.duration > 0, engine.canRewind, message == nil else { return }
            // Un barrido de lado a lado = 3 minutos (o el vídeo entero si es más corto)
            let span = min(engine.duration, 180)
            scrub = min(max(0, panOrigin + Double(g.translation.width / max(width, 1)) * span), engine.duration)
            show(keep: true)
        case .vertical:
            onDrag(g.translation.height)
        case nil:
            break
        }
    }

    private func endPan(_ g: DragGesture.Value) {
        switch panAxis {
        case .horizontal:
            if let scrub { engine.seek(to: scrub) }
            scrub = nil
            scheduleHide()
        case .vertical:
            onDragEnd(g.translation.height, g.predictedEndTranslation.height)
        case nil:
            break
        }
        panAxis = nil
    }

    // MARK: - Mostrar / ocultar

    private func toggleVisible() {
        if visible {
            hideTask?.cancel()
            visible = false
        } else {
            show()
        }
    }

    private func show(keep: Bool = false) {
        visible = true
        hideTask?.cancel()
        if !keep { scheduleHide() }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, engine.isPlaying, scrub == nil else { return }
            visible = false
        }
    }

    private func act(_ action: () -> Void) {
        action()
        show()
    }

    // MARK: - Controles

    private var chrome: some View {
        ZStack {
            LinearGradient(stops: [.init(color: .black.opacity(0.55), location: 0),
                                   .init(color: .black.opacity(0.15), location: 0.3),
                                   .init(color: .black.opacity(0.15), location: 0.6),
                                   .init(color: .black.opacity(0.7), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                bottomBar
            }
            .padding(.top, landscape ? max(safe.top, 10) : 2)
            .padding(.bottom, landscape ? max(safe.bottom, 6) : 0)
            .padding(.leading, landscape ? max(safe.leading, 12) : 4)
            .padding(.trailing, landscape && !chatOpen ? max(safe.trailing, 12) : 4)

            if message == nil {
                centerButtons
                    .opacity(scrub == nil ? 1 : 0)
                if let scrub, engine.storyboard == nil {
                    scrubReadout(scrub)
                }
            }
        }
        .foregroundStyle(.white)
        .buttonStyle(.plain)
    }

    private var topBar: some View {
        HStack(spacing: 4) {
            icon("chevron.down", label: landscape ? "Salir de pantalla completa" : "Minimizar") {
                landscape ? onFullscreen() : onMinimize()
            }
            if landscape {
                VStack(alignment: .leading, spacing: 1) {
                    Text(subtitle).font(.subheadline.weight(.semibold))
                    Text(title).font(.caption).foregroundStyle(.white.opacity(0.75))
                }
                .lineLimit(1)
                .padding(.leading, 4)
            }
            Spacer(minLength: 8)
            RoutePicker().frame(width: 40, height: 40)
            if engine.supportsPiP {
                icon("pip.enter", label: "Imagen dentro de imagen") { engine.togglePiP() }
            }
            SettingsMenu(engine: engine, landscape: landscape)
            if landscape && showsChatToggle {
                icon(chatOpen ? "bubble.left.fill" : "bubble.left", label: chatOpen ? "Ocultar chat" : "Mostrar chat") {
                    onToggleChat()
                }
            }
        }
    }

    private var centerButtons: some View {
        HStack(spacing: landscape ? 64 : 40) {
            skipButton(forward: false)
            Button { act { engine.togglePlay() } } label: {
                ZStack {
                    if engine.isBuffering {
                        ProgressView().controlSize(.large).tint(.white)
                    } else {
                        Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 30, weight: .semibold))
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .frame(width: 68, height: 68)
                .glassEffect(.regular.tint(.black.opacity(0.3)).interactive(), in: Circle())
            }
            .accessibilityLabel(engine.isPlaying ? "Pausa" : "Reproducir")
            skipButton(forward: true)
        }
    }

    private func skipButton(forward: Bool) -> some View {
        let disabled = forward ? engine.atLiveEdge : !engine.canRewind && engine.position < 1
        return Button { act { seekJump(forward: forward) } } label: {
            Image(systemName: forward ? "goforward.10" : "gobackward.10")
                .font(.system(size: 24, weight: .medium))
                .frame(width: 52, height: 52)
                .contentShape(Rectangle())
                .shadow(color: .black.opacity(0.4), radius: 4)
        }
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
        .accessibilityLabel(forward ? "Adelantar 10 segundos" : "Retroceder 10 segundos")
    }

    private var bottomBar: some View {
        let shown = scrub ?? engine.position
        return HStack(spacing: 10) {
            Text(Format.clock(shown))
                .frame(width: 62, alignment: .leading)
            Scrubber(value: shown, total: engine.duration, enabled: engine.canRewind && message == nil,
                     preview: scrub != nil && engine.storyboard != nil ? Scrubber.Preview(
                        image: engine.storyboard?.frame(at: shown), width: landscape ? 220 : 160) : nil,
                     marks: engine.muted) { value in
                scrub = value
                show(keep: true)
            } onEnded: { value in
                engine.seek(to: value)
                scrub = nil
                scheduleHide()
            }
            if engine.isLive {
                LivePill(atEdge: engine.atLiveEdge) { act { engine.goLive() } }
                    .frame(width: 78, alignment: .trailing)
            } else {
                Text(Format.clock(engine.duration))
                    .frame(width: 62, alignment: .trailing)
            }
            icon(landscape ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                 label: landscape ? "Salir de pantalla completa" : "Pantalla completa") { onFullscreen() }
        }
        .font(.caption.weight(.semibold))
        .monospacedDigit()
        .padding(.leading, 8)
    }


    private func icon(_ name: String, label: String, action: @escaping () -> Void) -> some View {
        Button { act(action) } label: {
            Image(systemName: name)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
                .shadow(color: .black.opacity(0.4), radius: 4)
        }
        .accessibilityLabel(label)
    }

    // MARK: - Indicadores

    /// Aparece solo mientras se está dentro de un tramo con el audio silenciado.
    private func skipMutedButton(_ range: Range<Double>) -> some View {
        Button {
            engine.seek(to: range.upperBound + 0.5)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "speaker.slash.fill")
                    .foregroundStyle(Scrubber.mutedColor)
                Text("Audio silenciado")
                    .foregroundStyle(.white.opacity(0.8))
                Text("Saltar")
                    .fontWeight(.semibold)
                Image(systemName: "forward.end.fill")
            }
            .font(.footnote)
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(.black.opacity(0.35)).interactive(), in: Capsule())
        .accessibilityLabel("Saltar el tramo con audio silenciado")
    }

    private func scrubReadout(_ value: Double) -> some View {
        VStack(spacing: 2) {
            Text(Format.clock(value))
                .font(.system(size: 32, weight: .semibold))
            if engine.isLive {
                let behind = engine.duration - value
                Text(behind < 15 ? "En vivo" : "−\(Format.clock(behind)) del directo")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
        .monospacedDigit()
        .shadow(color: .black.opacity(0.5), radius: 8)
        .allowsHitTesting(false)
    }

    private func jumpIndicator(width: CGFloat) -> some View {
        HStack {
            if let jump, !jump.forward { jumpBadge(jump) }
            Spacer()
            if let jump, jump.forward { jumpBadge(jump) }
        }
        .padding(.horizontal, width * 0.1)
        .animation(.snappy, value: jump)
    }

    private func jumpBadge(_ jump: Jump) -> some View {
        VStack(spacing: 4) {
            Image(systemName: jump.forward ? "forward.fill" : "backward.fill")
                .font(.system(size: 18, weight: .semibold))
            Text("\(jump.seconds) s")
                .font(.footnote.weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .foregroundStyle(.white)
        .frame(width: 76, height: 76)
        .background(.black.opacity(0.45), in: Circle())
        .transition(.scale(scale: 0.8).combined(with: .opacity))
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle").font(.title2)
            Text(message)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
            Button("Reintentar", action: onRetry)
                .buttonStyle(.bordered)
                .tint(.white)
        }
        .foregroundStyle(.white)
        .padding()
    }
}

/// Barra de progreso: fina en reposo, se ensancha al arrastrarla.
struct Scrubber: View {
    /// Miniatura que flota sobre el punto mientras se busca en un VOD.
    struct Preview {
        let image: UIImage?
        let width: CGFloat
    }

    let value: Double
    let total: Double
    var enabled = true
    var preview: Preview?
    /// Tramos marcados en la barra (audio silenciado).
    var marks: [Range<Double>] = []

    static let mutedColor = Color(red: 1, green: 0.72, blue: 0.25)
    let onChanged: (Double) -> Void
    let onEnded: (Double) -> Void

    @State private var dragging = false

    var body: some View {
        GeometryReader { geo in
            let fraction = total > 0 ? min(max(value / total, 0), 1) : 1
            let thumb: CGFloat = dragging ? 16 : 11
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25))
                    .frame(height: dragging ? 6 : 3)
                Capsule().fill(Color.glint)
                    .frame(width: geo.size.width * fraction, height: dragging ? 6 : 3)
                if total > 0 {
                    ForEach(marks, id: \.lowerBound) { mark in
                        let start = geo.size.width * min(1, mark.lowerBound / total)
                        let end = geo.size.width * min(1, mark.upperBound / total)
                        // Algo más gruesos que la barra y con un ancho mínimo, para verse aunque sean cortos
                        Capsule()
                            .fill(Self.mutedColor)
                            .frame(width: max(5, end - start), height: dragging ? 8 : 5)
                            .offset(x: start)
                    }
                }
                if enabled {
                    Circle().fill(.white)
                        .frame(width: thumb, height: thumb)
                        .shadow(color: .black.opacity(0.3), radius: 2)
                        .offset(x: geo.size.width * fraction - thumb / 2)
                }
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .overlay(alignment: .bottomLeading) {
                if let preview {
                    // Centrada sobre el punto; puede asomar un poco por los lados de la barra
                    let x = min(max(geo.size.width * fraction - preview.width / 2, -70), geo.size.width - preview.width + 70)
                    bubble(preview)
                        .offset(x: x, y: -26)
                        .allowsHitTesting(false)
                        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottom)))
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        guard enabled else { return }
                        dragging = true
                        onChanged(position(g.location.x, width: geo.size.width))
                    }
                    .onEnded { g in
                        guard enabled else { return }
                        dragging = false
                        onEnded(position(g.location.x, width: geo.size.width))
                    }
            )
        }
        .frame(height: 30)
        .animation(.easeOut(duration: 0.15), value: dragging)
        .sensoryFeedback(.selection, trigger: dragging)
        .accessibilityElement()
        .accessibilityLabel("Posición")
        .accessibilityValue(Format.clock(value))
    }

    private func position(_ x: CGFloat, width: CGFloat) -> Double {
        Double(min(max(x / max(width, 1), 0), 1)) * total
    }

    private func bubble(_ preview: Preview) -> some View {
        VStack(spacing: 6) {
            Color.black
                .frame(width: preview.width, height: preview.width * 9 / 16)
                .overlay {
                    if let image = preview.image {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        ProgressView().tint(.white)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.9), lineWidth: 1.5))
                .shadow(color: .black.opacity(0.5), radius: 10)
            Text(Format.clock(value))
                .font(.footnote.weight(.semibold))
                .monospacedDigit()
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.black.opacity(0.7), in: Capsule())
        }
        .frame(width: preview.width)
    }
}

/// "EN VIVO": rojo cuando estás al día; gris y pulsable cuando vas por detrás.
struct LivePill: View {
    let atEdge: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Circle().fill(atEdge ? Color.live : .white.opacity(0.5)).frame(width: 7, height: 7)
                Text("EN VIVO")
                    .foregroundStyle(Color.white.opacity(atEdge ? 1 : 0.7))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.white.opacity(atEdge ? 0 : 0.15), in: Capsule())
        }
        .disabled(atEdge)
        .accessibilityLabel(atEdge ? "En vivo" : "Ir al directo")
    }
}

/// Calidad, velocidad y relleno. Va en su propia vista para que no se redibuje con
/// cada tic del reproductor: si no, el menú abierto se refresca y no deja hacer scroll.
private struct SettingsMenu: View {
    let engine: PlayerEngine
    let landscape: Bool

    var body: some View {
        Menu {
            Picker(selection: Binding(get: { engine.quality ?? "" }, set: { engine.setQuality($0.isEmpty ? nil : $0) })) {
                Text("Automática").tag("")
                ForEach(engine.qualities) { Text($0.label).tag($0.name) }
            } label: {
                Label("Calidad", systemImage: "slider.horizontal.3")
            }
            if engine.mode != .live {
                Picker(selection: Binding(get: { engine.rate }, set: { engine.setRate($0) })) {
                    ForEach([0.5, 0.75, 1, 1.25, 1.5, 2] as [Float], id: \.self) { rate in
                        Text(rate == 1 ? "Normal" : "\(rate.formatted(.number.locale(Locale(identifier: "es"))))×").tag(rate)
                    }
                } label: {
                    Label("Velocidad", systemImage: "gauge.with.dots.needle.67percent")
                }
            }
            if landscape {
                Toggle(isOn: Binding(get: { engine.fill }, set: { value in withAnimation { engine.fill = value } })) {
                    Label("Rellenar pantalla", systemImage: "arrow.up.left.and.arrow.down.right.rectangle")
                }
            }
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
                .shadow(color: .black.opacity(0.4), radius: 4)
        }
        .accessibilityLabel("Ajustes de reproducción")
        .menuOrder(.fixed)
    }
}
