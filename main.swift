// dopa-macbook — 打鍵するたびにMac全体がドパガキになるオーバーレイ
import Cocoa
import QuartzCore
import ApplicationServices
import AVFoundation
import ScreenCaptureKit

// MARK: - 調整用パラメータ

enum Tune {
    static let comboTimeout = 2.5  // これ以上手が止まるとCOMBO BREAK
    static let feverDuration = 20.0 // FEVER TIMEの長さ（秒）
}

func after(_ s: Double, _ f: @escaping @MainActor () -> Void) {
    DispatchQueue.main.asyncAfter(deadline: .now() + s) { MainActor.assumeIsolated { f() } }
}

// MARK: - 色・文字・画像

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a)
}

let gold = rgb(1, 0.82, 0.2)
let rainbowFill = [rgb(1, 0.2, 0.2), rgb(1, 0.6, 0), rgb(1, 0.95, 0.1), rgb(0.2, 0.9, 0.3), rgb(0.2, 0.7, 1), rgb(0.7, 0.3, 1)]

func roundedFont(_ size: CGFloat) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: .black)
    guard let d = base.fontDescriptor.withDesign(.rounded), let f = NSFont(descriptor: d, size: size) else { return base }
    return f
}

struct TextStyle {
    var size: CGFloat
    var fill: [NSColor]          // 1色ならベタ塗り、複数ならグラデーション
    var stroke: NSColor
    var strokeRatio: CGFloat = 8 // フォントサイズに対する縁取りの太さ(%)
    var glow: NSColor? = nil
    var glowRadius: CGFloat = 20
    var horizontal = false       // グラデーションを左→右にする（既定は上→下）
    var font: String? = nil      // 書体名。nil なら丸ゴシック
    var skew: CGFloat = 0        // 斜体の傾き（0.2 で約11度右に倒す）
}

/// FEVER TIME用のイカした書体。日本語はヒラギノ角ゴの極太で受ける
let partyFont = "Futura-CondensedExtraBold"

func namedFont(_ name: String, _ size: CGFloat) -> NSFont {
    let base = NSFont(name: name, size: size) ?? roundedFont(size)
    let jp = NSFontDescriptor(name: "HiraginoSans-W9", size: size)
    return NSFont(descriptor: base.fontDescriptor.addingAttributes([.cascadeList: [jp]]), size: size) ?? base
}

/// 縁取り・グロー・グラデーション付きの文字をビットマップに描く
func renderText(_ text: String, _ st: TextStyle, scale: CGFloat) -> (CGImage, CGSize) {
    let font = st.font.map { namedFont($0, st.size) } ?? roundedFont(st.size)
    let pad = (st.glow != nil ? st.glowRadius * 1.6 : 4) + st.size * st.strokeRatio / 200 + 4
    let ts = NSAttributedString(string: text, attributes: [.font: font]).size()
    let size = CGSize(width: ceil(ts.width + abs(st.skew) * (ts.height + pad * 2) + pad * 2), height: ceil(ts.height + pad * 2))
    let pw = Int(size.width * scale), ph = Int(size.height * scale)
    let rgbSpace = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                        space: rgbSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: scale, y: scale)

    func draw(_ attrs: [NSAttributedString.Key: Any], in c: CGContext) {
        c.saveGState()
        // 下端を軸に上ほど右へずらして斜体にする
        c.concatenate(CGAffineTransform(a: 1, b: 0, c: st.skew, d: 1, tx: 0, ty: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: false)
        NSAttributedString(string: text, attributes: attrs).draw(at: NSPoint(x: pad, y: pad))
        NSGraphicsContext.restoreGraphicsState()
        c.restoreGState()
    }

    // 縁取り（とグロー）を先に描き、その上に本体を重ねる
    var outline: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: st.stroke,
                                                   .strokeColor: st.stroke, .strokeWidth: -st.strokeRatio]
    if let g = st.glow {
        let sh = NSShadow()
        sh.shadowColor = g
        sh.shadowBlurRadius = st.glowRadius
        sh.shadowOffset = .zero
        outline[.shadow] = sh
    }
    draw(outline, in: ctx)

    if st.fill.count == 1 {
        draw([.font: font, .foregroundColor: st.fill[0]], in: ctx)
    } else {
        let mctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                             space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        mctx.setFillColor(gray: 0, alpha: 1)
        mctx.fill(CGRect(x: 0, y: 0, width: pw, height: ph))
        mctx.scaleBy(x: scale, y: scale)
        draw([.font: font, .foregroundColor: NSColor.white], in: mctx)
        ctx.saveGState()
        ctx.clip(to: CGRect(origin: .zero, size: size), mask: mctx.makeImage()!)
        let grad = CGGradient(colorsSpace: rgbSpace, colors: st.fill.map { $0.cgColor } as CFArray, locations: nil)!
        let (from, to) = st.horizontal ? (CGPoint(x: pad, y: 0), CGPoint(x: size.width - pad, y: 0))
                                       : (CGPoint(x: 0, y: size.height - pad), CGPoint(x: 0, y: pad))
        ctx.drawLinearGradient(grad, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }
    return (ctx.makeImage()!, size)
}

func bitmap(_ w: Int, _ h: Int, _ draw: (CGContext) -> Void) -> CGImage {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    draw(ctx)
    return ctx.makeImage()!
}

let sparkImage = bitmap(32, 32) { ctx in
    let colors = [NSColor.white, rgb(1, 1, 1, 0.6), rgb(1, 1, 1, 0)].map { $0.cgColor } as CFArray
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.25, 1])!
    ctx.drawRadialGradient(grad, startCenter: CGPoint(x: 16, y: 16), startRadius: 0,
                           endCenter: CGPoint(x: 16, y: 16), endRadius: 16, options: [])
}

let starImg = bitmap(48, 48) { ctx in
    let c: CGFloat = 24, R: CGFloat = 23, r: CGFloat = 10
    for i in 0..<10 {
        let a = Double.pi / 2 + Double(i) * Double.pi / 5
        let rad = i % 2 == 0 ? R : r
        let pt = CGPoint(x: c + rad * cos(a), y: c + rad * sin(a))
        i == 0 ? ctx.move(to: pt) : ctx.addLine(to: pt)
    }
    ctx.closePath()
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fillPath()
}

let confettiImg = bitmap(16, 8) { ctx in
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 16, height: 8))
}

let goldCoin = bitmap(64, 64) { ctx in
    let colors = [rgb(1, 1, 0.85), gold, rgb(0.6, 0.35, 0)].map { $0.cgColor } as CFArray
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.5, 1])!
    ctx.addEllipse(in: CGRect(x: 0.5, y: 0.5, width: 63, height: 63))
    ctx.clip()
    ctx.drawRadialGradient(grad, startCenter: CGPoint(x: 22, y: 42), startRadius: 0,
                           endCenter: CGPoint(x: 32, y: 32), endRadius: 32, options: [.drawsAfterEndLocation])
}

let flareImg = bitmap(256, 256) { ctx in
    ctx.setShadow(offset: .zero, blur: 14, color: CGColor(gray: 1, alpha: 1))
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
    ctx.setLineCap(.round)
    for (len, width, angle) in [(120.0, 3.0, 0.0), (120.0, 3.0, Double.pi / 2), (60.0, 1.5, Double.pi / 4), (60.0, 1.5, -Double.pi / 4)] {
        ctx.setLineWidth(width)
        ctx.move(to: CGPoint(x: 128 - len * cos(angle), y: 128 - len * sin(angle)))
        ctx.addLine(to: CGPoint(x: 128 + len * cos(angle), y: 128 + len * sin(angle)))
        ctx.strokePath()
    }
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: 120, y: 120, width: 16, height: 16))
}

func ringPath(_ b: CGRect, _ width: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.addRect(b)
    let i = b.insetBy(dx: width, dy: width)
    p.move(to: CGPoint(x: i.minX, y: i.minY))
    p.addLine(to: CGPoint(x: i.minX, y: i.maxY))
    p.addLine(to: CGPoint(x: i.maxX, y: i.maxY))
    p.addLine(to: CGPoint(x: i.maxX, y: i.minY))
    p.closeSubpath()
    return p
}

// MARK: - 画面ごとの透明オーバーレイ

final class OverlayWindow: NSWindow {
    let root = CALayer()
    let screenRef: NSScreen
    var comboLabel: CALayer?
    var rankFrame: CALayer?   // 縁の光（太線＋細線の2本の枠）
    var laserTier = 0
    var lasers: [CALayer] = []
    var spots: [CALayer] = []
    var feverLayers: [CALayer] = []
    var heads: [CALayer] = []  // 上から照らすムービングライト

    init(screen: NSScreen) {
        screenRef = screen
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        let v = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        v.layer = root
        v.wantsLayer = true
        contentView = v
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        animationBehavior = .none
        setFrame(screen.frame, display: false)
        root.contentsScale = screen.backingScaleFactor
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    var scale: CGFloat { screenRef.backingScaleFactor }
    var center: CGPoint { CGPoint(x: root.bounds.midX, y: root.bounds.midY) }
    func toLocal(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x - frame.minX, y: p.y - frame.minY) }
}

// MARK: - 効果音（すべてその場で合成）

enum Wave { case square, triangle, noise }

struct Tone {
    var f0: Double
    var f1: Double? = nil
    var dur: Double
    var wave: Wave = .square
    var vol: Double = 0.2
    var decay: Double = 0
    var chord: [Double] = [1]
    var gap: Double = 0
}

@MainActor
final class Sound {
    var enabled = true
    static let keyPitches = 6
    private let engine = AVAudioEngine()
    private var players: [AVAudioPlayerNode] = []
    private var next = 0
    private var buffers: [String: AVAudioPCMBuffer] = [:]
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
    static let bpm = 140.0
    private let musicPlayer = AVAudioPlayerNode()
    private var music: AVAudioPCMBuffer?
    private var musicGen = 0

    init() {
        engine.attach(musicPlayer)
        engine.connect(musicPlayer, to: engine.mainMixerNode, format: format)
        for _ in 0..<12 {
            let p = AVAudioPlayerNode()
            engine.attach(p)
            engine.connect(p, to: engine.mainMixerNode, format: format)
            players.append(p)
        }
        engine.mainMixerNode.outputVolume = 0.6

        let C5 = 523.25, E5 = 659.25, G5 = 783.99, C6 = 1046.5, B5 = 987.77, E6 = 1318.5, G6 = 1567.98
        let major = [1, 1.2599, 1.4983]
        // 打鍵音はコンボが伸びるほど高くなる（ペンタトニック）
        for (i, f) in [880.0, 988, 1109, 1319, 1480, 1760].enumerated() {
            buffers["key\(i)"] = synth([Tone(f0: f, dur: 0.04, vol: 0.07, decay: 45)])
        }
        buffers["nice"] = synth([Tone(f0: G6, dur: 0.05, vol: 0.13, decay: 20), Tone(f0: C6 * 2, dur: 0.08, vol: 0.13, decay: 20)])
        buffers["coin"] = synth([Tone(f0: B5, dur: 0.06, vol: 0.13), Tone(f0: E6, dur: 0.22, vol: 0.13, decay: 10)])
        buffers["break"] = synth([Tone(f0: 392, dur: 0.12, wave: .triangle, vol: 0.35, gap: 0.02),
                                  Tone(f0: 330, f1: 250, dur: 0.4, wave: .triangle, vol: 0.35, decay: 3)])
        buffers["launch"] = synth([Tone(f0: 400, f1: 1400, dur: 0.6, wave: .triangle, vol: 0.05)])
        buffers["boom"] = synth([Tone(f0: 0, dur: 0.45, wave: .noise, vol: 0.3, decay: 7)])
        buffers["milestone"] = synth([E6, G6, E6 * 2, G6 * 2].map { Tone(f0: $0, dur: 0.06, vol: 0.13) }
            + [Tone(f0: C6 * 2, dur: 0.3, vol: 0.13, decay: 6)])
        buffers["fanfare"] = synth([C5, E5, G5, C6].map { Tone(f0: $0, dur: 0.08, vol: 0.18) } + [
            Tone(f0: G5, dur: 0.1, vol: 0.18, chord: major, gap: 0.04),
            Tone(f0: G5, dur: 0.1, vol: 0.18, chord: major, gap: 0.04),
            Tone(f0: C6, dur: 1.0, vol: 0.2, decay: 1.2, chord: major),
        ])
    }

