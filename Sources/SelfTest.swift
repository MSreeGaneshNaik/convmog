import AppKit
import ImageIO
import PDFKit

/// `Convmog --selftest` checks what a wrong drop would depend on: wedge maths, naming, file kinds.
/// build.sh runs it after compiling and refuses to install if anything fails.
enum SelfTest {
    static func run() -> Bool {
        var failures: [String] = []
        func check(_ ok: Bool, _ what: String) { if !ok { failures.append(what) } }

        // Every wedge centre maps back to its own wedge, for every wheel size.
        for n in 1...12 {
            let sweep = 2 * Double.pi / Double(n)
            for i in 0..<n {
                let a = Double.pi / 2 - Double(i) * sweep
                let got = WheelView.wedge(dx: CGFloat(cos(a) * 100), dy: CGFloat(sin(a) * 100), count: n)
                check(got == i, "wedge \(i) of \(n) came back as \(got)")
            }
        }

        // Results never overwrite anything: a clash gets " 2".
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("convmog-selftest-\(UUID().uuidString)")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        fm.createFile(atPath: dir.appendingPathComponent("photo.heic").path, contents: Data())
        let src = dir.appendingPathComponent("photo.png")
        check(Engine.output(src, ext: "heic").lastPathComponent == "photo 2.heic", "a name clash must get \" 2\"")
        check(Engine.output(src, ext: "jpg").lastPathComponent == "photo.jpg", "a free name must be used as is")

        // File kinds and the wedges they get.
        let at = { (name: String) in URL(fileURLWithPath: "/x/" + name) }
        check(Catalog.kind(at("a.tar.gz")) == .archive, "a.tar.gz is an archive")
        check(Catalog.kind(at("log.gz")) == .other, "a lone .gz is not an archive")
        check(Catalog.kind(at("clip.MP4")) == .video, "MP4 is a video")
        check(Catalog.kind(at("pic.jpeg")) == .image, "JPEG is an image")
        check(Catalog.allAre([at("pic.jpeg")], "jpg"), "jpeg counts as jpg")
        let png = Catalog.actions(for: [at("photo.png")], tools: false).map(\.label)
        check(png.contains("JPG") && png.contains("PDF"), "a PNG is offered JPG and PDF (got \(png))")
        check(!png.contains("PNG"), "a PNG is not offered PNG")

        // The mark's petal data parses and fills its 256 grid.
        let box = Mark.path(side: 256).bounds
        check(abs(box.width - 256) < 0.5 && abs(box.height - 256) < 0.5, "the mark fills its grid (got \(box))")

        // Every kind that should be croppable gets a Crop wedge, and images keep Flip.
        let imageTools = Catalog.actions(for: [at("photo.png")], tools: true).map(\.label)
        check(imageTools.contains("Crop") && imageTools.contains("Flip"), "an image is offered Crop and Flip (got \(imageTools))")
        check(Catalog.actions(for: [at("scan.pdf")], tools: true).contains { $0.label == "Crop" }, "a PDF is offered Crop")
        check(Catalog.actions(for: [at("notes.docx")], tools: true).contains { $0.label == "Crop" }, "a Word doc is offered Crop")

        // The real engine, on real files: Flip mirrors, Crop starts from the ink and cuts what was picked.
        do {
            let red = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), blue = CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
            let pair = try makePNG(in: dir, "pair.png", 2, 1) { ctx in
                ctx.setFillColor(red); ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
                ctx.setFillColor(blue); ctx.fill(CGRect(x: 1, y: 0, width: 1, height: 1))
            }
            let flipped = try rgba(Engine.flipImage(pair))
            check(flipped.count == 8 && flipped[2] > 200 && flipped[0] < 60, "Flip puts the right-hand pixel on the left (got \(flipped))")

            // A 10×6 black block, 12px in and 8px down, on a 40×30 white sheet.
            let sheet = try makePNG(in: dir, "sheet.png", 40, 30) { ctx in
                ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
                ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fill(CGRect(x: 12, y: 30 - 8 - 6, width: 10, height: 6))
            }
            let start = try Engine.cropPreview(sheet).start
            let block = CGRect(x: 12.0 / 40, y: 8.0 / 30, width: 10.0 / 40, height: 6.0 / 30)
            let startsOnInk = abs(start.minX - block.minX) < 0.01 && abs(start.minY - block.minY) < 0.01
                && abs(start.width - block.width) < 0.01 && abs(start.height - block.height) < 0.01
            check(startsOnInk, "the crop window starts from the trimmed edges (got \(start), want \(block))")
            let cut = try Engine.crop(sheet, to: block)
            let size = Engine.pixelSize(cut)
            check(size?.0 == 10 && size?.1 == 6, "Crop cuts an image to the picked area (got \(String(describing: size)))")
            check(darkShare(try rgba(cut)) > 0.95, "Crop cuts at the picked place, not just the picked size")

            // Rotate turns clockwise: red|blue comes back as red over blue.
            let rotated = try Engine.rotateImage(pair)
            let upright = try rgba(rotated)
            check(Engine.pixelSize(rotated).map { $0 == (1, 2) } == true && upright[0] > 200 && upright[2] < 60,
                  "Rotate turns clockwise (got \(upright))")

            // An iPhone-style photo stored sideways with an orientation tag comes out upright, tag reset.
            let sideways = dir.appendingPathComponent("sideways.jpg")
            try Engine.writeImage(Engine.flatten(Engine.loadImage(pair)), to: sideways, uti: "public.jpeg", quality: 1,
                                  props: [kCGImagePropertyOrientation: 6])
            let straightened = try Engine.convertImage(sideways, uti: "public.png", ext: "png")
            let tag = CGImageSourceCreateWithURL(straightened as CFURL, nil)
                .flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }?[kCGImagePropertyOrientation] as? Int ?? 1
            check(Engine.pixelSize(straightened).map { $0 == (1, 2) } == true && tag == 1,
                  "a photo tagged as turned comes out upright with the tag reset (got \(String(describing: Engine.pixelSize(straightened))), tag \(tag))")

