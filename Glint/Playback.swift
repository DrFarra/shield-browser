import Observation
import SwiftUI

/// Lo que se está viendo: carga la información del canal o del vídeo, arranca
/// el reproductor y el chat, y sabe si el reproductor está minimizado.
@MainActor @Observable
final class Playback {
    enum Media: Equatable {
        case live(String)
        case video(String)
    }

    private(set) var media: Media?
    var minimized = false
    private(set) var channel: Twitch.Channel?
    private(set) var video: Twitch.Video?
    private(set) var problem: String?
    let engine = PlayerEngine()
    let chat = ChatClient()

    @ObservationIgnored private var task: Task<Void, Never>?

    var login: String? {
        switch media {
        case .live(let login): login
        case .video: video?.owner?.login
        case nil: nil
        }
    }

    func play(_ media: Media) {
        if self.media == media {
            withAnimation(.snappy) { minimized = false }
            return
        }
        stop()
        problem = nil
        withAnimation(.snappy) {
            self.media = media
            minimized = false
        }
        task = Task { await start(media) }
    }

    func close() {
        stop()
        withAnimation(.snappy) { media = nil }
    }

    func retry() {
        guard let media else { return }
        if engine.error != nil, problem == nil {
            engine.retry()
        } else {
            stop()
            problem = nil
            self.media = media
            task = Task { await start(media) }
        }
    }

    private func stop() {
        task?.cancel()
        engine.stop()
        chat.disconnect()
        channel = nil
        video = nil
    }

    private func start(_ media: Media) async {
        do {
            switch media {
            case .live(let login):
                chat.connect(login)
                guard let channel = try await Twitch.channel(login) else {
                    problem = "Este canal no existe"
                    return
                }
                self.channel = channel
                guard let stream = channel.stream else {
                    problem = "\(channel.name) no está en directo ahora"
                    return
                }
                engine.startLive(login: login, startedAt: stream.createdAt, archiveID: stream.archiveVideo?.id)
                // Espectadores, título y categoría al día
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(60))
                    if let fresh = try? await Twitch.channel(login), fresh.stream != nil {
                        self.channel = fresh
                        engine.updateArchive(fresh.stream?.archiveVideo?.id)
                    }
                }
            case .video(let id):
                guard let video = try await Twitch.video(id) else {
                    problem = "Este vídeo ya no existe"
                    return
                }
                self.video = video
                engine.startVOD(id: id, length: Double(video.lengthSeconds ?? 0))
            }
        } catch is CancellationError {
        } catch {
            problem = error.localizedDescription
        }
    }
}