    private func synth(_ tones: [Tone]) -> AVAudioPCMBuffer {
        let sr = format.sampleRate
        let n = Int(tones.reduce(0) { $0 + $1.dur + $1.gap } * sr) + 1
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
        buf.frameLength = AVAudioFrameCount(n)
        let out = buf.floatChannelData![0]
        for i in 0..<n { out[i] = 0 }
        var idx = 0
        for t in tones {
            let len = Int(t.dur * sr)
            var phases = [Double](repeating: 0, count: t.chord.count)
            for i in 0..<len where idx + i < n {
                let time = Double(i) / sr
                let f = t.f0 + ((t.f1 ?? t.f0) - t.f0) * (time / t.dur)
                var s = 0.0
                for (c, ratio) in t.chord.enumerated() {
                    phases[c] += f * ratio / sr
                    let ph = phases[c] - floor(phases[c])
                    switch t.wave {
                    case .square: s += ph < 0.5 ? 1 : -1
                    case .triangle: s += 4 * abs(ph - 0.5) - 1
                    case .noise: s += Double.random(in: -1...1)
                    }
                }
                let env = min(1, time / 0.004) * min(1, (t.dur - time) / 0.01) * exp(-t.decay * time)
                out[idx + i] = Float(s / Double(t.chord.count) * env * t.vol)
            }
            idx += len + Int(t.gap * sr)
        }
        return buf
    }

    func play(_ name: String) {
        guard enabled, let b = buffers[name] else { return }
        if !engine.isRunning { try? engine.start() }
        guard engine.isRunning else { return }
        let p = players[next]
        next = (next + 1) % players.count
        p.stop()
        p.scheduleBuffer(b, at: nil, options: [], completionHandler: nil)
        p.play()
    }

    func hush() {
        players.forEach { $0.stop() }
        musicGen += 1
        musicPlayer.stop()
    }

    func startMusic() {
        guard enabled else { return }
        if music == nil { music = renderMusic() }
        if !engine.isRunning { try? engine.start() }
        guard engine.isRunning, let m = music else { return }
        musicGen += 1
        musicPlayer.stop()
        musicPlayer.volume = 0.9
        musicPlayer.scheduleBuffer(m, at: nil, options: .loops, completionHandler: nil)
        musicPlayer.play()
    }

    func stopMusic(fade: Double = 1.2) {
        musicGen += 1
        let g = musicGen, steps = 12
        for i in 1...steps {
            after(fade * Double(i) / Double(steps)) { [weak self] in
                guard let self, self.musicGen == g else { return }
                self.musicPlayer.volume = Float(0.9 * (1 - Double(i) / Double(steps)))
                if i == steps { self.musicPlayer.stop() }
            }
        }
    }

    /// 140BPM・4小節ループの4つ打ち（Am - F - C - G）。キックとベースを前に出した重いミックス
    private func renderMusic() -> AVAudioPCMBuffer {
        let sr = format.sampleRate
        let beat = 60 / Sound.bpm
        let bars = 4
        let n = Int(Double(bars * 4) * beat * sr)
        var kick = [Double](repeating: 0, count: n)
        var bass = [Double](repeating: 0, count: n)  // キックに合わせて深く沈める
        var top = [Double](repeating: 0, count: n)   // ハット・クラップ・コード。軽く沈める
        // ループの継ぎ目で途切れないよう、はみ出した分は先頭に回す
        func add(_ buf: inout [Double], at t: Double, dur: Double, _ f: (Double) -> Double) {
            let s0 = Int(t * sr)
            for i in 0..<Int(dur * sr) { buf[(s0 + i) % n] += f(Double(i) / sr) }
        }
        let roots = [55.0, 43.65, 65.41, 49.0]
        let chords = [[440.0, 523.25, 659.25], [349.23, 440, 523.25], [392.0, 523.25, 659.25], [392.0, 493.88, 587.33]]

        for b in 0..<(bars * 4) {
            let t0 = Double(b) * beat
            // キック：深く伸びるサブの胴鳴り＋「ドッ」のアタック＋歪み
            var kp = 0.0
            add(&kick, at: t0, dur: beat * 0.97) { t in
                kp += (50 + 130 * exp(-t * 30)) / sr
                let body = sin(2 * .pi * kp) * exp(-t * 4.5)
                let punch = sin(2 * .pi * 160 * t) * exp(-t * 35) * 0.5
                let click = t < 0.004 ? Double.random(in: -1...1) * 0.6 : 0
                return tanh(2.8 * (body + punch + click))
            }
            if b % 2 == 1 {
                add(&top, at: t0, dur: 0.18) { t in Double.random(in: -1...1) * exp(-t * 22) * 0.3 }
            }
            for (k, vol, len) in [(2, 0.2, 0.07), (1, 0.07, 0.03), (3, 0.07, 0.03)] {
                var prev = 0.0
                add(&top, at: t0 + beat * Double(k) / 4, dur: len) { t in
                    let x = Double.random(in: -1...1)
                    defer { prev = x }
                    return (x - prev) * exp(-t * 45) * vol
                }
            }
            // サブベース：拍いっぱい鳴らし続け、サイドチェインで「ズン、ズン」とうねらせる
            let root = roots[b / 4]
            var sp = 0.0
            add(&bass, at: t0, dur: beat) { t in
                sp += root / sr
                return sin(2 * .pi * sp) * min(1, t / 0.005) * min(1, (beat - t) / 0.005) * 0.6
            }
            // 裏のローリングベース（太く・歪ませて）
            for k in 1...3 {
                var ph = (0.0, 0.0), y = 0.0
                add(&bass, at: t0 + beat * Double(k) / 4, dur: beat / 4 * 0.95) { t in
                    ph.0 += root * 2 * 0.995 / sr
                    ph.1 += root * 2 * 1.005 / sr
                    let f0 = ph.0 - floor(ph.0), f1 = ph.1 - floor(ph.1)
                    let raw = (2 * f0 - 1) + (2 * f1 - 1) + 0.6 * (f0 < 0.5 ? 1 : -1)
                    y += 0.18 * (raw - y)
                    return tanh(3 * y) * exp(-t * 7) * 0.42
                }
            }
        }
        for bar in 0..<bars {
            let chord = chords[bar]
            for pos in [2, 6, 10, 14, 15] {
                var phs = [Double](repeating: 0, count: chord.count * 3)
                add(&top, at: Double(bar * 16 + pos) * beat / 4, dur: 0.22) { t in
                    var s = 0.0
                    for (ci, f) in chord.enumerated() {
                        for (d, det) in [0.993, 1.0, 1.007].enumerated() {
                            let k = ci * 3 + d
                            phs[k] += f * det / sr
                            s += 2 * (phs[k] - floor(phs[k])) - 1
                        }
                    }
                    return s / Double(phs.count) * exp(-t * 9) * 0.3
                }
            }
        }

        // ミックス：ベースは深く、上ものは軽く沈めるサイドチェイン → 歪ませて音圧を詰める
        var mix = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let tb = (Double(i) / sr).truncatingRemainder(dividingBy: beat)
            let bassDuck = 0.08 + 0.92 * (1 - exp(-tb / 0.06))
            let topDuck = 0.3 + 0.7 * (1 - exp(-tb / 0.07))
            mix[i] = tanh(1.6 * (kick[i] + bass[i] * bassDuck + top[i] * topDuck))
        }
        let peak = max(mix.map(abs).max() ?? 1, 1e-6)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
        buf.frameLength = AVAudioFrameCount(n)
        let out = buf.floatChannelData![0]
        for i in 0..<n { out[i] = Float(mix[i] / peak * 0.95) }
        return buf
    }
}

// MARK: - 本体

@MainActor
final class Dopa: NSObject {
    enum TextAnim { case pop, drop }

    let sound = Sound()
    private var windows: [OverlayWindow] = []
    private(set) var enabled: Bool
    private(set) var combo = 0
    private var lastKey: CFTimeInterval = 0
    private var lastPoint = CGPoint.zero
    private var frameKey: String?
    private var gen = 0  // 無効化・画面構成変更で予約済みの演出を捨てるための世代番号
    private var seenKeywords: [String] = []
    private var textCache: [String: (CGImage, CGSize)] = [:]
    private var emojiCache: [String: CGImage] = [:]
    private var glowCache: [String: CGImage] = [:]
    private var clubLevel = 0
    private var neonIndex = 0
    private var feverUntil: CFTimeInterval?
    private var beatTimer: Timer?
    private var beatCount = 0
    var inFever: Bool { feverUntil != nil }
    private static let neon = [rgb(0.2, 1, 0.35), rgb(1, 0.2, 0.9), rgb(0.2, 0.9, 1), rgb(1, 0.15, 0.25), rgb(0.35, 0.45, 1), rgb(1, 0.9, 0.2)]
    var onComboChange: (() -> Void)?

