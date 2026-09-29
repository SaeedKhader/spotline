import CFFmpeg
import Foundation
import SubtitleCore
import SubtitleFormats

/// A subtitle stream muxed into a media file, e.g. an SRT or PGS track in an MKV.
public struct EmbeddedSubtitleTrack: Identifiable, Hashable, Sendable {
    public var id: Int { streamIndex }
    /// FFmpeg's stream index.
    public var streamIndex: Int
    /// FFmpeg's codec name, e.g. "subrip", "ass", "mov_text" or "hdmv_pgs_subtitle".
    public var codec: String
    /// ISO 639 or BCP 47 language code from the file, e.g. "eng".
    public var language: String?
    public var title: String?
    public var isDefault: Bool
    public var isForced: Bool
    public var isHearingImpaired: Bool
    /// False for image-based tracks (PGS, VobSub, DVB), which cannot be read as text.
    public var isText: Bool

    public init(
        streamIndex: Int, codec: String, language: String? = nil, title: String? = nil, isDefault: Bool = false,
        isForced: Bool = false, isHearingImpaired: Bool = false, isText: Bool = true
    ) {
        self.streamIndex = streamIndex
        self.codec = codec
        self.language = language
        self.title = title
        self.isDefault = isDefault
        self.isForced = isForced
        self.isHearingImpaired = isHearingImpaired
        self.isText = isText
    }

    /// The codec as people know it, e.g. "SubRip" or "PGS".
    public var formatName: String {
        switch codec {
        case "subrip", "srt": "SubRip"
        case "ass": "ASS"
        case "ssa": "SSA"
        case "webvtt": "WebVTT"
        case "mov_text": "MP4 Timed Text"
        case "hdmv_pgs_subtitle": "PGS"
        case "dvd_subtitle": "VobSub"
        case "dvb_subtitle": "DVB"
        case "eia_608": "CEA-608"
        default: codec
        }
    }

    /// E.g. "English · SDH · Forced", or "Track 3" when the file says nothing.
    public var displayName: String {
        var parts: [String] = []
        if let language, language != "und" {
            parts.append(Locale.current.localizedString(forLanguageCode: language) ?? language)
        }
        if let title, !title.isEmpty, !parts.contains(title) { parts.append(title) }
        if isHearingImpaired { parts.append("SDH") }
        if isForced { parts.append("Forced") }
        return parts.isEmpty ? "Track \(streamIndex)" : parts.joined(separator: " · ")
    }

    /// The file format that keeps the most of this track, nil for image-based tracks.
    public var fileFormat: SubtitleFormat? {
        guard isText else { return nil }
        switch codec {
        case "ass": return .ass
        case "ssa": return .ssa
        case "webvtt": return .webVTT
        default: return .srt
        }
    }
}

extension MediaAnalyzer {
    /// The subtitle streams of a media file, in file order.
    public static func subtitleTracks(in url: URL) throws -> [EmbeddedSubtitleTrack] {
        let file = try MediaFile(url)
        return file.streams.enumerated().compactMap { index, stream in
            guard let stream, let parameters = stream.pointee.codecpar,
                  parameters.pointee.codec_type == AVMEDIA_TYPE_SUBTITLE
            else { return nil }
            let descriptor = avcodec_descriptor_get(parameters.pointee.codec_id)
            let disposition = stream.pointee.disposition
            func tag(_ key: String) -> String? {
                av_dict_get(stream.pointee.metadata, key, nil, 0).map { String(cString: $0.pointee.value) }
            }
            return EmbeddedSubtitleTrack(
                streamIndex: index,
                codec: descriptor.map { String(cString: $0.pointee.name) } ?? "unknown",
                language: tag("language"),
                title: tag("title"),
                isDefault: disposition & AV_DISPOSITION_DEFAULT != 0,
                isForced: disposition & AV_DISPOSITION_FORCED != 0,
                isHearingImpaired: disposition & AV_DISPOSITION_HEARING_IMPAIRED != 0,
                isText: (descriptor?.pointee.props ?? 0) & AV_CODEC_PROP_TEXT_SUB != 0
            )
        }
    }

    /// The cues of a text subtitle stream, timed like the player's clock
    /// (from the start of the media). `progress` reports how many cues were
    /// read so far and returns false to cancel.
    ///
    /// SubRip and WebVTT cue text is kept as written. ASS keeps its styles and
    /// header. Other text codecs (MP4 timed text) go through FFmpeg's decoder,
    /// whose ASS markup becomes Spotline's, and give plain cues.
    public static func subtitles(
        in url: URL,
        streamIndex: Int,
        options: Options = Options(),
        progress: (Progress<Int>) -> Bool = { _ in true }
    ) throws -> SubtitleTrack {
        let file = try MediaFile(url)
        guard file.streams.indices.contains(streamIndex), let stream = file.streams[streamIndex],
              stream.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_SUBTITLE
        else { throw Error.noStream }
        let reader = try SubtitleStreamReader(stream: stream, startTime: file.startTime)
        _ = try file.read(stream: Int32(streamIndex), options: options, progress: progress, decode: reader.read) {
            reader.count
        }
        var track = try reader.track()
        if let language = av_dict_get(stream.pointee.metadata, "language", nil, 0).map({ String(cString: $0.pointee.value) }) {
            track.languageCode = Locale.LanguageCode(language).identifier(.alpha2) ?? language
        }
        return track
    }
}

