import CoreAudio
import SwiftUI

extension AudioOutputs.Device.Kind {
    var symbol: String {
        switch self {
        case .builtIn:    return "speaker.wave.2.fill"
        case .headphones: return "headphones"
        case .display:    return "display"
        case .airPlay:    return "airplayaudio"
        case .usb:        return "hifispeaker.fill"
        case .other:      return "speaker.wave.2"
        }
    }
}

/// The speaker cell: what is playing through, and how loud.
struct SoundCell: View {
    let state: AudioOutputs.State

    private var volumeText: String {
        state.volume.map { "\(Int(($0 * 100).rounded()))" } ?? "—"
    }

    var body: some View {
        VStack(spacing: NotchLayout.ringLabelGap) {
            ZStack {
                Circle()
                    .strokeBorder(Palette.ringTrack, lineWidth: Design.px(6))
                // The volume drawn the way the rings draw usage.
                if let volume = state.volume {
                    Circle()
                        .trim(from: 0, to: CGFloat(volume))
                        .stroke(Palette.textPrimary, style: StrokeStyle(lineWidth: Design.px(6), lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .padding(Design.px(3))
                }
                // In a call the cell is about the microphone: that is the
                // thing you might need to reach for in a hurry.
                if let microphone = state.microphone, microphone.isInUse {
                    Image(systemName: microphone.isMuted == true ? "mic.slash.fill" : "mic.fill")
                        .font(.system(size: NotchLayout.ringDiameter * 0.3, weight: .semibold))
                        .foregroundStyle(microphone.isMuted == true ? Palette.critical : Palette.ample)
                } else {
                    Image(systemName: state.currentDevice?.kind.symbol ?? "speaker.slash")
                        .font(.system(size: NotchLayout.ringDiameter * 0.3, weight: .semibold))
                        .foregroundStyle(Palette.textPrimary)
                }
            }
            .frame(width: NotchLayout.ringDiameter, height: NotchLayout.ringDiameter)

            Text(volumeText)
                .font(Typography.percent)
                .foregroundStyle(Palette.textPrimary)
                .frame(height: NotchLayout.percentLineHeight)
                .contentTransition(.numericText())
        }
        .frame(height: NotchLayout.cellExtent)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.t("Sound output"))
    }
}

/// The outputs to choose from, and the volume of the one in use.
struct SoundCard: View {
    let state: AudioOutputs.State
    var players: [NowPlaying] = []
    var onMedia: (NowPlaying, NowPlaying.Command) -> Void = { _, _ in }
    let direction: NotchEdge.TooltipDirection
    var tailOffset: CGFloat = 0
    let onSelect: (AudioDeviceID) -> Void
    let onVolume: (Float) -> Void
    var onMute: (Bool) -> Void = { _ in }
    var apps: [AppVolumeRow] = []
    var onAppVolume: (String, Float) -> Void = { _, _ in }

    @Environment(\.codenotchReduceTransparency) private var reduceTransparency
    @Environment(\.notchSurfaceStyle) private var surfaceStyle
    @Environment(\.colorScheme) private var colorScheme

    static let maxRows = 6
    static let headerHeight: CGFloat = Design.px(64)
    static let rowHeight: CGFloat = Design.px(64)
    static let volumeHeight: CGFloat = Design.px(84)
    static let playerHeight: CGFloat = Design.px(132)
    static let playersGap: CGFloat = Design.px(20)
    static let microphoneHeight: CGFloat = Design.px(72)
    static let appsHeaderHeight: CGFloat = Design.px(56)
    static let appRowHeight: CGFloat = Design.px(60)

    /// The microphone row is always there: muting is wanted in a hurry, and a
    /// row that appears only once a call has started moves under the pointer.
    static func height(deviceCount: Int, playerCount: Int = 0, appCount: Int = 0) -> CGFloat {
        let players = playerCount > 0 ? CGFloat(playerCount) * playerHeight + playersGap : 0
        let apps = appCount > 0 ? appsHeaderHeight + CGFloat(appCount) * appRowHeight : 0
        return 2 * NotchLayout.cardPadding + players + headerHeight
            + CGFloat(min(max(deviceCount, 1), maxRows)) * rowHeight + volumeHeight + microphoneHeight
            + apps
    }

    /// Everything at its fullest: what the panel reserves room for.
    static var maxHeight: CGFloat {
        height(deviceCount: maxRows, playerCount: 2, appCount: AppVolumeRow.maxRows)
    }

    private var cardHeight: CGFloat {
        Self.height(deviceCount: state.devices.count, playerCount: players.count, appCount: apps.count)
    }
    private var glassy: Bool { surfaceStyle.isGlass && !reduceTransparency }
    private var secondaryInk: Color {
        TooltipGlassContrast.secondaryInk(surfaceStyle: surfaceStyle, colorScheme: colorScheme,
                                          reduceTransparency: reduceTransparency)
    }
    /// Clear on glass, for the reason `UsageResetCard` gives.
    private var surfaceFill: Color { glassy ? .clear : Palette.card }