    override init() {
        enabled = UserDefaults.standard.object(forKey: "enabled") as? Bool ?? true
        super.init()
        sound.enabled = UserDefaults.standard.object(forKey: "sound") as? Bool ?? true
        buildWindows()
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let t = Timer(timeInterval: 1.0 / 30, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
    }

    // MARK: 設定

    func setEnabled(_ on: Bool) {
        enabled = on
        UserDefaults.standard.set(on, forKey: "enabled")
        gen += 1
        stopFever()
        clearComboFX()
        if !on { sound.hush() }
        windows.forEach { on ? $0.orderFrontRegardless() : $0.orderOut(nil) }
        onComboChange?()
    }

    func setSound(_ on: Bool) {
        sound.enabled = on
        UserDefaults.standard.set(on, forKey: "sound")
        if !on { sound.hush() }
    }

    /// 録画モード用。保存されている設定は書き換えずに、このときだけ演出と音をオンにする
    func enableTemporarily() {
        sound.enabled = true
        guard !enabled else { return }
        enabled = true
        windows.forEach { $0.orderFrontRegardless() }
        onComboChange?()
    }

    /// 許可なしでも見た目を確認できるよう、連打を再現する
    func demo(keys: Int) {
        guard enabled else { return }
        let g = gen
        for i in 0..<keys {
            after(Double(i) * 0.07) { [weak self] in
                guard let self, self.enabled, self.gen == g else { return }
                self.hit(at: nil)
            }
        }
    }

    @objc private func screensChanged() { buildWindows() }

    private func buildWindows() {
        stopFever()
        windows.forEach { $0.orderOut(nil) }
        windows = NSScreen.screens.map { OverlayWindow(screen: $0) }
        gen += 1
        frameKey = nil
        clubLevel = 0
        updateRankFrame()
        updateClub()
        if enabled { windows.forEach { $0.orderFrontRegardless() } }
    }

    // MARK: 入力

    func handleKey(_ e: NSEvent) {
        let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if e.keyCode == 35, mods.isSuperset(of: [.control, .option, .command]) {  // ⌃⌥⌘P
            setEnabled(!enabled)
            return
        }
        guard enabled, !mods.contains(.command), !e.isARepeat else { return }
        hit(at: caretPoint())
        after(0.08) { [weak self] in self?.checkKeywords() }
    }

    /// カーソル位置が取れたらそこ、取れなければマウスのある画面のランダムな位置に出す
    private func hit(at caret: CGPoint?) {
        let p = caret ?? randomPoint()
        let now = CACurrentMediaTime()
        combo = now - lastKey < Tune.comboTimeout ? combo + 1 : 1
        lastKey = now
        lastPoint = p
        sound.play("key\(min(combo / 10, Sound.keyPitches - 1))")
        if let w = windowAt(p) {
            let lp = w.toLocal(p)
            let c = CGFloat(min(combo, 60))
            starBurst(at: lp, in: w, count: 14 + Int(c), speed: 150 + c * 4)
            flare(at: lp, in: w, color: rankColor(combo), size: 260 + c * 5)
            if combo % 5 == 0 { ring(at: lp, in: w, color: rankColor(combo), radius: 40, maxScale: 2.4, life: 0.5) }
            showCombo(at: lp, in: w)
        }
        if isMilestone(combo) { milestone(combo) }
        updateRankFrame()
        updateClub()
        if clubLevel >= 4 && !inFever { recolorLasers() }
        windows.forEach { $0.lasers.forEach(pulse) }
        if !inFever { pulseFrame() }
        onComboChange?()
    }

    private func windowAt(_ p: CGPoint) -> OverlayWindow? { windows.first { $0.frame.contains(p) } }

    /// レーザーや花火などの重い演出は、この画面だけに出す
    private var stageWindow: OverlayWindow? { windowAt(lastPoint) ?? windowAt(NSEvent.mouseLocation) ?? windows.first }

    private func randomPoint() -> CGPoint {
        let f = (windowAt(NSEvent.mouseLocation) ?? windows.first)?.frame ?? .zero
        let r = f.insetBy(dx: f.width * 0.15, dy: f.height * 0.15)
        return CGPoint(x: CGFloat.random(in: r.minX...r.maxX), y: CGFloat.random(in: r.minY...r.maxY))
    }

    private func focusedElement() -> AXUIElement? {
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.05)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let f = focused, CFGetTypeID(f) == AXUIElementGetTypeID() else { return nil }
        return (f as! AXUIElement)
    }