extension MediaFile {
    /// Where the player's clock starts: mpv counts from the container's start time.
    var startTime: MediaTime {
        let start = format.pointee.start_time
        return start == Int64.min ? .zero : MediaTime(value: start, timescale: Int64(AV_TIME_BASE))
    }
}

/// Collects the events of one text subtitle stream.
final class SubtitleStreamReader {
    private enum Kind {
        /// SubRip and WebVTT: the packet is the cue text.
        case plainText
        /// Everything else: FFmpeg decodes packets to ASS events.
        case decoded(StreamDecoder, keepsStyles: Bool)
    }

    private let kind: Kind
    private let timeBase: AVRational
    private let startTime: MediaTime
    private var cues: [Cue] = []
    private var events: [(start: MediaTime, end: MediaTime, fields: String)] = []

    var count: Int { cues.count + events.count }

    init(stream: UnsafeMutablePointer<AVStream>, startTime: MediaTime) throws {
        let parameters = stream.pointee.codecpar!
        let descriptor = avcodec_descriptor_get(parameters.pointee.codec_id)
        guard (descriptor?.pointee.props ?? 0) & AV_CODEC_PROP_TEXT_SUB != 0 else {
            throw MediaAnalyzer.Error.imageSubtitles
        }
        timeBase = stream.pointee.time_base
        self.startTime = startTime
        switch parameters.pointee.codec_id {
        case AV_CODEC_ID_SUBRIP, AV_CODEC_ID_WEBVTT:
            kind = .plainText
            stream.pointee.discard = AVDISCARD_DEFAULT
        case let codec:
            let decoder = try StreamDecoder(stream: stream) { $0.pointee.pkt_timebase = stream.pointee.time_base }
            kind = .decoded(decoder, keepsStyles: codec == AV_CODEC_ID_ASS || codec == AV_CODEC_ID_SSA)
        }
    }

    /// Reads one packet; nil (the end of the stream) is ignored.
    func read(_ packet: UnsafeMutablePointer<AVPacket>?) {
        guard let packet, let (start, end) = timing(of: packet.pointee) else { return }
        switch kind {
        case .plainText:
            guard let data = packet.pointee.data, packet.pointee.size > 0 else { return }
            let bytes = UnsafeBufferPointer(start: data, count: Int(packet.pointee.size))
            let text = String(decoding: bytes, as: UTF8.self)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\0").union(.newlines))
            if !text.isEmpty { cues.append(Cue(start: start, end: end, text: text)) }
        case .decoded(let decoder, let keepsStyles):
            var subtitle = AVSubtitle()
            var gotSubtitle: Int32 = 0
            guard avcodec_decode_subtitle2(decoder.context, &subtitle, &gotSubtitle, packet) >= 0, gotSubtitle != 0 else {
                return
            }
            defer { avsubtitle_free(&subtitle) }
            for index in 0..<Int(subtitle.num_rects) {
                guard let rect = subtitle.rects[index], let ass = rect.pointee.ass else { continue }
                let fields = String(cString: ass).trimmingCharacters(in: .newlines)
                // MP4 timed text marks gaps with empty samples; ASS keeps empty lines as written.
                if !keepsStyles, fields.split(separator: ",", maxSplits: 8, omittingEmptySubsequences: false).last?.isEmpty ?? true {
                    continue
                }
                events.append((start, end, fields))
            }
        }
    }

    /// The cues read so far.
    func track() throws -> SubtitleTrack {
        var track = try decodedTrack() ?? SubtitleTrack(cues: cues.sorted { $0.start < $1.start })
        // Packets without a duration last until the next cue, the last one two seconds.
        for index in track.cues.indices where track.cues[index].end <= track.cues[index].start {
            let start = track.cues[index].start
            let next = track.cues[(index + 1)...].first { $0.start > start }?.start
            track.cues[index].end = next ?? start + MediaTime(value: 2, timescale: 1)
        }
        return track
    }

    private func decodedTrack() throws -> SubtitleTrack? {
        guard case .decoded(let decoder, let keepsStyles) = kind else { return nil }
        let context = decoder.context.pointee
        let header = context.subtitle_header.map {
            String(decoding: UnsafeBufferPointer(start: $0, count: Int(context.subtitle_header_size)), as: UTF8.self)
        } ?? "[Script Info]\n"
        var track = try SubtitleTrack(assHeader: header, events: events)
        if !keepsStyles {
            // FFmpeg's stand-in header describes its renderer, not the file.
            track.styles = []
            track.properties = [:]
            for index in track.cues.indices { track.cues[index].style = nil }
        }
        return track
    }

    /// The packet's start and end on the player's clock, nil without a timestamp.
    private func timing(of packet: AVPacket) -> (MediaTime, MediaTime)? {
        let pts = packet.pts != Int64.min ? packet.pts : packet.dts
        guard pts != Int64.min, timeBase.den > 0 else { return nil }
        func time(_ value: Int64) -> MediaTime {
            MediaTime(value: value * Int64(timeBase.num), timescale: Int64(timeBase.den))
        }
        let start = time(pts) - startTime
        return (start, start + time(max(packet.duration, 0)))
    }
}
