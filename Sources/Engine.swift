import AppKit
import AVFoundation
import PDFKit
import ImageIO
import CoreImage
import UniformTypeIdentifiers

struct ConvmogError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Every conversion runs locally: ImageIO, PDFKit, AVFoundation and the tools macOS ships
/// (afconvert, textutil, ditto, tar). ffmpeg is used only when it's installed.
enum Engine {
    static var ffmpeg: String? {
        ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/opt/local/bin/ffmpeg"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: - Naming: results land next to the original and never overwrite anything

    static func unique(_ dir: URL, _ base: String, _ ext: String?) -> URL {
        func make(_ name: String) -> URL {
            let u = dir.appendingPathComponent(name)
            if let e = ext { return u.appendingPathExtension(e) }
            return u
        }
        var url = make(base)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = make("\(base) \(n)")
            n += 1
        }
        return url
    }

    static func output(_ src: URL, ext: String, suffix: String = "") -> URL {
        unique(src.deletingLastPathComponent(), src.deletingPathExtension().lastPathComponent + suffix, ext)
    }

    static func folder(_ src: URL, suffix: String) throws -> URL {
        var base = src.deletingPathExtension().lastPathComponent
        if base.lowercased().hasSuffix(".tar") { base = String(base.dropLast(4)) }
        let dir = unique(src.deletingLastPathComponent(), base + suffix, nil)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func pad(_ n: Int, _ total: Int) -> String {
        let s = String(n)
        return String(repeating: "0", count: max(0, String(total).count - s.count)) + s
    }

    /// Runs `body` to produce `out`; cleans up a half-written file if it fails.
    static func producing(_ out: URL, _ body: () throws -> Void) throws -> URL {
        do {
            try body()
            return out
        } catch {
            try? FileManager.default.removeItem(at: out)
            throw error
        }
    }

    @discardableResult
    static func run(_ exe: String, _ args: [String], cwd: URL? = nil) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        if let cwd = cwd { p.currentDirectoryURL = cwd }
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard p.terminationStatus == 0 else {
            let tool = URL(fileURLWithPath: exe).lastPathComponent
            let last = text.split(separator: "\n").last.map(String.init) ?? ""
            throw ConvmogError(last.isEmpty ? "\(tool) stopped (code \(p.terminationStatus))" : "\(tool): \(last)")
        }
        return text
    }

    static func onMain<T>(_ body: () throws -> T) throws -> T {
        if Thread.isMainThread { return try body() }
        return try DispatchQueue.main.sync { try body() }
    }

    // MARK: - Images (ImageIO)

    static func pixelSize(_ url: URL) -> (Int, Int)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int,
              let h = p[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }

