import Foundation

/// `Morph --selftest` checks what a wrong drop would depend on: wedge maths, naming, file kinds.
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
        let dir = fm.temporaryDirectory.appendingPathComponent("morph-selftest-\(UUID().uuidString)")
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

        print(failures.isEmpty ? "selftest: ok" : "selftest: FAILED\n  " + failures.joined(separator: "\n  "))
        return failures.isEmpty
    }
}