    private func selectedRange(_ el: AXUIElement) -> CFRange? {
        var range: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &range) == .success,
              let r = range, CFGetTypeID(r) == AXValueGetTypeID() else { return nil }
        var cf = CFRange()
        return AXValueGetValue(r as! AXValue, .cfRange, &cf) ? cf : nil
    }

    /// フォーカス中の文字カーソル位置（Cocoa座標）。取れないアプリでは nil
    private func caretPoint() -> CGPoint? {
        guard let el = focusedElement(), var cf = selectedRange(el), let rv = AXValueCreate(.cfRange, &cf) else { return nil }
        var bounds: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(el, kAXBoundsForRangeParameterizedAttribute as CFString, rv, &bounds) == .success,
              let b = bounds, CFGetTypeID(b) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(b as! AXValue, .cgRect, &rect), rect != .zero,
              let primary = NSScreen.screens.first else { return nil }
        let p = CGPoint(x: rect.maxX, y: primary.frame.height - rect.midY)
        return windowAt(p) != nil ? p : nil
    }

    /// カーソル直前の文字列と、その先頭位置
    private func textBeforeCaret(_ n: Int) -> (String, Int)? {
        guard let el = focusedElement(), let cf = selectedRange(el) else { return nil }
        let start = max(0, cf.location - n)
        var q = CFRange(location: start, length: cf.location - start)
        guard q.length > 0, let qv = AXValueCreate(.cfRange, &q) else { return nil }
        var str: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(el, kAXStringForRangeParameterizedAttribute as CFString, qv, &str) == .success,
              let s = str as? String else { return nil }
        return (s, start)
    }

    // MARK: コンボ

    private func rankName(_ n: Int) -> String {
        switch n {
        case ..<10: return "C"
        case ..<20: return "B"
        case ..<30: return "A"
        case ..<50: return "S"
        case ..<100: return "SS"
        default: return "SSS"
        }
    }

    private func rankColor(_ n: Int) -> NSColor {
        switch n {
        case ..<10: return rgb(0.3, 0.8, 1)
        case ..<20: return rgb(0.3, 1, 0.4)
        case ..<30: return rgb(1, 0.3, 0.85)
        case ..<50: return rgb(1, 0.8, 0.2)
        default: return rgb(1, 0.35, 0.1)
        }
    }

    private func showCombo(at p: CGPoint, in w: OverlayWindow) {
        for o in windows where o !== w {
            o.comboLabel?.removeFromSuperlayer()
            o.comboLabel = nil
        }
        let (img, sz) = renderText("\(combo) COMBO  \(rankName(combo))",
                                   TextStyle(size: 34 + CGFloat(min(combo, 80)) * 0.3,
                                             fill: [rgb(1, 0.97, 0.5), rgb(1, 0.65, 0.1), rgb(1, 0.35, 0.1)],
                                             stroke: rgb(0.25, 0.05, 0), strokeRatio: 14,
                                             glow: rankColor(combo), glowRadius: 14), scale: w.scale)
        let l: CALayer
        if let existing = w.comboLabel {
            l = existing
        } else {
            l = CALayer()
            l.anchorPoint = CGPoint(x: 0, y: 0.5)
            l.zPosition = 100
            w.root.addSublayer(l)
            w.comboLabel = l
        }
        let b = w.root.bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        l.contents = img
        l.contentsScale = w.scale
        l.bounds = CGRect(origin: .zero, size: sz)
        l.position = CGPoint(x: min(p.x + 24, b.maxX - sz.width - 10), y: min(p.y + 40, b.maxY - sz.height / 2 - 10))
        l.opacity = 1
        CATransaction.commit()
        l.removeAllAnimations()
        let s = CASpringAnimation(keyPath: "transform.scale")
        s.fromValue = 1.6
        s.toValue = 1
        s.damping = 9
        s.stiffness = 420
        s.duration = s.settlingDuration
        let r = CABasicAnimation(keyPath: "transform.rotation.z")
        r.fromValue = Double.random(in: -0.15...0.15)
        r.toValue = 0
        r.duration = 0.15
        l.add(s, forKey: "pop")
        l.add(r, forKey: "rot")
    }

    private func comboBreak() {
        let n = combo
        combo = 0
        updateRankFrame()
        updateClub()
        onComboChange?()
        if n >= 5 { sound.play("break") }
        for w in windows {
            guard let l = w.comboLabel else { continue }
            w.comboLabel = nil
            let pos = l.position
            l.removeFromSuperlayer()
            guard n >= 5 else { continue }
            let (img, sz) = renderText("COMBO BREAK", TextStyle(size: 40, fill: [rgb(0.85, 0.75, 1), rgb(0.5, 0.3, 0.9)],
                                                                 stroke: rgb(0.1, 0, 0.2), strokeRatio: 12,
                                                                 glow: rgb(0.6, 0.2, 1), glowRadius: 12), scale: w.scale)
            showImage(img, sz, in: w, at: CGPoint(x: pos.x + sz.width / 2, y: pos.y), anim: .drop, life: 1.2)
        }
    }

    private func clearComboFX() {
        combo = 0
        for w in windows {
            w.comboLabel?.removeFromSuperlayer()
            w.comboLabel = nil
        }
        updateRankFrame()
        updateClub()
    }

    /// 画面の縁の枠。ランクで色が変わり、S以上とFEVER中は虹色に回る
    /// （全画面の影のぼかしは重いので、太さの違う枠を2本重ねて光って見せる）
    private func updateRankFrame() {
        let key: String? = !enabled ? nil : inFever ? "FEVER" : combo >= 10 ? rankName(combo) : nil
        guard key != frameKey else { return }
        frameKey = key
        for w in windows {
            w.rankFrame?.removeFromSuperlayer()
            w.rankFrame = nil
            guard let key else { continue }
            let f = CALayer()
            f.frame = w.root.bounds
            f.zPosition = 90
            let col = rankColor(combo)
            for (width, alpha) in [(CGFloat(28), CGFloat(0.3)), (CGFloat(10), CGFloat(1))] {
                let b = CALayer()
                b.frame = f.bounds
                b.borderWidth = width
                b.borderColor = col.withAlphaComponent(alpha).cgColor
                b.setValue(width, forKey: "baseWidth")
                if key.hasPrefix("S") || key == "FEVER" {
                    let a = CAKeyframeAnimation(keyPath: "borderColor")
                    a.values = (rainbowFill + [rainbowFill[0]]).map { $0.withAlphaComponent(alpha).cgColor }
                    a.duration = key == "FEVER" ? 0.5 : key == "S" ? 2 : 1
                    a.repeatCount = .infinity
                    b.add(a, forKey: "rainbow")
                }
                f.addSublayer(b)
            }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 0.25
            f.add(fade, forKey: "in")
            w.root.addSublayer(f)
            w.rankFrame = f
        }
    }

    // MARK: 節目の演出

    private func isMilestone(_ n: Int) -> Bool { [10, 20, 30, 50, 75].contains(n) || (n >= 100 && n % 50 == 0) }

    private func milestone(_ n: Int) {
        let title: String
        switch n {
        case 10: title = "COMBO x10"
        case 20: title = "GREAT x20"
        case 30: title = "ON FIRE x30"
        case 50: title = "UNSTOPPABLE x50"
        case 75: title = "INSANE x75"
        default: title = "DOPAMINE x\(n)"
        }
        // 100コンボでFEVER TIME突入、FEVER中の節目は延長
        let fever = n >= 100 && !inFever
        if n >= 100 { startFever() }
        let banner = fever ? "FEVER TIME!!" : title
        sound.play(fever ? "boom" : "milestone")
        for w in [stageWindow].compactMap({ $0 }) {
            let b = w.root.bounds
            let life = fever ? 3.0 : 1.4
            dim(in: w, alpha: 0.35, life: life)
            flashLasers(in: w)
            flare(at: w.center, in: w, color: .white, size: 700)
            let (img, sz) = renderText(banner, TextStyle(size: min(b.width * (fever ? 0.13 : 0.1), fever ? 220 : 170),
                                                        fill: [rgb(1, 0.25, 0.3), rgb(1, 0.75, 0.1), rgb(0.95, 1, 0.2), rgb(0.3, 1, 0.45)],
                                                        stroke: rgb(0.15, 0.02, 0.1), strokeRatio: 8,
                                                        glow: rgb(1, 0.3, 0.6), glowRadius: 34, horizontal: true,
                                                        font: partyFont, skew: 0.2),
                                       scale: w.scale)
            if fever {
                slam(img, sz, in: w, at: CGPoint(x: b.midX, y: b.midY - b.height * 0.05), angle: 0.14, life: life)
            } else {
                showImage(img, sz, in: w, at: CGPoint(x: b.midX, y: b.midY - b.height * 0.08), anim: .pop, life: life, shake: true)
            }
            ring(at: w.center, in: w, color: .white, radius: 120, maxScale: 4, life: 0.8, width: 10)
            starBurst(at: w.center, in: w, count: 160, speed: 620, scale: 0.5, life: 1.3, gravity: -200)
            if n >= 30 {
                for i in 0..<(fever ? 16 : 8) { rocket(in: w, delay: 0.15 + Double(i) * 0.18 + Double.random(in: 0...0.12)) }
            }
            if fever {
                whiteFlash(in: w)
                sunburst(in: w, life: 4)
                confettiRain(in: w)
                for i in 0..<3 {
                    after(Double(i) * 0.22) { self.ring(at: w.center, in: w, color: i == 1 ? gold : .white, radius: 120, maxScale: 5, life: 0.9, width: 14) }
                }
            }
        }
    }

    // MARK: キーワード反応

    private struct Keyword {
        enum Kind { case rockets, hearts, critical, stars }
        let words: [String]
        let title: String
        let kind: Kind
        let fill: [NSColor]
        let glow: NSColor
    }

    private static let keywords: [Keyword] = [
        Keyword(words: ["完成", "できた", "shipped", "done"], title: "SHIPPED!", kind: .rockets,
                fill: [rgb(0.6, 0.9, 1), rgb(0.4, 0.4, 1), rgb(0.8, 0.3, 1)], glow: rgb(0.3, 0.5, 1)),
        Keyword(words: ["リリース", "デプロイ", "ローンチ", "release", "deploy", "launch"], title: "LAUNCH!!", kind: .rockets,
                fill: [rgb(0.7, 1, 1), rgb(0.1, 0.8, 1), rgb(0.1, 0.4, 1)], glow: rgb(0, 0.8, 1)),
        Keyword(words: ["好き", "すき", "愛してる", "love"], title: "LOVE ♡", kind: .hearts,
                fill: [rgb(1, 0.6, 0.75), rgb(1, 0.15, 0.35)], glow: rgb(1, 0.2, 0.5)),
        Keyword(words: ["最高", "天才", "優勝", "完璧", "神", "perfect"], title: "CRITICAL!!", kind: .critical,
                fill: [rgb(1, 0.95, 0.4), rgb(1, 0.5, 0.05), rgb(0.9, 0.1, 0.05)], glow: rgb(1, 0.4, 0)),
        Keyword(words: ["いいね", "ナイス", "えらい", "nice", "good"], title: "NICE!", kind: .stars,
                fill: [rgb(1, 1, 0.7), rgb(1, 0.85, 0.2)], glow: rgb(1, 0.8, 0.1)),
    ]

    private func checkKeywords() {
        guard enabled, let (tail, start) = textBeforeCaret(16) else { return }
        let lower = tail.lowercased() as NSString
        for k in Dopa.keywords {
            for word in k.words {
                let r = lower.range(of: word, options: .backwards)
                guard r.location != NSNotFound else { continue }
                let id = "\(word)@\(start + r.location)"  // 同じ箇所の同じ単語では1回だけ
                guard !seenKeywords.contains(id) else { continue }
                seenKeywords.append(id)
                if seenKeywords.count > 50 { seenKeywords.removeFirst() }
                keywordFX(k)
                return
            }
        }
    }

    private func keywordFX(_ k: Keyword) {
        guard let w = windowAt(lastPoint) else { return }
        let p = w.toLocal(lastPoint)
        let (img, sz) = renderText(k.title, TextStyle(size: 64, fill: k.fill, stroke: rgb(0.1, 0.02, 0.1), strokeRatio: 10,
                                                      glow: k.glow, glowRadius: 22), scale: w.scale)
        let b = w.root.bounds
        let at = CGPoint(x: min(max(p.x, sz.width / 2), b.maxX - sz.width / 2), y: min(p.y + 110, b.maxY - sz.height / 2))
        showImage(img, sz, in: w, at: at, anim: .pop, life: 1.4, shake: true)
        switch k.kind {
        case .rockets:
            sound.play("launch")
            emojiFlight(["🚀", "🚀", "🚀", "⭐️", "✨", "🛸"], in: w, count: 18)
        case .hearts:
            sound.play("coin")
            emojiRain(["😍", "💕", "💖", "❤️", "🥰", "💘"], from: p, in: w)
        case .critical:
            sound.play("boom")
            ring(at: p, in: w, color: rgb(1, 0.5, 0), radius: 60, maxScale: 4, life: 0.7, width: 12)
            after(0.12) { self.ring(at: p, in: w, color: rgb(1, 0.9, 0.3), radius: 60, maxScale: 3, life: 0.6, width: 8) }
            starBurst(at: p, in: w, count: 140, speed: 520, scale: 0.45, life: 1.1, gravity: -200)
        case .stars:
            sound.play("nice")
            emojiSpray(["⭐️", "✨", "🌟"], from: p, in: w)
        }
    }

    // MARK: 定期処理

    @objc private func tick() {
        if combo > 0, CACurrentMediaTime() - lastKey > Tune.comboTimeout { comboBreak() }
    }

    // MARK: クラブ演出

    /// 10〜: ムービングライトと反射光 / 20〜: 下からレーザー / 30〜: 上の両角からも＋スポットライト / 50〜とFEVER: 色が切り替わる
    private func updateClub() {
        let lvl = !enabled ? 0 : inFever || combo >= 50 ? 4 : combo >= 30 ? 3 : combo >= 20 ? 2 : combo >= 10 ? 1 : 0
        guard lvl != clubLevel else { return }
        clubLevel = lvl
        let stage = stageWindow
        for w in windows { applyClub(w === stage ? lvl : 0, to: w) }
        if lvl >= 4 { recolorLasers() }
    }

    private func applyClub(_ lvl: Int, to w: OverlayWindow) {
        if lvl == 0 {
            w.spots.forEach(fadeRemove)
            w.spots = []
        } else if w.spots.isEmpty {
            w.spots = (0..<3).map { makeSpot(in: w, color: Dopa.neon[($0 * 2) % Dopa.neon.count]) } + [reflections(in: w)]
        }
        if lvl >= 3, w.heads.isEmpty {
            w.heads = makeHeads(in: w)
        } else if lvl < 3 {
            w.heads.forEach(fadeRemove)
            w.heads = []
        }
        // レーザーの本数が変わる段階でだけ組み直す
        let tier = lvl >= 2 ? min(lvl, 3) : 0
        guard tier != w.laserTier else { return }
        w.laserTier = tier
        w.lasers.forEach(fadeRemove)
        w.lasers = []
        let b = w.root.bounds
        let len = hypot(b.width, b.height) * 1.1
        let col = Dopa.neon[neonIndex % Dopa.neon.count]
        if tier >= 2 {
            w.lasers.append(makeRig(in: w, at: CGPoint(x: b.midX, y: -10), angle: .pi / 2, count: 7, spread: 1.5,
                                    length: len, colors: [col], sweep: 0.35, period: 2.0))
        }
        if tier >= 3 {
            let c2 = Dopa.neon[(neonIndex + 1) % Dopa.neon.count]
            w.lasers.append(makeRig(in: w, at: CGPoint(x: -10, y: b.maxY + 10), angle: -.pi / 4, count: 5, spread: 0.9,
                                    length: len, colors: [c2], sweep: 0.3, period: 1.6))
            w.lasers.append(makeRig(in: w, at: CGPoint(x: b.maxX + 10, y: b.maxY + 10), angle: -3 * .pi / 4, count: 5, spread: 0.9,
                                    length: len, colors: [c2], sweep: 0.3, period: 1.8))
        }
    }

    private func makeRig(in w: OverlayWindow, at p: CGPoint, angle: Double, count: Int, spread: Double, length: CGFloat,
                         colors: [NSColor], sweep: Double, period: Double, opacity: Float = 0.6) -> CALayer {
        let rig = CALayer()
        rig.position = p
        rig.zPosition = 15
        rig.opacity = opacity
        for i in 0..<count {
            let beam = CAGradientLayer()
            beam.startPoint = CGPoint(x: 0.5, y: 0)
            beam.endPoint = CGPoint(x: 0.5, y: 1)
            beam.locations = [0, 0.3, 0.5, 0.7, 1]
            beam.anchorPoint = CGPoint(x: 0, y: 0.5)
            beam.bounds = CGRect(x: 0, y: 0, width: length, height: 14)
            beam.position = .zero
            let t = count == 1 ? 0 : Double(i) / Double(count - 1) - 0.5
            beam.transform = CATransform3DMakeRotation(angle + t * spread, 0, 0, 1)
            beam.setValue(t, forKey: "fanT")
            paint(beam, colors[i % colors.count])
            rig.addSublayer(beam)
        }
        let a = CABasicAnimation(keyPath: "transform.rotation.z")
        a.fromValue = -sweep
        a.toValue = sweep
        a.duration = period
        a.autoreverses = true
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        a.timeOffset = Double.random(in: 0..<period)
        rig.add(a, forKey: "sweep")
        let fadeIn = CABasicAnimation(keyPath: "opacity")
        fadeIn.fromValue = 0
        fadeIn.duration = 0.3
        rig.add(fadeIn, forKey: "in")
        w.root.addSublayer(rig)
        return rig
    }

    private func paint(_ beam: CAGradientLayer, _ c: NSColor) {
        beam.colors = [NSColor.clear, c.withAlphaComponent(0.8), NSColor.white, c.withAlphaComponent(0.8), NSColor.clear].map { $0.cgColor }
    }

    /// 打鍵・ビートに合わせてレーザーを一瞬明るくする
    private func pulse(_ rig: CALayer) {
        let a = CAKeyframeAnimation(keyPath: "opacity")
        a.values = [1, rig.opacity]
        a.duration = 0.2
        rig.add(a, forKey: "pulse")
    }

    private func recolorLasers() {
        neonIndex += 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for w in windows {
            for (r, rig) in w.lasers.enumerated() {
                for (i, beam) in (rig.sublayers ?? []).enumerated() {
                    guard let g = beam as? CAGradientLayer else { continue }
                    paint(g, Dopa.neon[(neonIndex + r + (inFever ? i : 0)) % Dopa.neon.count])
                }
            }
        }
        CATransaction.commit()
    }

    /// 節目で下の両角から一斉に照射
    private func flashLasers(in w: OverlayWindow) {
        let b = w.root.bounds
        let len = hypot(b.width, b.height) * 1.1
        let rigs = [
            makeRig(in: w, at: CGPoint(x: -10, y: -10), angle: .pi / 4, count: 9, spread: 1.3, length: len,
                    colors: Dopa.neon, sweep: 0.4, period: 0.45, opacity: 0.95),
            makeRig(in: w, at: CGPoint(x: b.maxX + 10, y: -10), angle: 3 * .pi / 4, count: 9, spread: 1.3, length: len,
                    colors: Dopa.neon.reversed(), sweep: 0.4, period: 0.5, opacity: 0.95),
        ]
        after(1.3) { rigs.forEach(self.fadeRemove) }
    }

    private func glowImage(_ c: NSColor) -> CGImage {
        let key = c.description
        if let g = glowCache[key] { return g }
        let img = bitmap(256, 256) { ctx in
            let colors = [c.withAlphaComponent(1), c.withAlphaComponent(0.35), c.withAlphaComponent(0)].map { $0.cgColor } as CFArray
            let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.3, 1])!
            ctx.drawRadialGradient(grad, startCenter: CGPoint(x: 128, y: 128), startRadius: 0,
                                   endCenter: CGPoint(x: 128, y: 128), endRadius: 128, options: [])
        }
        glowCache[key] = img
        return img
    }

    /// 画面を漂う色付きの光の玉
    private func makeSpot(in w: OverlayWindow, color: NSColor) -> CALayer {
        let b = w.root.bounds
        let size = min(b.width, b.height) * CGFloat.random(in: 0.6...0.9)
        let l = CALayer()
        l.contents = glowImage(color)
        l.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        l.zPosition = 5
        l.opacity = 0.2
        let pts = (0..<5).map { _ in NSValue(point: NSPoint(x: CGFloat.random(in: 0...b.width), y: CGFloat.random(in: 0...b.height))) }
        l.position = pts[0].pointValue
        let a = CAKeyframeAnimation(keyPath: "position")
        a.values = pts
        a.duration = Double.random(in: 5...8)
        a.autoreverses = true
        a.repeatCount = .infinity
        a.calculationMode = .cubic
        l.add(a, forKey: "move")
        let fadeIn = CABasicAnimation(keyPath: "opacity")
        fadeIn.fromValue = 0
        fadeIn.duration = 0.6
        l.add(fadeIn, forKey: "in")
        w.root.addSublayer(l)
        return l
    }

    /// 打った場所で光が膨らむブルーム＋十字のレンズフレア
    private func flare(at p: CGPoint, in w: OverlayWindow, color: NSColor, size: CGFloat) {
        let bloom = CALayer()
        bloom.contents = glowImage(color)
        bloom.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        bloom.position = p
        bloom.zPosition = 42
        bloom.opacity = 0
        let cross = CALayer()
        cross.contents = flareImg
        cross.bounds = CGRect(x: 0, y: 0, width: size * 1.2, height: size * 1.2)
        cross.position = p
        cross.zPosition = 43
        cross.opacity = 0
        for (l, rot) in [(bloom, 0.0), (cross, Double.random(in: 0.3...0.8))] {
            let s = CABasicAnimation(keyPath: "transform.scale")
            s.fromValue = 0.3
            s.toValue = 1.2
            let r = CABasicAnimation(keyPath: "transform.rotation.z")
            r.toValue = rot
            let o = CABasicAnimation(keyPath: "opacity")
            o.fromValue = 0.9
            o.toValue = 0
            let g = CAAnimationGroup()
            g.animations = [s, r, o]
            g.duration = 0.4
            g.timingFunction = CAMediaTimingFunction(name: .easeOut)
            w.root.addSublayer(l)
            l.add(g, forKey: nil)
            after(0.4) { l.removeFromSuperlayer() }
        }
    }

    private func fadeRemove(_ l: CALayer) {
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = l.presentation()?.opacity ?? l.opacity
        a.toValue = 0
        a.duration = 0.4
        a.fillMode = .forwards
        a.isRemovedOnCompletion = false
        l.add(a, forKey: "out")
        after(0.4) { l.removeFromSuperlayer() }
    }

    /// ミラーボールの反射光。画面上の中央を軸に、光の粒がぐるぐる回る
    private func reflections(in w: OverlayWindow) -> CALayer {
        let b = w.root.bounds
        let R = hypot(b.width, b.height)
        let c = CALayer()
        c.position = CGPoint(x: b.midX, y: b.maxY + 40)
        c.zPosition = 6
        let tints = [NSColor.white, NSColor.white] + Dopa.neon
        for _ in 0..<90 {
            let d = CALayer()
            let sz = CGFloat.random(in: 4...11)
            let r = R * sqrt(CGFloat.random(in: 0.02...1))
            let a = Double.random(in: 0..<(2 * .pi))
            d.bounds = CGRect(x: 0, y: 0, width: sz, height: sz)
            d.cornerRadius = sz / 2
            d.position = CGPoint(x: r * cos(a), y: r * sin(a))
            d.backgroundColor = tints.randomElement()!.withAlphaComponent(0.9).cgColor
            d.opacity = Float.random(in: 0.35...0.9)
            let tw = CABasicAnimation(keyPath: "opacity")
            tw.fromValue = d.opacity
            tw.toValue = 0.05
            tw.duration = Double.random(in: 0.4...1.4)
            tw.autoreverses = true
            tw.repeatCount = .infinity
            tw.timeOffset = Double.random(in: 0...2)
            d.add(tw, forKey: "twinkle")
            c.addSublayer(d)
        }
        let rot = CABasicAnimation(keyPath: "transform.rotation.z")
        rot.fromValue = 0
        rot.toValue = 2 * Double.pi
        rot.duration = 16
        rot.repeatCount = .infinity
        c.add(rot, forKey: "rot")
        let fadeIn = CABasicAnimation(keyPath: "opacity")
        fadeIn.fromValue = 0
        fadeIn.duration = 0.8
        c.add(fadeIn, forKey: "in")
        w.root.addSublayer(c)
        return c
    }

    /// 画面の上の縁から照らす円錐のスポットライト。2拍で1往復し、隣同士は逆向きに振って交差させる
    private func makeHeads(in w: OverlayWindow) -> [CALayer] {
        let b = w.root.bounds
        let n = 5
        let beat = 60 / Sound.bpm
        let L = b.height * 1.35
        let baseW = 2 * L * tan(0.13)
        return (0..<n).map { i in
            let head = CALayer()
            head.position = CGPoint(x: b.width * (0.1 + 0.8 * CGFloat(i) / CGFloat(n - 1)), y: b.maxY + 4)
            head.zPosition = 14
            head.opacity = 0.55
            let cone = CALayer()
            cone.anchorPoint = CGPoint(x: 0.5, y: 1)
            cone.bounds = CGRect(x: 0, y: 0, width: baseW, height: L)
            cone.position = .zero
            head.addSublayer(cone)
            let lens = CALayer()
            lens.contents = glowImage(.white)
            lens.bounds = CGRect(x: 0, y: 0, width: 70, height: 70)
            lens.position = .zero
            head.addSublayer(lens)
            paintHead(head, Dopa.neon[(neonIndex + i) % Dopa.neon.count])
            let amp = 0.55
            let a = CABasicAnimation(keyPath: "transform.rotation.z")
            a.fromValue = i % 2 == 0 ? -amp : amp
            a.toValue = i % 2 == 0 ? amp : -amp
            a.duration = beat * 2
            a.autoreverses = true
            a.repeatCount = .infinity
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            head.add(a, forKey: "swing")
            let fadeIn = CABasicAnimation(keyPath: "opacity")
            fadeIn.fromValue = 0
            fadeIn.duration = 0.4
            head.add(fadeIn, forKey: "in")
            w.root.addSublayer(head)
            return head
        }
    }

    private var coneCache: [String: CGImage] = [:]

    /// 頂点が上の円錐。色ごとに一度だけ描いて使い回す
    private func coneImage(_ c: NSColor) -> CGImage {
        let key = c.description
        if let img = coneCache[key] { return img }
        let img = bitmap(128, 512) { ctx in
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 64, y: 512))
            path.addLine(to: CGPoint(x: 0, y: 0))
            path.addLine(to: CGPoint(x: 128, y: 0))
            path.closeSubpath()
            ctx.addPath(path)
            ctx.clip()
            let colors = [c.withAlphaComponent(0.8), c.withAlphaComponent(0.28), c.withAlphaComponent(0)].map { $0.cgColor } as CFArray
            let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.4, 1])!
            ctx.drawLinearGradient(grad, start: CGPoint(x: 64, y: 512), end: CGPoint(x: 64, y: 0), options: [])
        }
        coneCache[key] = img
        return img
    }

    private func paintHead(_ head: CALayer, _ c: NSColor) {
        head.sublayers?.first?.contents = coneImage(c)
    }

    /// キックのたびに画面全体を色付きの光で一瞬照らす（1拍に1回まで）
    private func wash(in w: OverlayWindow, color: NSColor) {
        let l = CALayer()
        l.frame = w.root.bounds
        l.backgroundColor = color.cgColor
        l.opacity = 0
        l.zPosition = 8
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 0.2
        a.toValue = 0
        a.duration = 0.3
        a.timingFunction = CAMediaTimingFunction(name: .easeOut)
        w.root.addSublayer(l)
        l.add(a, forKey: nil)
        after(0.3) { l.removeFromSuperlayer() }
    }

    /// レーザーの扇を拍に合わせて一瞬大きく開いて戻す
    private func fanOpen(_ rig: CALayer, beat: Double) {
        for beam in rig.sublayers ?? [] {
            let t = beam.value(forKey: "fanT") as? Double ?? 0
            let a = CAKeyframeAnimation(keyPath: "transform.rotation.z")
            a.values = [0, t * 0.6, 0]
            a.keyTimes = [0, 0.25, 1]
            a.isAdditive = true
            a.duration = beat * 0.9
            a.timingFunctions = [.init(name: .easeOut), .init(name: .easeInEaseOut)]
            beam.add(a, forKey: "fan")
        }
    }

    /// 画面の縁の光を、キック（FEVER外では打鍵）に合わせて太くする
    private func pulseFrame() {
        for w in windows {
            for b in w.rankFrame?.sublayers ?? [] {
                let base = b.value(forKey: "baseWidth") as? CGFloat ?? 10
                let a = CAKeyframeAnimation(keyPath: "borderWidth")
                a.values = [base * 2.6, base]
                a.duration = 0.25
                a.timingFunction = CAMediaTimingFunction(name: .easeOut)
                b.add(a, forKey: "kick")
            }
        }
    }

    // MARK: FEVER TIME

    private func startFever() {
        let first = feverUntil == nil
        feverUntil = CACurrentMediaTime() + Tune.feverDuration
        guard first else { return }
        sound.startMusic()
        beatCount = 0
        let t = Timer(timeInterval: 60 / Sound.bpm, target: self, selector: #selector(feverBeat), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        beatTimer = t
        let stage = stageWindow
        for w in windows {
            let b = w.root.bounds
            w.feverLayers = [marquee(in: w, y: b.maxY - 120, life: nil, reverse: false),
                             marquee(in: w, y: 70, life: nil, reverse: true)]
            if w === stage { w.feverLayers += [sunburst(in: w, life: nil), confettiRain(in: w, continuous: true)] }
        }
        updateClub()
        updateRankFrame()
    }

    @objc private func feverBeat() {
        guard let until = feverUntil else { return }
        if CACurrentMediaTime() >= until { stopFever(); return }
        beatCount += 1
        recolorLasers()
        pulseFrame()
        let beat = 60 / Sound.bpm
        let col = Dopa.neon[beatCount % Dopa.neon.count]
        windows.forEach { wash(in: $0, color: col) }
        guard let w = stageWindow else { return }
        w.lasers.forEach(pulse)
        w.lasers.forEach { fanOpen($0, beat: beat) }
        if beatCount % 4 == 1 {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for (i, h) in w.heads.enumerated() { paintHead(h, Dopa.neon[(beatCount / 4 + i) % Dopa.neon.count]) }
            CATransaction.commit()
        }
        w.heads.forEach(pulse)
        let b = w.root.bounds
        let p = CGPoint(x: CGFloat.random(in: b.width * 0.1...b.width * 0.9), y: CGFloat.random(in: b.height * 0.2...b.height * 0.8))
        flare(at: p, in: w, color: col, size: 420)
        if beatCount % 2 == 0 { rocket(in: w, delay: 0, quiet: true) }
        if beatCount % 4 == 0 {
            ring(at: w.center, in: w, color: col, radius: 120, maxScale: 4, life: 0.8, width: 10)
            let q = CGPoint(x: CGFloat.random(in: b.width * 0.15...b.width * 0.85), y: CGFloat.random(in: b.height * 0.25...b.height * 0.75))
            starBurst(at: q, in: w, count: 70, speed: 500, scale: 0.45, life: 1.1, gravity: -200)
        }
        if beatCount % 8 == 0 {
            flashLasers(in: w)
            feverShout(in: w)
        }
        if beatCount % 8 == 4 { emojiFlight(["🔥", "💥", "⚡️", "🎉", "🪩"], in: w, count: 12) }
        if beatCount % 16 == 0 { whiteFlash(in: w) }
    }

    private func stopFever() {
        guard feverUntil != nil else { return }
        feverUntil = nil
        beatTimer?.invalidate()
        beatTimer = nil
        sound.stopMusic()
        for w in windows {
            w.feverLayers.forEach(fadeRemove)
            w.feverLayers = []
        }
        updateClub()
        updateRankFrame()
    }

    private static let shouts = [
        "FEVER!!", "DOPAMINE!!", "脳汁ドバドバ!!", "止まるな!!", "UNSTOPPABLE!!", "最強!!", "まだいける!!",
        "神!!", "優勝!!", "天才!!", "ぶち上げ!!", "限界突破!!", "覚醒!!", "無敵!!", "えぐい!!", "やばすぎ!!",
        "指が止まらねぇ!!", "ドーパミン全開!!", "LET'S GO!!", "HYPE!!", "PARTY!!", "MAX!!", "BOOM!!BOOM!!BOOM!!", "INCREDIBLE!!",
    ]
    private var shoutBag: [String] = []
    private var lastShout: String?

    /// 全部を1回ずつ出し切るまで同じ言葉は出さない。混ぜ直したときも直前と同じ言葉は続けない
    private func nextShout() -> String {
        if shoutBag.isEmpty {
            shoutBag = Dopa.shouts.shuffled()
            if shoutBag.last == lastShout { shoutBag.swapAt(0, shoutBag.count - 1) }
        }
        let word = shoutBag.removeLast()
        lastShout = word
        return word
    }

    private func feverShout(in w: OverlayWindow) {
        let word = nextShout()
        let key = "shout:\(word)@\(w.scale)"
        let (img, sz) = textCache[key] ?? renderText(word, TextStyle(size: 150, fill: [rgb(1, 1, 1), rgb(1, 0.95, 0.4), rgb(1, 0.55, 0.1)],
                                                                     stroke: rgb(0.1, 0, 0.15), strokeRatio: 9,
                                                                     glow: rgb(1, 0.2, 0.8), glowRadius: 30,
                                                                     font: partyFont, skew: 0.22), scale: w.scale)
        textCache[key] = (img, sz)
        let b = w.root.bounds
        // 右上がりと右下がりを交互に
        let up = (beatCount / 8) % 2 == 0
        let angle = (up ? 1 : -1) * CGFloat.random(in: 0.12...0.22)
        let x = CGFloat.random(in: min(b.midX, sz.width / 2 + 40)...max(b.midX, b.maxX - sz.width / 2 - 40))
        let y = CGFloat.random(in: b.height * 0.32...b.height * 0.62)
        slam(img, sz, in: w, at: CGPoint(x: x, y: y), angle: angle, life: 1.7)
    }

    /// 文字を大きい所から斜めに叩きつけ、着地点から衝撃波を出す。最後は傾いた向きのまま流れて消える
    private func slam(_ img: CGImage, _ size: CGSize, in w: OverlayWindow, at p: CGPoint, angle: CGFloat, life: Double) {
        let impact = 0.07  // life に対する着地のタイミング
        let holder = CALayer()
        holder.position = p
        holder.transform = CATransform3DMakeRotation(angle, 0, 0, 1)
        holder.zPosition = 50
        let l = CALayer()
        l.contents = img
        l.contentsScale = w.scale
        l.bounds = CGRect(origin: .zero, size: size)
        l.position = .zero
        // 4倍から一気に落とし、着地で縦につぶれてから跳ね返る
        let sx = CAKeyframeAnimation(keyPath: "transform.scale.x")
        sx.values = [4, 1.18, 0.94, 1.03, 1, 1, 1.12]
        sx.keyTimes = [0, impact, impact + 0.04, impact + 0.09, impact + 0.14, 0.85, 1].map { NSNumber(value: $0) }
        let sy = CAKeyframeAnimation(keyPath: "transform.scale.y")
        sy.values = [4, 0.72, 1.1, 0.97, 1, 1, 1.12]
        sy.keyTimes = sx.keyTimes
        let ease = [CAMediaTimingFunction(name: .easeIn)] + Array(repeating: CAMediaTimingFunction(name: .easeOut), count: 5)
        sx.timingFunctions = ease
        sy.timingFunctions = ease
        let x = CAKeyframeAnimation(keyPath: "position.x")
        x.values = [-220, 0, 20, 260]
        x.keyTimes = [0, impact, 0.85, 1].map { NSNumber(value: $0) }
        x.timingFunctions = [.init(name: .easeIn), .init(name: .linear), .init(name: .easeIn)]
        let o = CAKeyframeAnimation(keyPath: "opacity")
        o.values = [0, 1, 1, 0]
        o.keyTimes = [0, impact * 0.6, 0.85, 1].map { NSNumber(value: $0) }
        let g = CAAnimationGroup()
        g.animations = [sx, sy, x, o]
        g.duration = life
        g.fillMode = .forwards
        g.isRemovedOnCompletion = false
        l.add(g, forKey: "slam")
        // 着地の衝撃で大きく揺らし、だんだん収める
        let shake = CAKeyframeAnimation(keyPath: "position")
        shake.values = (0..<10).map { i in
            let k = Double(9 - i) / 9 * 26
            return NSValue(point: NSPoint(x: Double.random(in: -k...k), y: Double.random(in: -k...k)))
        }
        shake.isAdditive = true
        shake.duration = 0.4
        shake.beginTime = CACurrentMediaTime() + life * impact
        holder.add(shake, forKey: "shake")
        holder.addSublayer(l)
        w.root.addSublayer(holder)

        let g0 = gen
        after(life * impact) { [weak self] in
            guard let self, self.gen == g0 else { return }
            self.sound.play("boom")
            self.shockwave(at: p, in: w)
            self.starBurst(at: p, in: w, count: 90, speed: 700, scale: 0.45, life: 1.0, gravity: -200)
        }
        after(life) { holder.removeFromSuperlayer() }
    }

    /// 着地点から広がる衝撃波：強い光・集中線・空気の圧の輪・3重のリング
    private func shockwave(at p: CGPoint, in w: OverlayWindow) {
        let b = w.root.bounds
        let reach = hypot(b.width, b.height)
        flare(at: p, in: w, color: .white, size: 800)

        // 漫画の集中線のような放射状の線
        let lines = CAShapeLayer()
        let R = reach * 0.6
        lines.bounds = CGRect(x: -R, y: -R, width: R * 2, height: R * 2)
        lines.position = p
        lines.zPosition = 47
        let path = CGMutablePath()
        for _ in 0..<64 {
            let a = Double.random(in: 0..<(2 * .pi))
            let wdt = Double.random(in: 0.006...0.018)
            let inner = R * CGFloat.random(in: 0.18...0.32)
            path.move(to: CGPoint(x: inner * cos(a), y: inner * sin(a)))
            path.addLine(to: CGPoint(x: R * cos(a - wdt), y: R * sin(a - wdt)))
            path.addLine(to: CGPoint(x: R * cos(a + wdt), y: R * sin(a + wdt)))
            path.closeSubpath()
        }
        lines.path = path
        lines.fillColor = NSColor(white: 1, alpha: 0.8).cgColor
        lines.opacity = 0
        let ls = CABasicAnimation(keyPath: "transform.scale")
        ls.fromValue = 0.5
        ls.toValue = 1.25
        let lo = CABasicAnimation(keyPath: "opacity")
        lo.fromValue = 1
        lo.toValue = 0
        let lg = CAAnimationGroup()
        lg.animations = [ls, lo]
        lg.duration = 0.35
        lg.timingFunction = CAMediaTimingFunction(name: .easeOut)
        w.root.addSublayer(lines)
        lines.add(lg, forKey: nil)
        after(0.35) { lines.removeFromSuperlayer() }

        // 空気の圧が画面いっぱいに広がる光の輪
        let wave = CAGradientLayer()
        wave.type = .radial
        let d: CGFloat = 400
        wave.bounds = CGRect(x: 0, y: 0, width: d, height: d)
        wave.position = p
        wave.startPoint = CGPoint(x: 0.5, y: 0.5)
        wave.endPoint = CGPoint(x: 1, y: 1)
        wave.colors = [rgb(1, 1, 1, 0), rgb(1, 1, 1, 0), rgb(1, 1, 1, 0.55), rgb(1, 1, 1, 0)].map { $0.cgColor }
        wave.locations = [0, 0.72, 0.86, 1]
        wave.zPosition = 46
        wave.opacity = 0
        let ws = CABasicAnimation(keyPath: "transform.scale")
        ws.fromValue = 0.2
        ws.toValue = reach * 1.4 / d
        let wo = CABasicAnimation(keyPath: "opacity")
        wo.fromValue = 1
        wo.toValue = 0
        let wg = CAAnimationGroup()
        wg.animations = [ws, wo]
        wg.duration = 0.65
        wg.timingFunction = CAMediaTimingFunction(name: .easeOut)
        w.root.addSublayer(wave)
        wave.add(wg, forKey: nil)
        after(0.65) { wave.removeFromSuperlayer() }

        // 太い白いリング＋色付きのリングを時間差で3重に
        let col = Dopa.neon[beatCount % Dopa.neon.count]
        ring(at: p, in: w, color: .white, radius: 70, maxScale: 9, life: 0.6, width: 16)
        after(0.07) { self.ring(at: p, in: w, color: col, radius: 70, maxScale: 7, life: 0.6, width: 10) }
        after(0.14) { self.ring(at: p, in: w, color: .white, radius: 70, maxScale: 5, life: 0.55, width: 5) }
    }

    // MARK: 演出パーツ

    @discardableResult
    private func showImage(_ img: CGImage, _ size: CGSize, in w: OverlayWindow, at p: CGPoint, anim: TextAnim,
                           life: Double, shake: Bool = false) -> CALayer {
        let l = CALayer()
        l.contents = img
        l.contentsScale = w.scale
        l.bounds = CGRect(origin: .zero, size: size)
        l.position = p
        l.zPosition = 50
        let g = CAAnimationGroup()
        g.duration = life
        g.fillMode = .forwards
        g.isRemovedOnCompletion = false
        switch anim {
        case .pop:
            let s = CAKeyframeAnimation(keyPath: "transform.scale")
            s.values = [0.1, 1.3, 0.92, 1.04, 1.0, 1.0, 1.25]
            s.keyTimes = [0, 0.1, 0.17, 0.22, 0.27, 0.85, 1]
            let o = CAKeyframeAnimation(keyPath: "opacity")
            o.values = [0, 1, 1, 0]
            o.keyTimes = [0, 0.06, 0.85, 1]
            g.animations = [s, o]
        case .drop:
            let y = CABasicAnimation(keyPath: "position.y")
            y.fromValue = p.y + 40
            y.toValue = p.y - 90
            y.timingFunction = CAMediaTimingFunction(name: .easeIn)
            let r = CABasicAnimation(keyPath: "transform.rotation.z")
            r.fromValue = 0
            r.toValue = -0.12
            let o = CAKeyframeAnimation(keyPath: "opacity")
            o.values = [0, 1, 1, 0]
            o.keyTimes = [0, 0.1, 0.6, 1]
            g.animations = [y, r, o]
        }
        w.root.addSublayer(l)
        l.add(g, forKey: nil)
        if shake {
            let j = CAKeyframeAnimation(keyPath: "position")
            j.values = (0..<8).map { _ in NSValue(point: NSPoint(x: Double.random(in: -6...6), y: Double.random(in: -6...6))) }
            j.isAdditive = true
            j.duration = 0.24
            j.repeatCount = .infinity
            l.add(j, forKey: "shake")
        }
        after(life) { l.removeFromSuperlayer() }
        return l
    }

    private func dim(in w: OverlayWindow, alpha: Float, life: Double) {
        let l = CALayer()
        l.frame = w.root.bounds
        l.backgroundColor = NSColor.black.cgColor
        l.opacity = 0
        l.zPosition = 10
        let o = CAKeyframeAnimation(keyPath: "opacity")
        o.values = [0, alpha, alpha, 0]
        o.keyTimes = [0, 0.1, 0.75, 1]
        o.duration = life
        w.root.addSublayer(l)
        l.add(o, forKey: nil)
        after(life) { l.removeFromSuperlayer() }
    }

    private func emitter(in w: OverlayWindow, at p: CGPoint, cells: [CAEmitterCell], emitFor: Double, removeAfter: Double,
                         additive: Bool = false) {
        let e = CAEmitterLayer()
        e.frame = w.root.bounds
        e.emitterPosition = p
        e.emitterShape = .point
        e.emitterCells = cells
        if additive { e.renderMode = .additive }
        e.beginTime = CACurrentMediaTime()
        e.zPosition = 40
        w.root.addSublayer(e)
        after(emitFor) { e.birthRate = 0 }
        after(removeAfter) { e.removeFromSuperlayer() }
    }

    private func starBurst(at p: CGPoint, in w: OverlayWindow, count: Int, speed: CGFloat,
                           scale: CGFloat = 0.3, life: Float = 0.8, gravity: CGFloat = -260) {
        let per = Float(count) / Float(rainbowFill.count) / 0.05
        var cells = rainbowFill.map { col -> CAEmitterCell in
            let c = CAEmitterCell()
            c.contents = starImg
            c.birthRate = per
            c.lifetime = life
            c.lifetimeRange = life * 0.3
            c.velocity = speed
            c.velocityRange = speed * 0.5
            c.emissionRange = .pi * 2
            c.yAcceleration = gravity
            c.scale = scale
            c.scaleRange = scale * 0.4
            c.scaleSpeed = -scale * 0.5
            c.spin = 3
            c.spinRange = 8
            c.alphaSpeed = -1 / life
            c.color = col.cgColor
            return c
        }
        let dot = CAEmitterCell()
        dot.contents = sparkImage
        dot.birthRate = Float(count) / 0.05
        dot.lifetime = life * 1.3
        dot.velocity = speed * 0.6
        dot.velocityRange = speed * 0.5
        dot.emissionRange = .pi * 2
        dot.yAcceleration = gravity * 0.5
        dot.scale = scale * 0.5
        dot.scaleRange = scale * 0.3
        dot.alphaSpeed = -0.8 / life
        cells.append(dot)
        emitter(in: w, at: p, cells: cells, emitFor: 0.05, removeAfter: Double(life) * 1.6 + 0.3)
    }

    private func ring(at p: CGPoint, in w: OverlayWindow, color: NSColor, radius: CGFloat, maxScale: CGFloat, life: Double, width: CGFloat = 6) {
        let s = CAShapeLayer()
        s.bounds = CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2)
        s.position = p
        s.path = CGPath(ellipseIn: s.bounds, transform: nil)
        s.fillColor = nil
        s.strokeColor = color.cgColor
        s.lineWidth = width
        s.zPosition = 45
        s.opacity = 0
        let sc = CABasicAnimation(keyPath: "transform.scale")
        sc.fromValue = 0.1
        sc.toValue = maxScale
        sc.timingFunction = CAMediaTimingFunction(name: .easeOut)
        let o = CABasicAnimation(keyPath: "opacity")
        o.fromValue = 1
        o.toValue = 0
        let g = CAAnimationGroup()
        g.animations = [sc, o]
        g.duration = life
        w.root.addSublayer(s)
        s.add(g, forKey: nil)
        after(life) { s.removeFromSuperlayer() }
    }

    private func rocket(in w: OverlayWindow, delay: Double, quiet: Bool = false) {
        let b = w.root.bounds
        let from = CGPoint(x: CGFloat.random(in: b.width * 0.08...b.width * 0.92), y: -10)
        let to = CGPoint(x: from.x + CGFloat.random(in: -140...140), y: CGFloat.random(in: b.height * 0.45...b.height * 0.88))
        let col = NSColor(hue: CGFloat.random(in: 0..<1), saturation: 0.85, brightness: 1, alpha: 1)
        let g = gen
        after(delay) { [weak self] in
            guard let self, self.gen == g else { return }
            let trail = CAEmitterCell()
            trail.contents = sparkImage
            trail.birthRate = 160
            trail.lifetime = 0.45
            trail.velocity = 25
            trail.emissionRange = .pi * 2
            trail.scale = 0.2
            trail.scaleSpeed = -0.3
            trail.alphaSpeed = -2
            trail.color = rgb(1, 0.85, 0.5).cgColor
            let e = CAEmitterLayer()
            e.frame = b
            e.emitterShape = .point
            e.renderMode = .additive
            e.emitterPosition = to
            e.emitterCells = [trail]
            e.beginTime = CACurrentMediaTime()
            e.zPosition = 40
            let a = CABasicAnimation(keyPath: "emitterPosition")
            a.fromValue = NSValue(point: from)
            a.toValue = NSValue(point: to)
            a.duration = 0.65
            a.timingFunction = CAMediaTimingFunction(name: .easeOut)
            w.root.addSublayer(e)
            e.add(a, forKey: nil)
            if !quiet { self.sound.play("launch") }
            after(0.65) { [weak self] in
                e.birthRate = 0
                guard let self, self.gen == g else { return }
                self.firework(at: to, in: w, color: col)
                self.ring(at: to, in: w, color: col, radius: 50, maxScale: 3, life: 0.6, width: 5)
                self.sound.play("boom")
            }
            after(1.5) { e.removeFromSuperlayer() }
        }
    }

    private func firework(at p: CGPoint, in w: OverlayWindow, color: NSColor) {
        let main = CAEmitterCell()
        main.contents = sparkImage
        main.birthRate = 140 / 0.05
        main.lifetime = 1.4
        main.lifetimeRange = 0.4
        main.velocity = 380
        main.velocityRange = 60
        main.emissionRange = .pi * 2
        main.yAcceleration = -150
        main.scale = 0.42
        main.scaleSpeed = -0.25
        main.alphaSpeed = -0.7
        main.color = color.cgColor
        main.greenRange = 0.15
        main.blueRange = 0.15
        let glitter = CAEmitterCell()
        glitter.contents = starImg
        glitter.birthRate = 60 / 0.05
        glitter.lifetime = 1.8
        glitter.velocity = 240
        glitter.velocityRange = 120
        glitter.emissionRange = .pi * 2
        glitter.yAcceleration = -120
        glitter.scale = 0.18
        glitter.spin = 4
        glitter.spinRange = 8
        glitter.alphaSpeed = -0.5
        emitter(in: w, at: p, cells: [main, glitter], emitFor: 0.05, removeAfter: 2.4, additive: true)
    }

    private func whiteFlash(in w: OverlayWindow) {
        let l = CALayer()
        l.frame = w.root.bounds
        l.backgroundColor = NSColor.white.cgColor
        l.opacity = 0
        l.zPosition = 30
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 0.7
        a.toValue = 0
        a.duration = 0.6
        w.root.addSublayer(l)
        l.add(a, forKey: nil)
        after(0.6) { l.removeFromSuperlayer() }
    }

    @discardableResult
    private func sunburst(in w: OverlayWindow, life: Double?) -> CALayer {
        let b = w.root.bounds
        let R = hypot(b.width, b.height) / 2
        let container = CALayer()
        container.bounds = CGRect(x: -R, y: -R, width: 2 * R, height: 2 * R)
        container.position = w.center
        container.zPosition = 20
        let n = 24
        for k in 0..<rainbowFill.count {
            let s = CAShapeLayer()
            s.bounds = container.bounds
            s.position = .zero
            let path = CGMutablePath()
            for i in stride(from: k, to: n, by: rainbowFill.count) {
                let a0 = Double(i) / Double(n) * 2 * .pi
                let a1 = a0 + .pi / Double(n)
                path.move(to: .zero)
                path.addLine(to: CGPoint(x: R * cos(a0), y: R * sin(a0)))
                path.addLine(to: CGPoint(x: R * cos(a1), y: R * sin(a1)))
                path.closeSubpath()
            }
            s.path = path
            s.fillColor = rainbowFill[k].withAlphaComponent(0.32).cgColor
            container.addSublayer(s)
        }
        let rot = CABasicAnimation(keyPath: "transform.rotation.z")
        rot.fromValue = 0
        rot.toValue = 2 * Double.pi
        rot.duration = 5
        rot.repeatCount = .infinity
        w.root.addSublayer(container)
        container.add(rot, forKey: "rot")
        if let life {
            let o = CAKeyframeAnimation(keyPath: "opacity")
            o.values = [0, 1, 1, 0]
            o.keyTimes = [0, 0.08, 0.85, 1]
            o.duration = life
            o.fillMode = .forwards
            o.isRemovedOnCompletion = false
            container.add(o, forKey: "fade")
            after(life) { container.removeFromSuperlayer() }
        } else {
            let o = CABasicAnimation(keyPath: "opacity")
            o.fromValue = 0
            o.duration = 0.5
            container.add(o, forKey: "in")
        }
        return container
    }

    /// 上下に流れる電光掲示板
    @discardableResult
    private func marquee(in w: OverlayWindow, y: CGFloat, life: Double?, reverse: Bool) -> CALayer {
        let b = w.root.bounds
        let key = "marquee@\(w.scale)"
        let (img, sz) = textCache[key] ?? renderText("  ★ FEVER ★ DOPAMINE", TextStyle(size: 46, fill: rainbowFill, stroke: rgb(0.1, 0, 0.1),
                                                                                      strokeRatio: 10, horizontal: true), scale: w.scale)
        textCache[key] = (img, sz)
        let h = sz.height + 10
        let band = CALayer()
        band.frame = CGRect(x: 0, y: y - h / 2, width: b.width, height: h)
        band.backgroundColor = NSColor(white: 0, alpha: 0.7).cgColor
        band.borderColor = gold.cgColor
        band.borderWidth = 3
        band.masksToBounds = true
        band.zPosition = 35
        let count = Int(ceil(b.width / sz.width)) + 2
        let rep = CAReplicatorLayer()
        rep.anchorPoint = .zero
        rep.bounds = CGRect(x: 0, y: 0, width: sz.width * CGFloat(count), height: h)
        rep.position = .zero
        rep.instanceCount = count
        rep.instanceTransform = CATransform3DMakeTranslation(sz.width, 0, 0)
        let t = CALayer()
        t.contents = img
        t.contentsScale = w.scale
        t.frame = CGRect(x: 0, y: 5, width: sz.width, height: sz.height)
        rep.addSublayer(t)
        band.addSublayer(rep)
        let a = CABasicAnimation(keyPath: "position.x")
        a.fromValue = reverse ? -sz.width : 0
        a.toValue = reverse ? 0 : -sz.width
        a.duration = Double(sz.width) / 450
        a.repeatCount = .infinity
        rep.add(a, forKey: nil)
        let fadeIn = CABasicAnimation(keyPath: "opacity")
        fadeIn.fromValue = 0
        fadeIn.toValue = 1
        fadeIn.duration = 0.3
        band.add(fadeIn, forKey: "in")
        w.root.addSublayer(band)
        if let life { after(life) { self.fadeRemove(band) } }
        return band
    }

    /// continuous が true のときは止めずに降らせ続ける（FEVER中用、量は控えめ）
    @discardableResult
    private func confettiRain(in w: OverlayWindow, continuous: Bool = false) -> CALayer {
        let b = w.root.bounds
        let e = CAEmitterLayer()
        e.frame = b
        e.emitterShape = .line
        e.emitterPosition = CGPoint(x: b.midX, y: b.maxY + 30)
        e.emitterSize = CGSize(width: b.width, height: 1)
        e.zPosition = 38
        func cell(_ img: CGImage, rate: Float, scale: CGFloat, color: NSColor = .white, gravity: CGFloat) -> CAEmitterCell {
            let c = CAEmitterCell()
            c.contents = img
            c.birthRate = rate
            c.lifetime = 5
            c.velocity = 150
            c.velocityRange = 100
            c.emissionLongitude = -.pi / 2
            c.emissionRange = 0.5
            c.yAcceleration = gravity
            c.spin = 4
            c.spinRange = 10
            c.scale = scale
            c.scaleRange = scale * 0.3
            c.color = color.cgColor
            return c
        }
        let k: Float = continuous ? 0.25 : 1
        e.emitterCells = [cell(goldCoin, rate: 60 * k, scale: 0.55, gravity: -700)]
            + rainbowFill.map { cell(confettiImg, rate: 25 * k, scale: 1.2, color: $0, gravity: -220) }
        e.beginTime = CACurrentMediaTime()
        w.root.addSublayer(e)
        if !continuous {
            after(3) { e.birthRate = 0 }
            after(9) { e.removeFromSuperlayer() }
        }
        return e
    }

    private func emojiImage(_ s: String) -> CGImage {
        if let c = emojiCache[s] { return c }
        let img = bitmap(128, 128) { ctx in
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            let str = NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: 100)])
            let sz = str.size()
            str.draw(at: NSPoint(x: (128 - sz.width) / 2, y: (128 - sz.height) / 2))
            NSGraphicsContext.restoreGraphicsState()
        }
        emojiCache[s] = img
        return img
    }

    /// 絵文字が画面を左下から右上へ横切る（ロケット向き）
    private func emojiFlight(_ set: [String], in w: OverlayWindow, count: Int) {
        let b = w.root.bounds
        for _ in 0..<count {
            let s = set.randomElement()!
            let size = CGFloat.random(in: 40...90)
            let l = CALayer()
            l.contents = emojiImage(s)
            l.bounds = CGRect(x: 0, y: 0, width: size, height: size)
            l.zPosition = 55
            let from = CGPoint(x: CGFloat.random(in: -200...(b.width * 0.7)), y: -100)
            let dist = CGFloat.random(in: b.height * 0.9...b.height * 1.4)
            let to = CGPoint(x: from.x + dist * 0.75, y: from.y + dist)
            l.position = to
            let a = CABasicAnimation(keyPath: "position")
            a.fromValue = NSValue(point: from)
            a.toValue = NSValue(point: to)
            let dur = Double.random(in: 0.9...1.7)
            let delay = Double.random(in: 0...0.6)
            a.duration = dur
            a.beginTime = CACurrentMediaTime() + delay
            a.fillMode = .backwards
            a.timingFunction = CAMediaTimingFunction(name: .easeIn)
            if s != "🚀" {
                let r = CABasicAnimation(keyPath: "transform.rotation.z")
                r.toValue = Double.random(in: -8...8)
                r.duration = dur
                r.beginTime = a.beginTime
                l.add(r, forKey: "spin")
            }
            w.root.addSublayer(l)
            l.add(a, forKey: "fly")
            after(delay + dur) { l.removeFromSuperlayer() }
        }
    }

    /// カーソルから吹き出し、上からも降ってくる
    private func emojiRain(_ set: [String], from p: CGPoint, in w: OverlayWindow) {
        let b = w.root.bounds
        func cell(_ s: String, rate: Float, up: Bool) -> CAEmitterCell {
            let c = CAEmitterCell()
            c.contents = emojiImage(s)
            c.birthRate = rate
            c.lifetime = up ? 1.6 : 4
            c.velocity = up ? 420 : 80
            c.velocityRange = up ? 160 : 60
            c.emissionLongitude = up ? .pi / 2 : -.pi / 2
            c.emissionRange = up ? 1.2 : 0.4
            c.yAcceleration = up ? -500 : -120
            c.scale = 0.35
            c.scaleRange = 0.15
            c.spinRange = 2
            c.alphaSpeed = up ? -0.5 : 0
            return c
        }
        emitter(in: w, at: p, cells: set.map { cell($0, rate: 30 / 0.06 / Float(set.count), up: true) }, emitFor: 0.06, removeAfter: 2)
        let e = CAEmitterLayer()
        e.frame = b
        e.emitterShape = .line
        e.emitterPosition = CGPoint(x: b.midX, y: b.maxY + 40)
        e.emitterSize = CGSize(width: b.width, height: 1)
        e.emitterCells = set.map { cell($0, rate: 6, up: false) }
        e.beginTime = CACurrentMediaTime()
        e.zPosition = 40
        w.root.addSublayer(e)
        after(1.8) { e.birthRate = 0 }
        after(8) { e.removeFromSuperlayer() }
    }

    private func emojiSpray(_ set: [String], from p: CGPoint, in w: OverlayWindow) {
        let cells = set.map { s -> CAEmitterCell in
            let c = CAEmitterCell()
            c.contents = emojiImage(s)
            c.birthRate = 30 / 0.05 / Float(set.count)
            c.lifetime = 1.2
            c.velocity = 360
            c.velocityRange = 140
            c.emissionRange = .pi * 2
            c.yAcceleration = -300
            c.scale = 0.3
            c.scaleRange = 0.12
            c.spin = 3
            c.spinRange = 6
            c.alphaSpeed = -0.7
            return c
        }
        emitter(in: w, at: p, cells: cells, emitFor: 0.05, removeAfter: 1.6)
    }
}