            // Pictures over 2000px are scanned smaller; the box found must still land on the ink.
            let wide = try makePNG(in: dir, "wide.png", 4000, 300) { ctx in
                ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 4000, height: 300))
                ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fill(CGRect(x: 1000, y: 300 - 100 - 50, width: 500, height: 50))
            }
            let found = try Engine.contentRect(Engine.loadImage(wide)) ?? .zero
            let onInk = abs(found.minX - 1000) <= 4 && abs(found.minY - 100) <= 4 && abs(found.width - 500) <= 8 && abs(found.height - 50) <= 8
            check(onInk, "the trimmed edges of a big picture land on the ink (got \(found))")

            // 1080p fits inside 1920×1080 whichever way the photo is turned: 40×30 inside 16×9 is 12×9.
            let fitted = try Engine.pixelSize(Engine.resizeImage(sheet, fitting: 16, 9))
            check(fitted.map { $0 == (12, 9) } == true, "1080p fits both sides (got \(String(describing: fitted)))")

            // Transparency is judged from the original file, so a RAW photo isn't turned into a PNG.
            check(!Engine.sourceHasAlpha(at("shot.nef")) && !Engine.sourceHasAlpha(sideways) && Engine.sourceHasAlpha(pair),
                  "RAW and JPEG count as opaque, a transparent PNG doesn't")

            // An animated GIF is refused by image tools rather than quietly cut down to one frame.
            // Two different frames with a delay, like a real animation (identical frames can be merged into one).
            let anim = dir.appendingPathComponent("anim.gif")
            let second = try makePNG(in: dir, "second.png", 2, 1) { ctx in
                ctx.setFillColor(blue); ctx.fill(CGRect(x: 0, y: 0, width: 2, height: 1))
            }
            let delay = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary
            if let gif = CGImageDestinationCreateWithURL(anim as CFURL, "com.compuserve.gif" as CFString, 2, nil) {
                CGImageDestinationAddImage(gif, try Engine.flatten(Engine.loadImage(pair)), delay)
                CGImageDestinationAddImage(gif, try Engine.flatten(Engine.loadImage(second)), delay)
                CGImageDestinationFinalize(gif)
            }
            let frames = CGImageSourceCreateWithURL(anim as CFURL, nil).map(CGImageSourceGetCount) ?? 0
            check(frames == 2, "the test GIF has two frames (got \(frames))")
            check((try? Engine.rotateImage(anim)) == nil, "Rotate refuses an animated GIF")

            // One broken file in a batch: the rest still run, and the error says how far it got.
            let broken = dir.appendingPathComponent("broken.png")
            fm.createFile(atPath: broken.path, contents: Data("not a picture".utf8))
            do {
                _ = try Catalog.each(Engine.flipImage)([broken, pair])
                failures.append("a batch with a broken file must report it")
            } catch let partial as PartialFailure {
                check(partial.made.count == 1 && partial.message.hasPrefix("1 of 2 done"), "a batch reports how far it got (got \(partial.message))")
            } catch {
                failures.append("a batch with a broken file reports how far it got (got \(error.localizedDescription))")
            }

            // A multi-page export that fails part-way leaves no half-filled folder.
            let pages = try Engine.folder(sheet, suffix: " pages")
            fm.createFile(atPath: pages.appendingPathComponent("sheet 1.png").path, contents: Data([1]))
            _ = try? Engine.producing(pages) { throw ConvmogError("disk full") }
            check(!fm.fileExists(atPath: pages.path), "a failed multi-page export removes its folder")

            // .ts is a video only when the bytes are a transport stream; otherwise it's TypeScript.
            let code = dir.appendingPathComponent("app.ts")
            try "export const answer = 42\n".write(to: code, atomically: true, encoding: .utf8)
            var packets = [UInt8](repeating: 0, count: 376)
            packets[0] = 0x47
            packets[188] = 0x47
            let stream = dir.appendingPathComponent("clip.ts")
            try Data(packets).write(to: stream)
            check(Catalog.kind(code) == .other && !Catalog.wantsFFmpeg([code]) && Catalog.kind(stream) == .video,
                  "TypeScript isn't mistaken for video, a transport stream is video")

            // A PDF page shown upright or turned: pick the block as it's shown, and the cropped page shows only the block.
            let pdf = try Engine.mergeToPDF([sheet])
            for degrees in [0, 90, 180, 270] {
                let doc = try Engine.openPDF(pdf)
                doc.page(at: 0)?.rotation = degrees
                let turned = try Engine.writePDF(doc, to: dir.appendingPathComponent("turned-\(degrees).pdf"))
                let picked = try Engine.cropPreview(turned).start
                guard let page = try Engine.openPDF(Engine.crop(turned, to: picked)).page(at: 0) else {
                    failures.append("the cropped \(degrees)° PDF has no page")
                    continue
                }
                let ink = darkShare(try rgba(Engine.render(page)))
                check(ink > 0.85, "a page turned \(degrees)° crops to what was picked (\(Int(ink * 100))% of it is the block)")
            }
        } catch {
            failures.append("engine check threw: \(error.localizedDescription)")
        }

        print(failures.isEmpty ? "selftest: ok" : "selftest: FAILED\n  " + failures.joined(separator: "\n  "))
        return failures.isEmpty
    }

    private static func makePNG(in dir: URL, _ name: String, _ w: Int, _ h: Int, _ paint: (CGContext) -> Void) throws -> URL {
        let ctx = try Engine.canvas(w, h)
        paint(ctx)
        guard let image = ctx.makeImage() else { throw ConvmogError("couldn't draw \(name)") }
        let url = dir.appendingPathComponent(name)
        try Engine.writeImage(image, to: url, uti: "public.png")
        return url
    }

    /// The share of pixels that are near black.
    private static func darkShare(_ bytes: [UInt8]) -> Double {
        var dark = 0
        for i in stride(from: 0, to: bytes.count, by: 4) where bytes[i] < 80 && bytes[i + 1] < 80 && bytes[i + 2] < 80 { dark += 1 }
        return bytes.isEmpty ? 0 : Double(dark) / Double(bytes.count / 4)
    }

    /// The file's pixels as sRGB RGBA bytes, top row first.
    private static func rgba(_ url: URL) throws -> [UInt8] {
        try rgba(Engine.loadImage(url))
    }

    private static func rgba(_ image: CGImage) throws -> [UInt8] {
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { throw ConvmogError("couldn't read the test picture") }
        return bytes
    }
}
