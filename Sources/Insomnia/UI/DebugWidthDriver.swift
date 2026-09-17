import AppKit
import QuartzCore

/// TEMPORARY diagnostic: drives the status item's length along a named curve
/// on request (distributed notification), so Control Center's relayout of
/// the neighbours can be measured against known write patterns.
@MainActor
final class DebugWidthDriver: NSObject {
    private let item: NSStatusItem
    private var link: CADisplayLink?
    private var start: CFTimeInterval = 0
    private var from: CGFloat = 0, to: CGFloat = 0, dur: Double = 0.5, mode = "linear"
    private var writes: [(Double, CGFloat)] = []
    private var fpsValue: Float = 120

    init(item: NSStatusItem) {
        self.item = item
        super.init()
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(request(_:)), name: Notification.Name("com.kgarg.insomnia.debug.width"), object: nil)
    }

    @objc private func request(_ note: Notification) {
        let info = note.userInfo ?? [:]
        MainActor.assumeIsolated {
            mode = info["mode"] as? String ?? "linear"
            dur = Double(info["dur"] as? String ?? "0.5") ?? 0.5
            to = CGFloat(Double(info["to"] as? String ?? "226") ?? 226)
            let fps = Float(info["fps"] as? String ?? "120") ?? 120
            fpsValue = fps
            from = item.length
            writes = []
            link?.invalidate()
            start = CACurrentMediaTime()
            try? String(format: "anim start wall %.3f", Date().timeIntervalSince1970).write(toFile: "/tmp/cctest/anim-start.txt", atomically: true, encoding: .utf8)
            let l = (item.button?.window?.screen ?? NSScreen.main)!.displayLink(target: self, selector: #selector(step(_:)))
            l.preferredFrameRateRange = CAFrameRateRange(minimum: fps, maximum: fps, preferred: fps)
            l.add(to: .main, forMode: .common)
            link = l
        }
    }

    private func curve(_ p: Double) -> CGFloat {
        let x: Double
        switch mode {
        case "linear": x = p
        case "easeout": x = 1 - pow(1 - p, 3)
        case "spring":
            let w = 2 * Double.pi / dur, z = 0.92, wd = w * sqrt(1 - z * z), t = p * dur * 1.2
            x = 1 - exp(-z * w * t) * (cos(wd * t) + (z * w / wd) * sin(wd * t))
        default: x = p < 0.5 ? 0 : 1
        }
        return from + (to - from) * CGFloat(x)
    }

    @objc private func step(_ l: CADisplayLink) {
        MainActor.assumeIsolated {
            let p = min(Double(writes.count + 1) / (dur * Double(fpsValue)), 1)
            let v = p >= 1 ? to : (curve(p) * 2).rounded() / 2
            item.length = v
            writes.append((Date().timeIntervalSince1970, v))
            if p >= 1 {
                l.invalidate(); link = nil
                let t0 = writes[0].0
                Log.info("debug width \(mode) \(dur)s: \(writes.count) writes: " + writes.map { String(format: "%.0f@%.0f", $0.1, ($0.0 - t0) * 1000) }.joined(separator: " "))
            }
        }
    }
}
