import TVServices
import SwiftUI

// Top Shelf: when Solar is in focus on the Apple TV Home Screen, the banner shows the live
// number and today's curve, drawn here into an image, without opening the app.

final class ContentProvider: TVTopShelfContentProvider {
    override func loadTopShelfContent() async -> (any TVTopShelfContent)? {
        guard let s = await Snapshot.build() ?? Snapshot.cached() else { return nil }
        s.cache()
        guard let url = await render(s) else { return nil }
        let item = TVTopShelfItem(identifier: "now")
        item.title = "\(SK.kw(s.nowKw)) kW now · \(SK.kwh(s.todayKwh)) kWh today"
        item.setImageURL(url, for: .screenScale1x)
        item.setImageURL(url, for: .screenScale2x)
        item.displayAction = TVTopShelfAction(url: URL(string: "solar://now")!)
        return TVTopShelfInsetContent(items: [item])
    }

    @MainActor private func render(_ s: Snapshot) -> URL? {
        let r = ImageRenderer(content: Banner(s: s).frame(width: 1940, height: 692))
        r.scale = 1
        guard let img = r.uiImage, let png = img.pngData() else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("topshelf-\(Int(Date().timeIntervalSince1970)).png")
        try? png.write(to: url)
        return url
    }
}

struct Banner: View {
    let s: Snapshot
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(red: 0.07, green: 0.07, blue: 0.08)
            Canvas { ctx, size in
                let pts = s.curve.filter { $0.count > 1 }
                guard pts.count > 1 else { return }
                let h0 = 6.5, h1 = 18.5, mx = max(pts.map { $0[1] }.max() ?? 1, 0.5)
                let X = { (h: Double) in CGFloat((h - h0) / (h1 - h0)) * size.width }
                let Y = { (v: Double) in size.height - 40 - CGFloat(v / mx) * (size.height - 300) }
                var line = Path(), area = Path()
                area.move(to: CGPoint(x: X(pts[0][0]), y: Y(0)))
                for (i, p) in pts.enumerated() {
                    let c = CGPoint(x: X(p[0]), y: Y(p[1]))
                    if i == 0 { line.move(to: c) } else { line.addLine(to: c) }
                    area.addLine(to: c)
                }
                area.addLine(to: CGPoint(x: X(pts[pts.count - 1][0]), y: Y(0))); area.closeSubpath()
                ctx.fill(area, with: .color(Color(red: 1, green: 0.62, blue: 0.04).opacity(0.25)))
                ctx.stroke(line, with: .color(Color(red: 1, green: 0.62, blue: 0.04)), lineWidth: 6)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Solar").font(.system(size: 40, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Text(SK.kw(s.nowKw)).font(.system(size: 150, weight: .bold)).foregroundStyle(.white)
                    Text("kW now").font(.system(size: 44, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                }
                Text("\(SK.kwh(s.todayKwh)) kWh today\(s.expectedKwh.map { ", of \(SK.kwh($0)) expected" } ?? "")")
                    .font(.system(size: 40)).foregroundStyle(Color(red: 1, green: 0.62, blue: 0.04))
            }
            .padding(70)
        }
    }
}
