import Foundation
import PlaybackCore
import SubtitleCore
import Testing
@testable import MPVPlayer

/// Plays the repository's fixture clip through real libmpv, headless.
@MainActor
@Suite(.serialized)
struct MPVPlayerTests {
    nonisolated static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appending(path: "../../../../Fixtures")
        .standardizedFileURL
    /// 119 frames of testsrc2 at 24000/1001 fps, timestamps in 1/24000 s.
    nonisolated static let fixture = fixtures.appending(path: "testsrc-23.976.mp4")
    /// The same frames in Matroska, whose timestamps are rounded to the millisecond.
    nonisolated static let matroskaFixture = fixtures.appending(path: "testsrc-23.976.mkv")

    func makeLoadedPlayer(_ media: URL = fixture) async throws -> MPVPlayer {
        let player = try MPVPlayer(configuration: .init(showsVideo: false, playsAudio: false, usesHardwareDecoding: false))
        player.load(media)
        try await waitUntil(player) { $0.hasMedia && $0.frameRate != nil && $0.duration != nil }
        return player
    }

    func waitUntil(
        _ player: MPVPlayer,
        timeout: Duration = .seconds(10),
        _ condition: (PlaybackStatus) -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition(player.status) {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out; status is \(player.status)")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func frame(_ player: MPVPlayer) -> Int64 {
        player.status.position.nearestFrame(at: player.status.frameRate!)
    }

    @Test func loadsPausedOnTheFirstFrameWithTheExactRate() async throws {
        let player = try await makeLoadedPlayer()
        #expect(player.status.frameRate == .fps23_976)
        #expect(player.status.isPaused)
        #expect(frame(player) == 0)
        #expect(player.status.mediaURL == Self.fixture)
    }

    @Test func reportsTheAudioStreamBeingPlayed() async throws {
        let player = try await makeLoadedPlayer(Self.fixtures.appending(path: "dialogue-5.1.mp4"))
        try await waitUntil(player) { $0.audioStreamIndex != nil }
        #expect(player.status.audioStreamIndex == 1)
    }

    @Test func playsAudioThroughAnOutputDevice() async throws {
        let player = try MPVPlayer(configuration: .init(showsVideo: false, usesHardwareDecoding: false))
        player.load(Self.fixtures.appending(path: "dialogue-5.1.mp4"))
        try await waitUntil(player) { $0.hasMedia }
        player.play(rate: 1)
        let deadline = ContinuousClock.now + .seconds(5)
        while player.handle.string("current-ao") == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        player.setPaused(true)
        #expect(player.handle.string("current-ao") == "avfoundation")
        #expect(player.status.selectedAudioTrackID == 1)
    }

    @Test func listsAndSwitchesAudioTracks() async throws {
        let player = try await makeLoadedPlayer(Self.fixtures.appending(path: "two-tracks.mkv"))
        try await waitUntil(player) { $0.audioTracks.count == 2 && $0.selectedAudioTrackID != nil }
        let tracks = player.status.audioTracks
        #expect(tracks.map(\.language) == ["eng", "ara"])
        #expect(tracks.map(\.title) == ["Original", "Arabic dub"])
        #expect(tracks.map(\.channelCount) == [2, 6])
        #expect(tracks.map(\.streamIndex) == [1, 2])
        #expect(player.status.selectedAudioTrackID == tracks[0].id)
        #expect(player.status.audioStreamIndex == 1)

        player.selectAudioTrack(id: tracks[1].id)
        try await waitUntil(player) { $0.selectedAudioTrackID == tracks[1].id && $0.audioStreamIndex == 2 }
    }

    @Test func neverShowsTheMediasOwnSubtitles() async throws {
        let player = try await makeLoadedPlayer(Self.fixtures.appending(path: "embedded-subs.mkv"))
        let subtitleTracks = (0..<(player.handle.string("track-list/count").flatMap(Int.init) ?? 0)).filter {
            player.handle.string("track-list/\($0)/type") == "sub"
        }
        #expect(subtitleTracks.count == 4)
        expectNoSubtitles(player)
    }

    @Test func neverLoadsSubtitleFilesNextToTheMediaOrShowsSubtitlesAfterReopening() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "MPVPlayerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let media = directory.appending(path: "movie.mkv")
        try FileManager.default.copyItem(at: Self.fixtures.appending(path: "embedded-subs.mkv"), to: media)
        for name in ["movie.srt", "movie.en.srt"] {
            try FileManager.default.copyItem(at: Self.fixtures.appending(path: "testsrc-23.976.srt"), to: directory.appending(path: name))
        }
        let player = try await makeLoadedPlayer(Self.fixture)
        player.load(media)
        try await waitUntil(player) { $0.mediaURL == media && $0.frameRate != nil }
        #expect(subtitleTrackCount(player) == 4, "Only the file's own tracks, no external files")
        expectNoSubtitles(player)
        player.step(by: 30)
        try await waitUntil(player) { $0.position.nearestFrame(at: .fps23_976) == 30 }
        player.load(media)
        try await waitUntil(player) { $0.mediaURL == media && $0.position.nearestFrame(at: .fps23_976) == 0 }
        expectNoSubtitles(player)
    }