    private var clampedTailOffset: CGFloat {
        let size = TooltipTail.size(for: direction)
        switch direction {
        case .leading, .trailing:
            let maxOffset = max(0, (cardHeight / 2) - NotchLayout.cardCorner - (size.height / 2))
            return min(max(tailOffset, -maxOffset), maxOffset)
        case .up, .down:
            let maxOffset = max(0, (NotchLayout.cardWidth / 2) - NotchLayout.cardCorner - (size.width / 2))
            return min(max(tailOffset, -maxOffset), maxOffset)
        }
    }

    var body: some View {
        stack
            .background {
                if glassy {
                    if #available(macOS 26.0, *) {
                        Color.clear
                            .glassEffect(surfaceStyle.glass, in: TooltipSilhouette(direction: direction, tailOffset: clampedTailOffset))
                            .background {
                                if let dim = TooltipGlassContrast.dim(surfaceStyle: surfaceStyle,
                                                                      colorScheme: colorScheme,
                                                                      reduceTransparency: reduceTransparency) {
                                    TooltipSilhouette(direction: direction, tailOffset: clampedTailOffset).fill(dim)
                                }
                            }
                    }
                }
            }
    }

    private var card: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: NotchLayout.cardCorner, style: .circular)
                .fill(surfaceFill)
                .frame(width: NotchLayout.cardWidth, height: cardHeight)

            VStack(alignment: .leading, spacing: 0) {
                if !players.isEmpty {
                    ForEach(players) { player in
                        playerRow(player)
                            .frame(height: Self.playerHeight, alignment: .topLeading)
                    }
                    Rectangle()
                        .fill(Palette.ringTrack)
                        .frame(height: 1)
                        .frame(height: Self.playersGap, alignment: .top)
                }

                Text(L10n.t("Sound output"))
                    .font(Typography.cardTitle)
                    .foregroundStyle(Palette.textPrimary)
                    .frame(height: Self.headerHeight, alignment: .top)

                if state.devices.isEmpty {
                    Text(L10n.t("No output device."))
                        .font(Typography.cardBody)
                        .foregroundStyle(secondaryInk)
                        .frame(height: Self.rowHeight, alignment: .topLeading)
                }
                ForEach(state.devices.prefix(Self.maxRows)) { device in
                    let isCurrent = device.id == state.current
                    HStack(spacing: Design.px(16)) {
                        Image(systemName: device.kind.symbol)
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: Design.px(36))
                            .foregroundStyle(isCurrent ? Palette.textPrimary : secondaryInk)
                        Text(device.name)
                            .font(Typography.cardBody.weight(isCurrent ? .semibold : .regular))
                            .foregroundStyle(isCurrent ? Palette.textPrimary : secondaryInk)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if isCurrent {
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Palette.ample)
                        }
                    }
                    .frame(height: Self.rowHeight)
                    .contentShape(Rectangle())
                    .onTapGesture { onSelect(device.id) }
                }

                HStack(spacing: Design.px(16)) {
                    Image(systemName: "speaker.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(secondaryInk)
                    if let volume = state.volume {
                        Slider(value: Binding(get: { Double(volume) },
                                              set: { onVolume(Float($0)) }),
                               in: 0...1)
                            .controlSize(.small)
                        Text("\(Int((volume * 100).rounded()))%")
                            .font(Typography.cardBody.monospacedDigit())
                            .foregroundStyle(Palette.textPrimary)
                            .frame(width: Design.px(90), alignment: .trailing)
                    } else {
                        Text(L10n.t("This output has no volume of its own."))
                            .font(Typography.cardBody)
                            .foregroundStyle(secondaryInk)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
                .frame(height: Self.volumeHeight)

                microphoneRow
                    .frame(height: Self.microphoneHeight)

                if !apps.isEmpty {
                    Text(L10n.t("Apps"))
                        .font(Typography.cardTitle)
                        .foregroundStyle(Palette.textPrimary)
                        .frame(height: Self.appsHeaderHeight, alignment: .bottomLeading)
                    ForEach(apps) { app in
                        HStack(spacing: Design.px(16)) {
                            Circle()
                                .fill(app.isPlaying ? Palette.ample : Color.clear)
                                .frame(width: Design.px(12), height: Design.px(12))
                            Text(app.name)
                                .font(Typography.cardBody)
                                .foregroundStyle(Palette.textPrimary)
                                .lineLimit(1)
                                .frame(width: Design.px(170), alignment: .leading)
                            Slider(value: Binding(get: { Double(app.level) },
                                                  set: { onAppVolume(app.bundleID, Float($0)) }),
                                   in: 0...1)
                                .controlSize(.small)
                            Text("\(Int((app.level * 100).rounded()))%")
                                .font(Typography.cardBody.monospacedDigit())
                                .foregroundStyle(app.level < 0.99 ? Palette.watch : secondaryInk)
                                .frame(width: Design.px(90), alignment: .trailing)
                        }
                        .frame(height: Self.appRowHeight)
                    }
                }
            }
            .padding(NotchLayout.cardPadding)
            .frame(width: NotchLayout.cardWidth, height: cardHeight, alignment: .topLeading)
        }
        .frame(width: NotchLayout.cardWidth, height: cardHeight, alignment: .top)
        .clipShape(RoundedRectangle(cornerRadius: NotchLayout.cardCorner, style: .circular))
        .overlay {
            if reduceTransparency {
                RoundedRectangle(cornerRadius: NotchLayout.cardCorner, style: .circular)
                    .strokeBorder(Palette.ringTrack, lineWidth: 1)
            }
        }
    }

    @ViewBuilder private var microphoneRow: some View {
        if let microphone = state.microphone {
            let muted = microphone.isMuted == true
            HStack(spacing: Design.px(16)) {
                Image(systemName: muted ? "mic.slash.fill" : "mic.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: Design.px(36))
                    .foregroundStyle(muted ? Palette.critical : (microphone.isInUse ? Palette.ample : secondaryInk))
                VStack(alignment: .leading, spacing: 0) {
                    Text(microphone.name)
                        .font(Typography.cardBody)
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(1)
                    if microphone.isInUse {
                        Text(L10n.t("In use — in a call"))
                            .font(Typography.cardBody)
                            .foregroundStyle(Palette.ample)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if microphone.isMuted != nil {
                    Button { onMute(!muted) } label: {
                        Text(muted ? L10n.t("Unmute") : L10n.t("Mute"))
                            .font(Typography.cardBody.weight(.semibold))
                            .foregroundStyle(muted ? Color.white : Palette.textPrimary)
                            .padding(.horizontal, Design.px(20))
                            .padding(.vertical, Design.px(8))
                            .background(Capsule().fill(muted ? Palette.critical : Palette.ringTrack))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// One player: what it is playing, and its three buttons.
    private func playerRow(_ player: NowPlaying) -> some View {
        VStack(alignment: .leading, spacing: Design.px(10)) {
            HStack(spacing: Design.px(12)) {
                Image(systemName: player.source == .spotify ? "music.note" : "play.rectangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(player.source == .spotify ? Palette.ample : Palette.critical)
                Text(player.source == .spotify ? "Spotify" : "YouTube")
                    .font(Typography.cardBody)
                    .foregroundStyle(secondaryInk)
                Spacer(minLength: 0)
                ForEach([NowPlaying.Command.previous, .toggle, .next], id: \.self) { command in
                    Button { onMedia(player, command) } label: {
                        Image(systemName: symbol(command, isPlaying: player.isPlaying))
                            .font(.system(size: command == .toggle ? 15 : 12, weight: .bold))
                            .foregroundStyle(Palette.textPrimary)
                            .frame(width: Design.px(56), height: Design.px(48))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!player.isControllable)
                    .opacity(player.isControllable ? 1 : 0.35)
                }
            }
            Text(player.title)
                .font(Typography.cardBody.weight(.semibold))
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
            if !player.isControllable {
                Text(L10n.t("To control it, allow JavaScript from Apple Events in Chrome (View › Developer)."))
                    .font(Typography.cardBody)
                    .foregroundStyle(secondaryInk)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            } else if let subtitle = player.subtitle {
                Text(subtitle)
                    .font(Typography.cardBody)
                    .foregroundStyle(secondaryInk)
                    .lineLimit(1)
            }
        }
    }

    private func symbol(_ command: NowPlaying.Command, isPlaying: Bool) -> String {
        switch command {
        case .previous: return "backward.fill"
        case .toggle:   return isPlaying ? "pause.fill" : "play.fill"
        case .next:     return "forward.fill"
        }
    }

    private var tail: some View {
        let size = TooltipTail.size(for: direction)
        return TooltipTail(direction: direction)
            .fill(surfaceFill)
            .frame(width: size.width, height: size.height)
            .offset(x: direction == .up || direction == .down ? clampedTailOffset : 0,
                    y: direction == .leading || direction == .trailing ? clampedTailOffset : 0)
    }

    @ViewBuilder private var stack: some View {
        switch direction {
        case .leading:
            HStack(spacing: 0) { card; tail }
        case .trailing:
            HStack(spacing: 0) { tail; card }
        case .down:
            VStack(spacing: 0) { tail; card }
        case .up:
            VStack(spacing: 0) { card; tail }
        }
    }
}
