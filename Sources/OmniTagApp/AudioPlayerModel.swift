import AVFoundation
import Foundation
import Observation

/// Native audio player for verifying narration, audio quality, and chapter marks.
///
/// Wraps `AVPlayer` with an observable 100ms periodic time observer, supporting
/// .m4b, .m4a, .mp3, .wav, .aiff, and .flac with zero third-party dependencies.
@Observable
@MainActor
final class AudioPlayerModel {
    var currentURL: URL?
    var isPlaying = false
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var itemEndObserver: NSObjectProtocol?

    init() {}

    var progress: Double {
        get {
            guard duration > 0 else { return 0 }
            return currentTime / duration
        }
        set {
            guard duration > 0 else { return }
            seek(to: newValue * duration)
        }
    }

    var formattedCurrentTime: String {
        Self.format(currentTime)
    }

    var formattedDuration: String {
        Self.format(duration)
    }

    func load(url: URL) {
        guard currentURL != url else { return }
        stop()

        currentURL = url
        let asset = AVURLAsset(url: url)
        let playerItem = AVPlayerItem(asset: asset)
        let newPlayer = AVPlayer(playerItem: playerItem)
        player = newPlayer

        Task { [weak self] in
            guard let self else { return }
            if let dur = try? await asset.load(.duration), dur.isNumeric, currentURL == url {
                duration = dur.seconds
            }
        }

        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserver = newPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor in
                if time.isNumeric {
                    self?.currentTime = time.seconds
                }
            }
        }

        itemEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isPlaying = false
                self?.seek(to: 0)
            }
        }
    }

    func togglePlayPause() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }

    func seek(to seconds: TimeInterval) {
        let clamped = max(0, min(seconds, duration))
        currentTime = clamped
        let target = CMTime(seconds: clamped, preferredTimescale: 600)
        player?.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func jump(by seconds: TimeInterval) {
        seek(to: currentTime + seconds)
    }

    func stop() {
        if let timeObserver {
            player?.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        if let itemEndObserver {
            NotificationCenter.default.removeObserver(itemEndObserver)
            self.itemEndObserver = nil
        }
        player?.pause()
        player = nil
        currentURL = nil
        isPlaying = false
        currentTime = 0
        duration = 0
    }

    static func format(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        return Duration.seconds(seconds).formatted(.time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }
}