// MARK: - 録画（画面＋Macの音）

final class Recorder: NSObject, SCRecordingOutputDelegate {
    private var stream: SCStream?

    /// screen を音声付きで url に録画し始める
    func start(screen: NSScreen, url: URL) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        guard let display = content.displays.first(where: { $0.displayID == id }) ?? content.displays.first else {
            throw NSError(domain: "DopaRecorder", code: 1, userInfo: [NSLocalizedDescriptionKey: "ディスプレイが見つかりません"])
        }
        let cfg = SCStreamConfiguration()
        cfg.width = Int(CGFloat(display.width) * screen.backingScaleFactor)
        cfg.height = Int(CGFloat(display.height) * screen.backingScaleFactor)
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        cfg.showsCursor = true
        cfg.capturesAudio = true
        cfg.excludesCurrentProcessAudio = false  // 自分の効果音とFEVERの曲も録る
        cfg.sampleRate = 48000
        cfg.channelCount = 2
        let s = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: cfg, delegate: nil)
        let oc = SCRecordingOutputConfiguration()
        oc.outputURL = url
        oc.outputFileType = .mp4
        oc.videoCodecType = .h264
        try s.addRecordingOutput(SCRecordingOutput(configuration: oc, delegate: self))
        try await s.startCapture()
        stream = s
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        NSLog("DopaRecorder failed: \(error)")
    }
}

