import AppKit
import AVFoundation
import UniformTypeIdentifiers
import ImageIO

/// One wedge on the wheel. `run` happens off the main thread and returns the files it made.
struct Action {
    let label: String
    let detail: String
    let symbol: String?          // nil = a format wedge (text), set = a tool wedge (icon + text)
    let verb: String             // shown in the status pill while working
    let run: ([URL]) throws -> [URL]
}

enum Kind { case image, video, audio, pdf, doc, archive, other }

/// Decides which wedges a dragged file gets. Only formats this Mac can actually write are offered.
enum Catalog {
    static let avVideo: Set<String> = ["mp4", "mov", "m4v", "3gp"]
    static let anyVideo: Set<String> = avVideo.union(["avi", "mkv", "webm", "flv", "wmv", "mpg", "mpeg", "ts", "mts", "m2ts", "ogv"])
    static let afAudio: Set<String> = ["mp3", "m4a", "aac", "wav", "aif", "aiff", "aifc", "caf", "flac"]
    static let anyAudio: Set<String> = afAudio.union(["ogg", "oga", "opus", "wma", "amr", "m4r"])
    static let docs: Set<String> = ["txt", "text", "md", "markdown", "rtf", "rtfd", "html", "htm", "doc", "docx", "odt", "wordml", "webarchive"]
    static let archives: Set<String> = ["zip", "tar", "tgz", "tbz", "txz", "7z", "rar"]
    static let readableImages = Set((CGImageSourceCopyTypeIdentifiers() as? [String]) ?? [])
    static let writableImages = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])

    static func ext(_ url: URL) -> String { url.pathExtension.lowercased() }

    static func canon(_ e: String) -> String {
        switch e {
        case "jpeg", "jpe": return "jpg"
        case "tif": return "tiff"
        case "heif": return "heic"
        case "htm": return "html"
        case "aif", "aifc": return "aiff"
        case "markdown": return "md"
        case "text": return "txt"
        case "mpeg": return "mpg"
        default: return e
        }
    }

    static func allAre(_ urls: [URL], _ e: String) -> Bool {
        urls.allSatisfy { canon(ext($0)) == canon(e) }
    }

    static func kind(_ url: URL) -> Kind {
        let e = ext(url)
        if e == "pdf" { return .pdf }
        if anyVideo.contains(e) { return .video }
        if anyAudio.contains(e) { return .audio }
        if docs.contains(e) { return .doc }
        if archives.contains(e) || url.lastPathComponent.lowercased().contains(".tar.") { return .archive }
        if let t = UTType(filenameExtension: e), t.conforms(to: .image), readableImages.contains(t.identifier) { return .image }
        return .other
    }

    static func wantsFFmpeg(_ urls: [URL]) -> Bool {
        Engine.ffmpeg == nil && urls.contains { anyVideo.subtracting(avVideo).union(anyAudio.subtracting(afAudio)).contains(ext($0)) }
    }

    static func actions(for urls: [URL], tools: Bool) -> [Action] {
        guard !urls.isEmpty else { return [] }
        let kinds = Set(urls.map(kind))
        var list: [Action]
        if kinds.count == 1, let k = kinds.first {
            switch k {
            case .image: list = tools ? imageTools(urls) : imageConvert(urls)
            case .pdf: list = tools ? pdfTools(urls) : pdfConvert(urls)
            case .video: list = tools ? videoTools(urls) : videoConvert(urls)
            case .audio: list = tools ? audioTools(urls) : audioConvert(urls)
            case .doc: list = tools ? docTools(urls) : docConvert(urls)
            case .archive: list = tools ? [] : [extract]
            case .other: list = tools ? [zip] : []
            }
        } else if kinds.isSubset(of: [.image, .pdf]) {
            list = tools ? [merge, zip] : []
        } else {
            list = tools ? [zip] : []
        }
        return Array(list.prefix(12))
    }

    // MARK: Builders

    static func each(_ f: @escaping (URL) throws -> URL) -> ([URL]) throws -> [URL] {
        { urls in try urls.map(f) }
    }

    static func format(_ label: String, _ detail: String, _ run: @escaping ([URL]) throws -> [URL]) -> Action {
        Action(label: label, detail: detail, symbol: nil, verb: "Converting to \(label)", run: run)
    }

    static func tool(_ label: String, _ symbol: String, _ verb: String, _ run: @escaping ([URL]) throws -> [URL]) -> Action {
        Action(label: label, detail: "", symbol: symbol, verb: verb, run: run)
    }

    static let zip = tool("ZIP", "archivebox", "Zipping") { try [Engine.zip($0)] }
    static let extract = tool("Extract", "archivebox", "Extracting", each(Engine.extract))
    static let merge = tool("Merge", "rectangle.stack", "Merging into one PDF") { try [Engine.mergeToPDF($0)] }

    // MARK: Images

    static let imageTargets: [(label: String, uti: String, ext: String, detail: String)] = [
        ("JPG", "public.jpeg", "jpg", "Photo"),
        ("PNG", "public.png", "png", "Lossless"),
        ("HEIC", "public.heic", "heic", "Tiny"),
        ("WEBP", "org.webmproject.webp", "webp", "Web"),
        ("TIFF", "public.tiff", "tiff", "Print"),
        ("GIF", "com.compuserve.gif", "gif", "Classic"),
        ("BMP", "com.microsoft.bmp", "bmp", "Bitmap"),
        ("ICO", "com.microsoft.ico", "ico", "Favicon"),
        ("ICNS", "com.apple.icns", "icns", "Mac icon"),
    ]

    static func imageConvert(_ urls: [URL]) -> [Action] {
        var out: [Action] = []
        for t in imageTargets where !allAre(urls, t.ext) {
            if writableImages.contains(t.uti) {
                out.append(format(t.label, t.detail, each { try Engine.convertImage($0, uti: t.uti, ext: t.ext) }))
            } else if t.ext == "webp", Engine.ffmpeg != nil {
                out.append(format(t.label, t.detail, each { try Engine.ff($0, ext: "webp") }))
            }
        }
        let many = urls.count > 1
        out.append(Action(label: "PDF", detail: many ? "Combine" : "Document", symbol: nil,
                          verb: many ? "Combining into a PDF" : "Making a PDF",
                          run: { try [Engine.mergeToPDF($0)] }))
        return out
    }

    static func imageTools(_ urls: [URL]) -> [Action] {
        [
            tool("Compress", "arrow.down.circle", "Compressing", each(Engine.compressImage)),
            tool("Half size", "arrow.down.right.and.arrow.up.left", "Resizing", each { try Engine.resizeImage($0, factor: 0.5) }),
            tool("1080p", "tv", "Resizing to 1080p", each { try Engine.resizeImage($0, maxSide: 1920) }),
            tool("Square", "crop", "Cropping", each(Engine.squareImage)),
            tool("Rotate", "rotate.right", "Rotating", each(Engine.rotateImage)),
            tool("Flip", "arrow.left.and.right", "Flipping", each(Engine.flipImage)),
            tool("Mono", "circle.lefthalf.filled", "Going black & white", each(Engine.monoImage)),
            tool("No EXIF", "eye.slash", "Removing metadata", each(Engine.stripImage)),
            zip,
        ]
    }

    // MARK: PDF

    static func pdfConvert(_ urls: [URL]) -> [Action] {
        [
            format("PNG", "Pages", each { try Engine.pdfToImages($0, uti: "public.png", ext: "png") }),
            format("JPG", "Pages", each { try Engine.pdfToImages($0, uti: "public.jpeg", ext: "jpg") }),
            format("DOCX", "Word", each { try Engine.pdfToDoc($0, ext: "docx") }),
            format("RTF", "Rich text", each { try Engine.pdfToDoc($0, ext: "rtf") }),
            format("TXT", "Plain text", each(Engine.pdfToText)),
        ]
    }

    static func pdfTools(_ urls: [URL]) -> [Action] {
        var list = [tool("Compress", "arrow.down.circle", "Compressing", each(Engine.compressPDF))]
        if urls.count > 1 { list.append(merge) }
        list += [
            tool("Split", "scissors", "Splitting pages", each(Engine.splitPDF)),
            tool("Rotate", "rotate.right", "Rotating pages", each(Engine.rotatePDF)),
            tool("OCR", "text.viewfinder", "Recognising text", each(Engine.ocrPDF)),
            tool("Cover", "photo", "Saving the cover", each(Engine.pdfCover)),
            tool("Clean", "eye.slash", "Removing metadata", each(Engine.stripPDF)),
            zip,
        ]
        return list
    }

    // MARK: Video

    static func videoConvert(_ urls: [URL]) -> [Action] {
        let native = urls.allSatisfy { avVideo.contains(ext($0)) }
        var list: [Action] = []
        if native {
            let containers: [(String, String, AVFileType)] = [("MP4", "mp4", .mp4), ("MOV", "mov", .mov), ("M4V", "m4v", .m4v)]
            for (label, e, type) in containers where !allAre(urls, e) {
                list.append(format(label, "Video", each { try Engine.exportVideo($0, preset: AVAssetExportPresetHighestQuality, type: type, ext: e) }))
            }
            list.append(format("GIF", "8s loop", each(Engine.videoToGIF)))
            list.append(format("M4A", "Audio", each { try Engine.exportVideo($0, preset: AVAssetExportPresetAppleM4A, type: .m4a, ext: "m4a") }))
            list.append(format("WAV", "Audio", each(Engine.videoToWAV)))
        }
        if Engine.ffmpeg != nil {
            let extra: [(String, String, String)] = native
                ? [("MP3", "mp3", "Audio"), ("WEBM", "webm", "Web"), ("MKV", "mkv", "Video"), ("AVI", "avi", "Legacy")]
                : [("MP4", "mp4", "Video"), ("MOV", "mov", "Video"), ("GIF", "gif", "8s loop"), ("MP3", "mp3", "Audio"),
                   ("M4A", "m4a", "Audio"), ("WAV", "wav", "Audio"), ("WEBM", "webm", "Web"), ("MKV", "mkv", "Video")]
            for (label, e, detail) in extra where !allAre(urls, e) {
                list.append(format(label, detail, each { try Engine.ff($0, ext: e) }))
            }
        }
        return list
    }

    static func videoTools(_ urls: [URL]) -> [Action] {
        let native = urls.allSatisfy { avVideo.contains(ext($0)) }
        var list: [Action] = []
        if native {
            list += [
                tool("720p", "arrow.down.circle", "Compressing to 720p",
                     each { try Engine.exportVideo($0, preset: AVAssetExportPreset1280x720, type: .mp4, ext: "mp4", suffix: "-720p") }),
                tool("HEVC", "sparkles", "Re-encoding to HEVC",
                     each { try Engine.exportVideo($0, preset: AVAssetExportPresetHEVCHighestQuality, type: .mp4, ext: "mp4", suffix: "-hevc") }),
                tool("540p", "arrow.down.right.and.arrow.up.left", "Shrinking to 540p",
                     each { try Engine.exportVideo($0, preset: AVAssetExportPreset960x540, type: .mp4, ext: "mp4", suffix: "-540p") }),
                tool("Mute", "speaker.slash", "Removing audio", each(Engine.muteVideo)),
                tool("Frame", "photo", "Grabbing a frame", each(Engine.videoFrame)),
                tool("Clean", "eye.slash", "Removing metadata", each(Engine.stripVideo)),
            ]
            if urls.count > 1 {
                list.append(tool("Join", "film", "Joining clips") { try [Engine.joinMedia($0, video: true)] })
            }
        } else if Engine.ffmpeg != nil {
            list.append(tool("Compress", "arrow.down.circle", "Compressing",
                             each { try Engine.ff($0, ext: "mp4", suffix: "-small",
                                                  args: ["-c:v", "libx264", "-preset", "medium", "-crf", "28", "-pix_fmt", "yuv420p",
                                                         "-c:a", "aac", "-b:a", "128k", "-movflags", "+faststart"]) }))
        }
        list.append(zip)
        return list
    }

    // MARK: Audio

    static func audioConvert(_ urls: [URL]) -> [Action] {
        let native = urls.allSatisfy { afAudio.contains(ext($0)) }
        var list: [Action] = []
        if native {
            let targets: [(String, String, String, [String])] = [
                ("M4A", "m4a", "AAC", ["-f", "m4af", "-d", "aac", "-b", "256000"]),
                ("WAV", "wav", "Lossless", ["-f", "WAVE", "-d", "LEI16"]),
                ("AIFF", "aiff", "Lossless", ["-f", "AIFF", "-d", "BEI16"]),
                ("FLAC", "flac", "Lossless", ["-f", "flac", "-d", "flac"]),
            ]
            for (label, e, detail, args) in targets where !allAre(urls, e) {
                list.append(format(label, detail, each { try Engine.afconvert($0, ext: e, args: args) }))
            }
        }
        if Engine.ffmpeg != nil {
            let extra: [(String, String, String)] = native
                ? [("MP3", "mp3", "Universal"), ("OGG", "ogg", "Vorbis"), ("OPUS", "opus", "Voice")]
                : [("M4A", "m4a", "AAC"), ("MP3", "mp3", "Universal"), ("WAV", "wav", "Lossless"),
                   ("FLAC", "flac", "Lossless"), ("OGG", "ogg", "Vorbis"), ("OPUS", "opus", "Voice")]
            for (label, e, detail) in extra where !allAre(urls, e) {
                list.append(format(label, detail, each { try Engine.ff($0, ext: e) }))
            }
        }
        return list
    }

    static func audioTools(_ urls: [URL]) -> [Action] {
        let native = urls.allSatisfy { afAudio.contains(ext($0)) }
        var list: [Action] = []
        if native {
            list += [
                tool("Compress", "arrow.down.circle", "Compressing",
                     each { try Engine.afconvert($0, ext: "m4a", suffix: "-small", args: ["-f", "m4af", "-d", "aac", "-b", "96000"]) }),
                tool("Mono", "speaker.wave.1", "Mixing to mono",
                     each { try Engine.afconvert($0, ext: "m4a", suffix: "-mono", args: ["-f", "m4af", "-d", "aac", "-b", "128000", "-c", "1"]) }),
                tool("Ringtone", "bell", "Making a ringtone", each(Engine.ringtone)),
            ]
            if urls.count > 1 {
                list.append(tool("Join", "plus.rectangle.on.rectangle", "Joining tracks") { try [Engine.joinMedia($0, video: false)] })
            }
        }
        if Engine.ffmpeg != nil {
            list.append(tool("Normalize", "waveform", "Levelling loudness", each(Engine.normalizeAudio)))
        }
        list.append(zip)
        return list
    }

    // MARK: Documents

    static func docConvert(_ urls: [URL]) -> [Action] {
        let plain = urls.allSatisfy { ["txt", "md"].contains(canon(ext($0))) }
        let targets: [(String, String, String)] = [
            ("PDF", "pdf", "Print"), ("DOCX", "docx", "Word"), ("TXT", "txt", "Plain"), ("RTF", "rtf", "Rich text"),
            ("HTML", "html", "Web"), ("ODT", "odt", "Open"), ("DOC", "doc", "Legacy"),
        ]
        return targets
            .filter { !allAre(urls, $0.1) && !($0.1 == "txt" && plain) }
            .map { t in format(t.0, t.2, each { try Engine.convertDoc($0, to: t.1) }) }
    }

    static func docTools(_ urls: [URL]) -> [Action] {
        var list: [Action] = []
        if urls.count > 1 {
            list.append(tool("Merge", "doc.on.doc", "Merging documents") { try [Engine.mergeDocs($0)] })
        }
        list.append(zip)
        return list
    }
}