    func subtitleTrackCount(_ player: MPVPlayer) -> Int {
        (0..<(player.handle.string("track-list/count").flatMap(Int.init) ?? 0)).filter {
            player.handle.string("track-list/\($0)/type") == "sub"
        }.count
    }

    func expectNoSubtitles(_ player: MPVPlayer, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(player.handle.string("sid") == "no", sourceLocation: sourceLocation)
        #expect(player.handle.string("secondary-sid") == "no", sourceLocation: sourceLocation)
        #expect(player.handle.string("current-tracks/sub/id") == nil, sourceLocation: sourceLocation)
        #expect(player.handle.string("sub-visibility") == "no", sourceLocation: sourceLocation)
        #expect(player.handle.string("osd-level") == "0", sourceLocation: sourceLocation)
    }

    @Test func playsBackward() async throws {
        let player = try await makeLoadedPlayer()
        player.seek(toFrame: 100, rate: .fps23_976)
        try await waitUntil(player) { $0.position.nearestFrame(at: .fps23_976) == 100 }
        player.play(rate: -2)
        #expect(player.status.rate == -2)
        try await waitUntil(player) { $0.position.nearestFrame(at: .fps23_976) < 80 }
        player.setPaused(true)
        player.play(rate: 1)
        #expect(player.status.rate == 1)
        let from = frame(player)
        try await waitUntil(player) { $0.position.nearestFrame(at: .fps23_976) > from + 3 }
    }

    @Test func seeksLandOnTheExactFrame() async throws {
        let player = try await makeLoadedPlayer()
        for target: Int64 in [57, 1, 118, 24] {
            player.seek(toFrame: target, rate: .fps23_976)
            try await waitUntil(player) { $0.position.nearestFrame(at: .fps23_976) == target }
        }
    }

    @Test(arguments: [fixture, matroskaFixture])
    func everyFrameIsReachableBySeeking(media: URL) async throws {
        let player = try await makeLoadedPlayer(media)
        for target in Int64(0)..<119 {
            player.seek(toFrame: target, rate: .fps23_976)
            try await waitUntil(player) { $0.position.nearestFrame(at: .fps23_976) == target }
        }
    }

    @Test func rapidStepsAddUp() async throws {
        let player = try await makeLoadedPlayer()
        for _ in 0..<10 { player.step(by: 1) }
        try await waitUntil(player) { $0.position.nearestFrame(at: .fps23_976) == 10 }
        for _ in 0..<3 { player.step(by: -1) }
        try await waitUntil(player) { $0.position.nearestFrame(at: .fps23_976) == 7 }
        #expect(player.status.isPaused)
    }

    @Test func seeksPastTheEndStopOnTheLastFrame() async throws {
        let player = try await makeLoadedPlayer()
        player.seek(toFrame: 10_000, rate: .fps23_976)
        try await waitUntil(player) { $0.position.nearestFrame(at: .fps23_976) >= 118 }
        #expect(frame(player) <= 119)
    }

    @Test func playingAdvancesTime() async throws {
        let player = try await makeLoadedPlayer()
        player.setPaused(false)
        try await waitUntil(player) { !$0.isPaused && $0.position.nearestFrame(at: .fps23_976) > 5 }
        player.setPaused(true)
        try await waitUntil(player) { $0.isPaused }
    }
}
