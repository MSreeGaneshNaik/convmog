import AppKit
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

        // The real engine, on real files: Flip mirrors, Crop trims to the ink.
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
            let cropped = try Engine.cropImage(sheet)
            let size = Engine.pixelSize(cropped)
            check(size?.0 == 10 && size?.1 == 6, "Crop trims an image to its ink (got \(String(describing: size)))")

            let pdf = try Engine.cropPDF(Engine.mergeToPDF([sheet]))
            let crop = try Engine.openPDF(pdf).page(at: 0)?.bounds(for: .cropBox) ?? .zero
            let want = CGRect(x: 10, y: 14, width: 14, height: 10)   // the block in PDF points, plus 2pt of air
            let near = abs(crop.minX - want.minX) < 1.5 && abs(crop.minY - want.minY) < 1.5
                && abs(crop.width - want.width) < 1.5 && abs(crop.height - want.height) < 1.5
            check(near, "Crop trims a PDF page to its ink (got \(crop), want \(want))")
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

    /// The file's pixels as sRGB RGBA bytes, top row first.
    private static func rgba(_ url: URL) throws -> [UInt8] {
        let image = try Engine.loadImage(url)
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { throw ConvmogError("couldn't read \(url.lastPathComponent)") }
        return bytes
    }
}
