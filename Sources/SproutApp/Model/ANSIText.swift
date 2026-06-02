import SwiftUI

/// Parses a line containing ANSI SGR escape sequences (`ESC[...m`) into a styled
/// `AttributedString`. Dev servers (vite, rails, esbuild) emit these for color;
/// without parsing they show up as literal escape garbage in the console.
enum ANSIText {
    /// `fallback` is the color used for text with no explicit ANSI color (e.g. red
    /// for stderr, primary for stdout).
    static func parse(_ raw: String, fallback: Color) -> AttributedString {
        var result = AttributedString()
        var state = Style(fallback: fallback)
        var scalars = Array(raw.unicodeScalars)
        var i = 0
        var pending = ""

        func flush() {
            guard !pending.isEmpty else { return }
            var run = AttributedString(pending)
            run.foregroundColor = state.color
            if state.bold { run.font = .system(.caption, design: .monospaced).bold() }
            result.append(run)
            pending = ""
        }

        while i < scalars.count {
            // SGR sequence: ESC [ <params> m
            if scalars[i] == "\u{1B}", i + 1 < scalars.count, scalars[i + 1] == "[" {
                var j = i + 2
                var params = ""
                while j < scalars.count, scalars[j] != "m",
                    (scalars[j].properties.numericType != nil || scalars[j] == ";")
                {
                    params.unicodeScalars.append(scalars[j])
                    j += 1
                }
                if j < scalars.count, scalars[j] == "m" {
                    flush()
                    state.apply(params: params)
                    i = j + 1
                    continue
                }
            }
            pending.unicodeScalars.append(scalars[i])
            i += 1
        }
        flush()
        return result
    }

    private struct Style {
        let fallback: Color
        var color: Color
        var bold = false

        init(fallback: Color) {
            self.fallback = fallback
            self.color = fallback
        }

        mutating func apply(params: String) {
            let codes = params.split(separator: ";").map { Int($0) ?? 0 }
            var k = 0
            // Empty params (ESC[m) means reset.
            if codes.isEmpty { reset(); return }
            while k < codes.count {
                let c = codes[k]
                switch c {
                case 0: reset()
                case 1: bold = true
                case 22: bold = false
                case 30...37: color = Self.standard[c - 30]
                case 39: color = fallback
                case 90...97: color = Self.bright[c - 90]
                case 38:
                    // 256-color (38;5;n) or truecolor (38;2;r;g;b)
                    if k + 1 < codes.count, codes[k + 1] == 5, k + 2 < codes.count {
                        color = Self.xterm256(codes[k + 2]); k += 2
                    } else if k + 1 < codes.count, codes[k + 1] == 2, k + 4 < codes.count {
                        color = Color(
                            red: Double(codes[k + 2]) / 255, green: Double(codes[k + 3]) / 255,
                            blue: Double(codes[k + 4]) / 255)
                        k += 4
                    }
                default: break  // background/underline/etc. ignored
                }
                k += 1
            }
        }

        mutating func reset() {
            color = fallback
            bold = false
        }

        static let standard: [Color] = [
            .black, .red, .green, .yellow, .blue, .purple, .cyan, .secondary,
        ]
        static let bright: [Color] = [
            .secondary, .red, .green, .yellow, .blue, .purple, .cyan, .primary,
        ]

        /// Approximate the xterm 256-color palette: 0-15 system, 16-231 6×6×6 cube,
        /// 232-255 grayscale ramp.
        static func xterm256(_ n: Int) -> Color {
            if n < 8 { return standard[n] }
            if n < 16 { return bright[n - 8] }
            if n < 232 {
                let v = n - 16
                let r = (v / 36) % 6, g = (v / 6) % 6, b = v % 6
                let f = { (x: Int) in x == 0 ? 0.0 : Double(x * 40 + 55) / 255 }
                return Color(red: f(r), green: f(g), blue: f(b))
            }
            let gray = Double((n - 232) * 10 + 8) / 255
            return Color(red: gray, green: gray, blue: gray)
        }
    }
}