    /// Decodes upright (EXIF orientation applied), optionally downscaled with high quality.
    static func loadImage(_ url: URL, maxPixel: Int? = nil) throws -> CGImage {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ConvmogError("Can't read \(url.lastPathComponent)")
        }
        var opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        if let m = maxPixel ?? pixelSize(url).map({ max($0.0, $0.1) }) {
            opts[kCGImageSourceThumbnailMaxPixelSize] = m
        }
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            throw ConvmogError("Can't decode \(url.lastPathComponent)")
        }
        return image
    }

    /// Original metadata with orientation reset, since pixels are already upright.
    static func metadata(_ url: URL) -> [CFString: Any] {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              var p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return [:] }
        p[kCGImagePropertyOrientation] = 1
        if var tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            p[kCGImagePropertyTIFFDictionary] = tiff
        }
        p.removeValue(forKey: kCGImagePropertyPixelWidth)
        p.removeValue(forKey: kCGImagePropertyPixelHeight)
        return p
    }

    static func writeImage(_ image: CGImage, to out: URL, uti: String, quality: Double? = nil, props: [CFString: Any] = [:]) throws {
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, uti as CFString, 1, nil) else {
            throw ConvmogError("This Mac can't write .\(out.pathExtension)")
        }
        var p = props
        if let q = quality { p[kCGImageDestinationLossyCompressionQuality] = q }
        CGImageDestinationAddImage(dest, image, p as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            try? FileManager.default.removeItem(at: out)
            throw ConvmogError("Couldn't encode .\(out.pathExtension)")
        }
    }

    static func canvas(_ w: Int, _ h: Int, like image: CGImage? = nil) throws -> CGContext {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let preferred = image?.colorSpace?.model == .rgb ? (image?.colorSpace ?? srgb) : srgb
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        let ctx = CGContext(data: nil, width: max(w, 1), height: max(h, 1), bitsPerComponent: 8, bytesPerRow: 0, space: preferred, bitmapInfo: info)
            ?? CGContext(data: nil, width: max(w, 1), height: max(h, 1), bitsPerComponent: 8, bytesPerRow: 0, space: srgb, bitmapInfo: info)
        guard let c = ctx else { throw ConvmogError("Not enough memory for that image") }
        c.interpolationQuality = .high
        return c
    }

    static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }

    static func flatten(_ image: CGImage) throws -> CGImage {
        let ctx = try canvas(image.width, image.height, like: image)
        let r = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(r)
        ctx.draw(image, in: r)
        guard let out = ctx.makeImage() else { throw ConvmogError("Couldn't flatten the image") }
        return out
    }

    static func squared(_ image: CGImage, side: Int? = nil) throws -> CGImage {
        let s = min(image.width, image.height)
        guard let crop = image.cropping(to: CGRect(x: (image.width - s) / 2, y: (image.height - s) / 2, width: s, height: s)) else {
            throw ConvmogError("Couldn't crop the image")
        }
        guard let side = side else { return crop }
        let ctx = try canvas(side, side, like: crop)
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let out = ctx.makeImage() else { throw ConvmogError("Couldn't resize the image") }
        return out
    }

    /// Saves in the source's own format when this Mac can write it, otherwise PNG (alpha) or JPG.
    static func saveSame(_ image: CGImage, like src: URL, suffix: String, quality: Double = 0.9, keepMeta: Bool = true) throws -> URL {
        let e = Catalog.ext(src)
        var uti = "public.jpeg", ext = "jpg"
        if let t = UTType(filenameExtension: e), Catalog.writableImages.contains(t.identifier), !["ico", "icns", "gif"].contains(e) {
            uti = t.identifier
            ext = e
        } else if hasAlpha(image) {
            uti = "public.png"
            ext = "png"
        }
        let pixels = try (uti == "public.jpeg" && hasAlpha(image) ? flatten(image) : image)
        let out = output(src, ext: ext, suffix: suffix)
        return try producing(out) {
            try writeImage(pixels, to: out, uti: uti, quality: quality, props: keepMeta ? metadata(src) : [:])
        }
    }

    static func convertImage(_ src: URL, uti: String, ext: String) throws -> URL {
        var image = try loadImage(src)
        if ext == "ico" { image = try squared(image, side: 256) }
        if ext == "icns" { image = try squared(image, side: 512) }
        if ext == "jpg" || ext == "bmp", hasAlpha(image) { image = try flatten(image) }
        let lossy = ["jpg", "heic", "webp"].contains(ext)
        let keepMeta = !["ico", "icns", "gif", "bmp"].contains(ext)
        let final = image
        let out = output(src, ext: ext)
        return try producing(out) {
            try writeImage(final, to: out, uti: uti, quality: lossy ? 0.9 : nil, props: keepMeta ? metadata(src) : [:])
        }
    }

    static func compressImage(_ src: URL) throws -> URL {
        let image = try loadImage(src)
        // Transparent art keeps its alpha in HEIC; everything else becomes a lean JPG (or stays HEIC).
        if hasAlpha(image), Catalog.writableImages.contains("public.heic") {
            let out = output(src, ext: "heic", suffix: "-small")
            return try producing(out) { try writeImage(image, to: out, uti: "public.heic", quality: 0.6, props: metadata(src)) }
        }
        let isHEIC = Catalog.canon(Catalog.ext(src)) == "heic"
        let pixels = try (hasAlpha(image) ? flatten(image) : image)
        let out = output(src, ext: isHEIC ? "heic" : "jpg", suffix: "-small")
        return try producing(out) {
            try writeImage(pixels, to: out, uti: isHEIC ? "public.heic" : "public.jpeg", quality: isHEIC ? 0.55 : 0.7, props: metadata(src))
        }
    }

    static func resizeImage(_ src: URL, factor: Double) throws -> URL {
        guard let size = pixelSize(src) else { throw ConvmogError("Can't read \(src.lastPathComponent)") }
        let side = max(1, Int(Double(max(size.0, size.1)) * factor))
        return try saveSame(loadImage(src, maxPixel: side), like: src, suffix: "-half")
    }

    static func resizeImage(_ src: URL, maxSide: Int) throws -> URL {
        let longest = pixelSize(src).map { max($0.0, $0.1) } ?? maxSide
        return try saveSame(loadImage(src, maxPixel: min(longest, maxSide)), like: src, suffix: "-1080p")
    }

    static func squareImage(_ src: URL) throws -> URL {
        try saveSame(squared(loadImage(src)), like: src, suffix: "-square")
    }

    static func rotateImage(_ src: URL) throws -> URL {
        let image = try loadImage(src)
        let w = image.width, h = image.height
        let ctx = try canvas(h, w, like: image)
        ctx.translateBy(x: 0, y: CGFloat(w))
        ctx.rotate(by: -.pi / 2)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = ctx.makeImage() else { throw ConvmogError("Couldn't rotate the image") }
        return try saveSame(out, like: src, suffix: "-rotated")
    }

    static func flipImage(_ src: URL) throws -> URL {
        let image = try loadImage(src)
        let ctx = try canvas(image.width, image.height, like: image)
        ctx.translateBy(x: CGFloat(image.width), y: 0)
        ctx.scaleBy(x: -1, y: 1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let out = ctx.makeImage() else { throw ConvmogError("Couldn't flip the image") }
        return try saveSame(out, like: src, suffix: "-flipped")
    }

    static func monoImage(_ src: URL) throws -> URL {
        let image = try loadImage(src)
        let input = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIPhotoEffectMono") else { throw ConvmogError("Mono filter unavailable") }
        filter.setValue(input, forKey: kCIInputImageKey)
        guard let result = filter.outputImage,
              let out = CIContext().createCGImage(result, from: input.extent) else {
            throw ConvmogError("Couldn't process the image")
        }
        return try saveSame(out, like: src, suffix: "-mono")
    }

    static func stripImage(_ src: URL) throws -> URL {
        try saveSame(loadImage(src), like: src, suffix: "-clean", quality: 0.95, keepMeta: false)
    }

    // MARK: - PDF (PDFKit)

    static func openPDF(_ url: URL) throws -> PDFDocument {
        guard let doc = PDFDocument(url: url) else { throw ConvmogError("Can't open \(url.lastPathComponent)") }
        if doc.isLocked { throw ConvmogError("That PDF is password-protected") }
        return doc
    }

    static func writePDF(_ doc: PDFDocument, to out: URL, options: [PDFDocumentWriteOption: Any] = [:]) throws -> URL {
        let ok = options.isEmpty ? doc.write(to: out) : doc.write(to: out, withOptions: options)
        guard ok else {
            try? FileManager.default.removeItem(at: out)
            throw ConvmogError("Couldn't write the PDF")
        }
        return out
    }

    static func render(_ page: PDFPage, scale: CGFloat = 2) throws -> CGImage {
        let box = page.bounds(for: .mediaBox)
        let turned = abs(page.rotation) % 180 == 90
        let w = Int(((turned ? box.height : box.width) * scale).rounded())
        let h = Int(((turned ? box.width : box.height) * scale).rounded())
        let ctx = try canvas(w, h)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: ctx)
        guard let image = ctx.makeImage() else { throw ConvmogError("Couldn't render the page") }
        return image
    }

    /// Images and/or PDFs → one PDF, in the order they were dragged.
    static func mergeToPDF(_ urls: [URL]) throws -> URL {
        let doc = PDFDocument()
        for u in urls {
            if Catalog.ext(u) == "pdf" {
                let source = try openPDF(u)
                for i in 0..<source.pageCount {
                    if let page = source.page(at: i)?.copy() as? PDFPage { doc.insert(page, at: doc.pageCount) }
                }
            } else {
                let image = try loadImage(u)
                let w = CGFloat(image.width), h = CGFloat(image.height)
                let k = min(1, 842 / max(w, h))   // longest side fits an A4 page, pixels stay full-res
                guard let page = PDFPage(image: NSImage(cgImage: image, size: NSSize(width: w * k, height: h * k))) else {
                    throw ConvmogError("Couldn't place \(u.lastPathComponent)")
                }
                doc.insert(page, at: doc.pageCount)
            }
        }
        guard doc.pageCount > 0 else { throw ConvmogError("Nothing to put in the PDF") }
        let out = output(urls[0], ext: "pdf", suffix: urls.count > 1 ? " merged" : "")
        return try writePDF(doc, to: out)
    }

    static func pdfToImages(_ src: URL, uti: String, ext: String) throws -> URL {
        let doc = try openPDF(src)
        guard doc.pageCount > 0 else { throw ConvmogError("That PDF has no pages") }
        if doc.pageCount == 1, let page = doc.page(at: 0) {
            let image = try render(page)
            let out = output(src, ext: ext)
            return try producing(out) { try writeImage(image, to: out, uti: uti, quality: 0.9) }
        }
        let dir = try folder(src, suffix: " pages")
        let base = src.deletingPathExtension().lastPathComponent
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let file = dir.appendingPathComponent("\(base) \(pad(i + 1, doc.pageCount))").appendingPathExtension(ext)
            try writeImage(render(page), to: file, uti: uti, quality: 0.9)
        }
        return dir
    }

    static func pdfToText(_ src: URL) throws -> URL {
        let text = try openPDF(src).string ?? ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConvmogError("No text in this PDF — run OCR first (⇧⌥ drag)")
        }
        let out = output(src, ext: "txt")
        return try producing(out) { try text.write(to: out, atomically: true, encoding: .utf8) }
    }

    static func pdfToDoc(_ src: URL, ext: String) throws -> URL {
        let doc = try openPDF(src)
        let all = NSMutableAttributedString()
        for i in 0..<doc.pageCount {
            if let s = doc.page(at: i)?.attributedString {
                all.append(s)
                all.append(NSAttributedString(string: "\n\n"))
            }
        }
        guard all.length > 0 else { throw ConvmogError("No text in this PDF — run OCR first (⇧⌥ drag)") }
        let out = output(src, ext: ext)
        return try producing(out) { try writeAttributed(all, to: out, ext: ext) }
    }

    static func compressPDF(_ src: URL) throws -> URL {
        let doc = try openPDF(src)
        guard #available(macOS 13.4, *) else { throw ConvmogError("PDF compression needs macOS 13.4 or later") }
        return try writePDF(doc, to: output(src, ext: "pdf", suffix: "-small"),
                            options: [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true])
    }

    static func ocrPDF(_ src: URL) throws -> URL {
        let doc = try openPDF(src)
        return try writePDF(doc, to: output(src, ext: "pdf", suffix: "-ocr"), options: [.saveTextFromOCROption: true])
    }

    static func splitPDF(_ src: URL) throws -> URL {
        let doc = try openPDF(src)
        guard doc.pageCount > 1 else { throw ConvmogError("Only one page — nothing to split") }
        let dir = try folder(src, suffix: " pages")
        let base = src.deletingPathExtension().lastPathComponent
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i)?.copy() as? PDFPage else { continue }
            let single = PDFDocument()
            single.insert(page, at: 0)
            _ = try writePDF(single, to: dir.appendingPathComponent("\(base) \(pad(i + 1, doc.pageCount))").appendingPathExtension("pdf"))
        }
        return dir
    }

    static func rotatePDF(_ src: URL) throws -> URL {
        let doc = try openPDF(src)
        for i in 0..<doc.pageCount {
            if let page = doc.page(at: i) { page.rotation = (page.rotation + 90) % 360 }
        }
        return try writePDF(doc, to: output(src, ext: "pdf", suffix: "-rotated"))
    }

    static func stripPDF(_ src: URL) throws -> URL {
        let doc = try openPDF(src)
        doc.documentAttributes = [:]
        return try writePDF(doc, to: output(src, ext: "pdf", suffix: "-clean"))
    }

    static func pdfCover(_ src: URL) throws -> URL {
        guard let page = try openPDF(src).page(at: 0) else { throw ConvmogError("That PDF has no pages") }
        let image = try render(page)
        let out = output(src, ext: "png", suffix: "-cover")
        return try producing(out) { try writeImage(image, to: out, uti: "public.png") }
    }

    // MARK: - Video & audio (AVFoundation)

    static func seconds(_ asset: AVAsset) -> Double {
        let s = CMTimeGetSeconds(asset.duration)
        return s.isFinite ? s : 0
    }

    static func export(_ asset: AVAsset, preset: String, to out: URL, type: AVFileType,
                       clean: Bool = false, range: CMTimeRange? = nil) throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw ConvmogError("This Mac can't run that export")
        }
        guard session.supportedFileTypes.contains(type) else {
            if preset == AVAssetExportPresetPassthrough {
                return try export(asset, preset: AVAssetExportPresetHighestQuality, to: out, type: type, clean: clean, range: range)
            }
            throw ConvmogError("Can't make .\(out.pathExtension) from this file")
        }
        session.outputURL = out
        session.outputFileType = type
        session.shouldOptimizeForNetworkUse = true
        if let r = range { session.timeRange = r }
        if clean {
            session.metadata = []
            session.metadataItemFilter = .forSharing()
        }
        let done = DispatchSemaphore(value: 0)
        session.exportAsynchronously { done.signal() }
        done.wait()
        guard session.status == .completed else {
            try? FileManager.default.removeItem(at: out)
            throw ConvmogError(session.error?.localizedDescription ?? "Export failed")
        }
    }

    static func exportVideo(_ src: URL, preset: String, type: AVFileType, ext: String, suffix: String = "") throws -> URL {
        let out = output(src, ext: ext, suffix: suffix)
        try export(AVURLAsset(url: src), preset: preset, to: out, type: type)
        return out
    }

    static func container(_ src: URL) -> (AVFileType, String) {
        switch Catalog.ext(src) {
        case "mov": return (.mov, "mov")
        case "m4v": return (.m4v, "m4v")
        default: return (.mp4, "mp4")
        }
    }

    static func videoToGIF(_ src: URL) throws -> URL {
        let asset = AVURLAsset(url: src)
        let length = min(seconds(asset), 8)
        guard length > 0 else { throw ConvmogError("Couldn't read the video") }
        let fps = 12.0
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 480, height: 480)
        let tolerance = CMTime(seconds: 0.5 / fps, preferredTimescale: 600)
        gen.requestedTimeToleranceBefore = tolerance
        gen.requestedTimeToleranceAfter = tolerance

        var frames: [CGImage] = []
        for i in 0..<max(1, Int(length * fps)) {
            let t = CMTime(seconds: Double(i) / fps, preferredTimescale: 600)
            if let frame = try? gen.copyCGImage(at: t, actualTime: nil) { frames.append(frame) }
        }
        guard !frames.isEmpty else { throw ConvmogError("Couldn't read any frames") }

        let out = output(src, ext: "gif")
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, "com.compuserve.gif" as CFString, frames.count, nil) else {
            throw ConvmogError("Couldn't create the GIF")
        }
        let loop: [CFString: Any] = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]]
        let delay: [CFString: Any] = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / fps]]
        CGImageDestinationSetProperties(dest, loop as CFDictionary)
        for frame in frames { CGImageDestinationAddImage(dest, frame, delay as CFDictionary) }
        guard CGImageDestinationFinalize(dest) else {
            try? FileManager.default.removeItem(at: out)
            throw ConvmogError("Couldn't encode the GIF")
        }
        return out
    }

    static func videoToWAV(_ src: URL) throws -> URL {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("m4a")
        defer { try? FileManager.default.removeItem(at: temp) }
        try export(AVURLAsset(url: src), preset: AVAssetExportPresetAppleM4A, to: temp, type: .m4a)
        let out = output(src, ext: "wav")
        return try producing(out) { try run("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEI16", temp.path, out.path]) }
    }

    static func muteVideo(_ src: URL) throws -> URL {
        let asset = AVURLAsset(url: src)
        let comp = AVMutableComposition()
        guard let video = asset.tracks(withMediaType: .video).first,
              let track = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ConvmogError("No video track found")
        }
        try track.insertTimeRange(CMTimeRange(start: .zero, duration: asset.duration), of: video, at: .zero)
        track.preferredTransform = video.preferredTransform
        let (type, ext) = container(src)
        let out = output(src, ext: ext, suffix: "-muted")
        try export(comp, preset: AVAssetExportPresetPassthrough, to: out, type: type)
        return out
    }

    static func stripVideo(_ src: URL) throws -> URL {
        let (type, ext) = container(src)
        let out = output(src, ext: ext, suffix: "-clean")
        try export(AVURLAsset(url: src), preset: AVAssetExportPresetPassthrough, to: out, type: type, clean: true)
        return out
    }

    static func videoFrame(_ src: URL) throws -> URL {
        let asset = AVURLAsset(url: src)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        let at = CMTime(seconds: min(1, seconds(asset) / 2), preferredTimescale: 600)
        let image = try gen.copyCGImage(at: at, actualTime: nil)
        let out = output(src, ext: "jpg", suffix: "-frame")
        return try producing(out) { try writeImage(image, to: out, uti: "public.jpeg", quality: 0.92) }
    }

    static func joinMedia(_ urls: [URL], video: Bool) throws -> URL {
        let comp = AVMutableComposition()
        let videoTrack = video ? comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) : nil
        let audioTrack = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        var cursor = CMTime.zero
        for (i, u) in urls.enumerated() {
            let asset = AVURLAsset(url: u)
            let span = CMTimeRange(start: .zero, duration: asset.duration)
            if let vt = videoTrack, let v = asset.tracks(withMediaType: .video).first {
                try vt.insertTimeRange(span, of: v, at: cursor)
                if i == 0 { vt.preferredTransform = v.preferredTransform }
            }
            if let at = audioTrack, let a = asset.tracks(withMediaType: .audio).first {
                try at.insertTimeRange(span, of: a, at: cursor)
            }
            cursor = CMTimeAdd(cursor, asset.duration)
        }
        if let at = audioTrack, at.segments.isEmpty { comp.removeTrack(at) }
        let out = output(urls[0], ext: video ? "mp4" : "m4a", suffix: " joined")
        try export(comp, preset: video ? AVAssetExportPresetHighestQuality : AVAssetExportPresetAppleM4A,
                   to: out, type: video ? .mp4 : .m4a)
        return out
    }

    static func ringtone(_ src: URL) throws -> URL {
        let asset = AVURLAsset(url: src)
        let length = min(seconds(asset), 30)
        guard length > 0 else { throw ConvmogError("Couldn't read the audio") }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("m4a")
        try export(asset, preset: AVAssetExportPresetAppleM4A, to: temp, type: .m4a,
                   range: CMTimeRange(start: .zero, duration: CMTime(seconds: length, preferredTimescale: 600)))
        let out = output(src, ext: "m4r")
        try FileManager.default.moveItem(at: temp, to: out)
        return out
    }

    static func afconvert(_ src: URL, ext: String, suffix: String = "", args: [String]) throws -> URL {
        let out = output(src, ext: ext, suffix: suffix)
        return try producing(out) { try run("/usr/bin/afconvert", args + [src.path, out.path]) }
    }

    // MARK: - ffmpeg (optional)

    static let ffArgs: [String: [String]] = [
        "mp4": ["-c:v", "libx264", "-preset", "veryfast", "-crf", "23", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart"],
        "mov": ["-c:v", "libx264", "-preset", "veryfast", "-crf", "23", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k"],
        "webm": ["-c:v", "libvpx-vp9", "-crf", "33", "-b:v", "0", "-row-mt", "1", "-c:a", "libopus", "-b:a", "128k"],
        "mkv": ["-map", "0", "-c", "copy"],
        "avi": ["-c:v", "mpeg4", "-q:v", "4", "-c:a", "libmp3lame", "-q:a", "3"],
        "gif": ["-t", "8", "-vf", "fps=12,scale=480:-1:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse", "-loop", "0"],
        "mp3": ["-vn", "-c:a", "libmp3lame", "-q:a", "2"],
        "m4a": ["-vn", "-c:a", "aac", "-b:a", "192k"],
        "wav": ["-vn", "-c:a", "pcm_s16le"],
        "flac": ["-vn", "-c:a", "flac"],
        "ogg": ["-vn", "-c:a", "libvorbis", "-q:a", "5"],
        "opus": ["-vn", "-c:a", "libopus", "-b:a", "128k"],
        "webp": ["-c:v", "libwebp", "-quality", "85"],
    ]

    static func ff(_ src: URL, ext: String, suffix: String = "", args: [String]? = nil) throws -> URL {
        guard let bin = ffmpeg else { throw ConvmogError("Needs ffmpeg — run: brew install ffmpeg") }
        let out = output(src, ext: ext, suffix: suffix)
        let codec = args ?? ffArgs[ext] ?? []
        return try producing(out) {
            try run(bin, ["-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-i", src.path] + codec + [out.path])
        }
    }

    static func normalizeAudio(_ src: URL) throws -> URL {
        let e = Catalog.canon(Catalog.ext(src))
        let target = ffArgs[e] != nil ? e : "m4a"
        return try ff(src, ext: target, suffix: "-loud",
                      args: ["-af", "loudnorm=I=-16:TP=-1.5:LRA=11"] + (ffArgs[target] ?? []))
    }

    // MARK: - Documents (textutil + Cocoa text system)

    static func convertDoc(_ src: URL, to ext: String) throws -> URL {
        let out = output(src, ext: ext)
        if ext == "pdf" || Catalog.canon(Catalog.ext(src)) == "md" {
            let text = try loadDoc(src)
            return try producing(out) { try writeAttributed(text, to: out, ext: ext) }
        }
        return try producing(out) { try run("/usr/bin/textutil", ["-convert", ext, "-output", out.path, src.path]) }
    }

    static func mergeDocs(_ urls: [URL]) throws -> URL {
        let all = NSMutableAttributedString()
        for (i, u) in urls.enumerated() {
            if i > 0 { all.append(NSAttributedString(string: "\n\n")) }
            all.append(try loadDoc(u))
        }
        let out = output(urls[0], ext: "docx", suffix: " merged")
        return try producing(out) { try writeAttributed(all, to: out, ext: "docx") }
    }

    static func loadDoc(_ src: URL) throws -> NSAttributedString {
        if Catalog.canon(Catalog.ext(src)) == "md" {
            let text = try String(contentsOf: src, encoding: .utf8)
            return try onMain { markdown(text) }
        }
        return try onMain { try NSAttributedString(url: src, options: [:], documentAttributes: nil) }
    }

    static func writeAttributed(_ text: NSAttributedString, to out: URL, ext: String) throws {
        if ext == "pdf" { return try printPDF(text, to: out) }
        let types: [String: NSAttributedString.DocumentType] = [
            "docx": .officeOpenXML, "rtf": .rtf, "html": .html, "odt": .openDocument, "doc": .docFormat, "txt": .plain,
        ]
        guard let type = types[ext] else { throw ConvmogError("Can't write .\(ext)") }
        var attrs: [NSAttributedString.DocumentAttributeKey: Any] = [.documentType: type]
        if type == .plain || type == .html { attrs[.characterEncoding] = String.Encoding.utf8.rawValue }
        let data = try onMain { try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: attrs) }
        try data.write(to: out)
    }

    /// Paginates attributed text onto A4 pages and saves straight to a PDF file.
    static func printPDF(_ text: NSAttributedString, to out: URL) throws {
        let ok: Bool = try onMain {
            let info = NSPrintInfo()
            info.paperSize = NSSize(width: 595, height: 842)
            info.topMargin = 56
            info.bottomMargin = 56
            info.leftMargin = 56
            info.rightMargin = 56
            info.horizontalPagination = .fit
            info.verticalPagination = .automatic
            info.isHorizontallyCentered = false
            info.isVerticallyCentered = false
            info.jobDisposition = .save
            info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL.rawValue] = out

            let width = info.paperSize.width - info.leftMargin - info.rightMargin
            let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
            view.appearance = NSAppearance(named: .aqua)
            view.isVerticallyResizable = true
            view.textContainerInset = .zero
            view.textContainer?.widthTracksTextView = true
            view.textStorage?.setAttributedString(text)
            if let lm = view.layoutManager, let tc = view.textContainer {
                lm.ensureLayout(for: tc)
                view.setFrameSize(NSSize(width: width, height: max(lm.usedRect(for: tc).height + 4, 100)))
            }
            let op = NSPrintOperation(view: view, printInfo: info)
            op.showsPrintPanel = false
            op.showsProgressPanel = false
            return op.run()
        }
        guard ok else { throw ConvmogError("Couldn't lay out the PDF") }
    }

    /// Light Markdown → rich text: headings, bullets, code blocks, and inline bold/italic/code/links.
    static func markdown(_ source: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let body = NSFont.systemFont(ofSize: 11.5)
        let mono = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
        let ink = NSColor.black
        var inCode = false

        for raw in source.components(separatedBy: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                inCode.toggle()
                continue
            }
            if inCode {
                out.append(NSAttributedString(string: raw + "\n", attributes: [.font: mono, .foregroundColor: ink]))
                continue
            }
            var line = raw
            var font = body
            var after: CGFloat = 4
            if line.hasPrefix("### ") {
                font = .systemFont(ofSize: 13.5, weight: .semibold); line.removeFirst(4); after = 6
            } else if line.hasPrefix("## ") {
                font = .systemFont(ofSize: 16, weight: .semibold); line.removeFirst(3); after = 8
            } else if line.hasPrefix("# ") {
                font = .systemFont(ofSize: 21, weight: .bold); line.removeFirst(2); after = 10
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                line = "•  " + String(trimmed.dropFirst(2))
            }
            let para = NSMutableParagraphStyle()
            para.paragraphSpacing = after
            para.lineHeightMultiple = 1.15

            let parsed = (try? NSAttributedString(markdown: line, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                ?? NSAttributedString(string: line)
            let m = NSMutableAttributedString(attributedString: parsed)
            let whole = NSRange(location: 0, length: m.length)
            m.addAttributes([.font: font, .foregroundColor: ink, .paragraphStyle: para], range: whole)
            m.enumerateAttribute(.inlinePresentationIntent, in: whole) { value, range, _ in
                guard let bits = (value as? NSNumber)?.uintValue else { return }
                let intent = InlinePresentationIntent(rawValue: bits)
                var f = font
                if intent.contains(.stronglyEmphasized) { f = NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask) }
                if intent.contains(.emphasized) { f = NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask) }
                if intent.contains(.code) { f = mono }
                m.addAttribute(.font, value: f, range: range)
            }
            m.append(NSAttributedString(string: "\n", attributes: [.font: font, .paragraphStyle: para]))
            out.append(m)
        }
        return out
    }

    // MARK: - Archives (ditto, zip, tar — all built in)

    static func zip(_ urls: [URL]) throws -> URL {
        if urls.count == 1 {
            let src = urls[0]
            let out = unique(src.deletingLastPathComponent(), src.lastPathComponent, "zip")
            return try producing(out) {
                try run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", src.path, out.path])
            }
        }
        let dir = urls[0].deletingLastPathComponent()
        let together = urls.allSatisfy { $0.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL }
        let out = unique(dir, "Archive", "zip")
        let items = together ? urls.map(\.lastPathComponent) : urls.map(\.path)
        let flags = ["-r", "-q", "-y"] + (together ? [] : ["-j"])   // -j: no Users/<name>/… paths inside
        return try producing(out) {
            try run("/usr/bin/zip", flags + [out.path] + items + ["-x", "*.DS_Store"], cwd: dir)
        }
    }

    static func extract(_ src: URL) throws -> URL {
        let dir = try folder(src, suffix: "")
        do {
            try run("/usr/bin/tar", ["-xf", src.path, "-C", dir.path])
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
        return dir
    }
}