// MARK: - メニューバー

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var dopa: Dopa!
    private var item: NSStatusItem!
    private var keyMonitor: Any?
    private var permTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        dopa = Dopa()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        dopa.onComboChange = { [weak self] in self?.updateTitle() }
        updateTitle()

        // 録画モードで起動したときは、許可ダイアログが映り込まないよう確認だけにする
        let recordOnLaunch = CommandLine.arguments.contains("--record-demo")
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: !recordOnLaunch] as CFDictionary
        if recordOnLaunch {
            dopa.enableTemporarily()
            after(1.5) { self.recordDemo(quitAfter: true) }
        }
        if AXIsProcessTrustedWithOptions(opts) {
            installMonitor()
        } else {
            let t = Timer(timeInterval: 2, target: self, selector: #selector(checkPermission), userInfo: nil, repeats: true)
            RunLoop.main.add(t, forMode: .common)
            permTimer = t
        }
    }

    @objc private func checkPermission() {
        guard AXIsProcessTrusted() else { return }
        permTimer?.invalidate()
        permTimer = nil
        installMonitor()
    }

    private func installMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            MainActor.assumeIsolated { self?.dopa.handleKey(e) }
        }
    }

    private func updateTitle() {
        let title = !dopa.enabled ? "DOPA off" : dopa.combo > 0 ? "DOPA x\(dopa.combo)" : "DOPA"
        item.button?.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .heavy),
            .foregroundColor: dopa.enabled ? NSColor.systemPink : NSColor.secondaryLabelColor,
        ])
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if !AXIsProcessTrusted() {
            menu.addItem(withTitle: "⚠️ アクセシビリティの許可が必要（クリックで設定を開く）", action: #selector(openAX), keyEquivalent: "").target = self
            menu.addItem(.separator())
        }
        let on = menu.addItem(withTitle: "ドパガキモード（⌃⌥⌘P）", action: #selector(toggleEnabled), keyEquivalent: "")
        on.target = self
        on.state = dopa.enabled ? .on : .off
        let snd = menu.addItem(withTitle: "サウンド", action: #selector(toggleSound), keyEquivalent: "")
        snd.target = self
        snd.state = dopa.sound.enabled ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "テスト: 30連打", action: #selector(demo30), keyEquivalent: "").target = self
        menu.addItem(withTitle: "テスト: 100連打（FEVER）", action: #selector(demo100), keyEquivalent: "").target = self
        let rec = menu.addItem(withTitle: recording ? "録画中…" : "テスト: 100連打を音声付きで録画", action: #selector(recordFromMenu), keyEquivalent: "")
        rec.target = self
        rec.isEnabled = !recording
        menu.addItem(.separator())
        menu.addItem(withTitle: "終了", action: #selector(quit), keyEquivalent: "q").target = self
    }

    @objc private func toggleEnabled() { dopa.setEnabled(!dopa.enabled) }
    @objc private func toggleSound() { dopa.setSound(!dopa.sound.enabled) }
    @objc private func demo30() { dopa.demo(keys: 30) }
    @objc private func demo100() { dopa.demo(keys: 100) }
    @objc private func recordFromMenu() { recordDemo(quitAfter: false) }

    private let recorder = Recorder()
    private var recording = false

    /// マウスのある画面を録画しながら100連打のテストを流し、FEVER TIMEが終わったら保存する
    private func recordDemo(quitAfter: Bool) {
        guard !recording else { return }
        recording = true
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main ?? NSScreen.screens[0]
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dopa-macbook-\(stamp).mp4")
        Task { @MainActor in
            defer {
                self.recording = false
                if quitAfter { NSApp.terminate(nil) }
            }
            do {
                try await self.recorder.start(screen: screen, url: url)
            } catch {
                NSLog("DopaRecorder start failed: \(error)")
                return
            }
            try? await Task.sleep(for: .seconds(1))
            self.dopa.demo(keys: 100)
            // 100打（約7秒）＋FEVER TIME＋フェードアウト
            try? await Task.sleep(for: .seconds(7 + Tune.feverDuration + 3))
            await self.recorder.stop()
            NSLog("DopaRecorder saved: \(url.path)")
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func openAX() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
