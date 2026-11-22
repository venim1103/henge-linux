// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import UIKit

/// Terminal cell foreground/background color specification supporting
/// default colors, ANSI 16/256 palette indices, and 24-bit TrueColor.
enum TermColor: Equatable {
    case defaultFg
    case defaultBg
    case indexed(UInt8)
    case rgb(UInt8, UInt8, UInt8)

    static let defaultFgColor = UIColor(red: 0.90, green: 0.93, blue: 0.90, alpha: 1.0)
    static let defaultBgColor = UIColor.black

    func uiColor(isForeground: Bool) -> UIColor {
        switch self {
        case .defaultFg:
            return Self.defaultFgColor
        case .defaultBg:
            return Self.defaultBgColor
        case .indexed(let idx):
            return Self.paletteCache[Int(idx)]
        case .rgb(let r, let g, let b):
            return UIColor(
                red: CGFloat(r) / 255.0,
                green: CGFloat(g) / 255.0,
                blue: CGFloat(b) / 255.0,
                alpha: 1.0
            )
        }
    }

    private static let ansi16: [UIColor] = [
        UIColor(red: 0.08, green: 0.09, blue: 0.10, alpha: 1.0), // 0 black
        UIColor(red: 0.85, green: 0.25, blue: 0.25, alpha: 1.0), // 1 red
        UIColor(red: 0.25, green: 0.78, blue: 0.35, alpha: 1.0), // 2 green
        UIColor(red: 0.90, green: 0.75, blue: 0.22, alpha: 1.0), // 3 yellow
        UIColor(red: 0.28, green: 0.56, blue: 0.95, alpha: 1.0), // 4 blue
        UIColor(red: 0.76, green: 0.42, blue: 0.88, alpha: 1.0), // 5 magenta
        UIColor(red: 0.24, green: 0.78, blue: 0.84, alpha: 1.0), // 6 cyan
        UIColor(red: 0.84, green: 0.86, blue: 0.88, alpha: 1.0), // 7 white
        UIColor(red: 0.44, green: 0.47, blue: 0.52, alpha: 1.0), // 8 bright black
        UIColor(red: 1.00, green: 0.42, blue: 0.42, alpha: 1.0), // 9 bright red
        UIColor(red: 0.42, green: 0.94, blue: 0.52, alpha: 1.0), // 10 bright green
        UIColor(red: 1.00, green: 0.90, blue: 0.42, alpha: 1.0), // 11 bright yellow
        UIColor(red: 0.48, green: 0.72, blue: 1.00, alpha: 1.0), // 12 bright blue
        UIColor(red: 0.90, green: 0.60, blue: 1.00, alpha: 1.0), // 13 bright magenta
        UIColor(red: 0.46, green: 0.92, blue: 0.96, alpha: 1.0), // 14 bright cyan
        UIColor(red: 1.00, green: 1.00, blue: 1.00, alpha: 1.0), // 15 bright white
    ]

    private static let paletteCache: [UIColor] = {
        var colors: [UIColor] = []
        colors.reserveCapacity(256)
        for i in 0..<256 {
            if i < 16 {
                colors.append(ansi16[i])
            } else if i < 232 {
                let n = i - 16
                let r = n / 36
                let g = (n % 36) / 6
                let b = n % 6
                let levels: [CGFloat] = [0, 95, 135, 175, 215, 255]
                colors.append(UIColor(
                    red: levels[r] / 255.0,
                    green: levels[g] / 255.0,
                    blue: levels[b] / 255.0,
                    alpha: 1.0
                ))
            } else {
                let gray = CGFloat(8 + (i - 232) * 10) / 255.0
                colors.append(UIColor(red: gray, green: gray, blue: gray, alpha: 1.0))
            }
        }
        return colors
    }()
}

struct TermCell: Equatable {
    var scalar: UnicodeScalar = " "
    var fg: TermColor = .defaultFg
    var bg: TermColor = .defaultBg
    var bold: Bool = false
    var dim: Bool = false
    var italic: Bool = false
    var underline: Bool = false
    var inverse: Bool = false
    var hidden: Bool = false
    var strikethrough: Bool = false
    /// Marks the trailing spacer cell of a 2-column wide character (CJK/emoji).
    var isWideContinuation: Bool = false

    static let blank = TermCell()
}

/// Stateful VT100 / xterm-256color terminal emulator for HengeLinux's PL011
/// (`ttyAMA0`) serial console, supporting alternate screen buffers (`vim`,
/// `htop`, `tmux`, `agy`), DEC special graphics box-drawing, SGR colon
/// subparameters, `REP`, `IRM`, `XTWINOPS`, `OSC 10/11` color queries, wide
/// Unicode cells, SGR mouse reporting, and 2,000-line scrollback.
@MainActor
final class VT100TerminalEmulator {
    private enum ParseState {
        case ground
        case escape
        case escapeCharset(Int) // 0 = G0, 1 = G1
        case escapeIntermediate
        case csi
        case osc
        case oscEsc
        case dcs
        case dcsEsc
    }

    private struct SavedCursor {
        var x: Int = 0
        var y: Int = 0
        var fg: TermColor = .defaultFg
        var bg: TermColor = .defaultBg
        var bold: Bool = false
        var dim: Bool = false
        var italic: Bool = false
        var underline: Bool = false
        var inverse: Bool = false
        var hidden: Bool = false
        var strikethrough: Bool = false
        var originMode: Bool = false
        var autoWrap: Bool = true
        var g0Graphics: Bool = false
        var g1Graphics: Bool = false
        var useG1: Bool = false
    }

    private(set) var cols: Int
    private(set) var rows: Int
    private(set) var grid: [[TermCell]]
    private(set) var scrollback: [[TermCell]] = []
    private let maxScrollback: Int = 2000

    private var altGrid: [[TermCell]]?
    private var primarySavedCursor = SavedCursor()
    private var decSavedCursor = SavedCursor()

    private(set) var isUsingAlternateScreen: Bool = false
    private(set) var cursorX: Int = 0
    private(set) var cursorY: Int = 0
    private(set) var cursorVisible: Bool = true
    private(set) var appCursorKeys: Bool = false
    private(set) var bracketedPaste: Bool = false
    private(set) var mouseTrackingEnabled: Bool = false
    private(set) var sgrMouseMode: Bool = false

    private var pendingWrap: Bool = false
    private var autoWrap: Bool = true
    private var originMode: Bool = false
    private var insertMode: Bool = false
    private var g0Graphics: Bool = false
    private var g1Graphics: Bool = false
    private var useG1: Bool = false
    private var scrollTop: Int = 0
    private var scrollBottom: Int

    private var curFg: TermColor = .defaultFg
    private var curBg: TermColor = .defaultBg
    private var curBold: Bool = false
    private var curDim: Bool = false
    private var curItalic: Bool = false
    private var curUnderline: Bool = false
    private var curInverse: Bool = false
    private var curHidden: Bool = false
    private var curStrikethrough: Bool = false

    private var parseState: ParseState = .ground
    private var csiBuffer: [UInt8] = []
    private var oscBuffer: [UInt8] = []
    private var utf8Buffer: [UInt8] = []
    private var utf8Expected: Int = 0
    private var lastPrintedScalar: UnicodeScalar?

    /// Suppresses DSR/DA/OSC replies while replaying historical catch-up bytes.
    var suppressReplies: Bool = false

    /// Called when the guest queries terminal state (e.g. DSR `\x1b[6n`, `CSI 18 t`, `OSC 11 ; ?`).
    var onReply: ((Data) -> Void)?
    /// Called when the guest queries terminal geometry (`ESC[999;999H` + `ESC[6n` or `CSI 18 t`).
    var onSizeQueried: ((Int, Int) -> Void)?
    /// Called when alternate screen mode toggles (`?1049h`/`l`, `?47h`/`l`).
    var onAltScreenChanged: ((Bool) -> Void)?

    /// Tracks lines pushed into scrollback during a feed batch so the view
    /// can keep a scrolled-up viewport anchored at the same text.
    private(set) var scrollbackAddedSinceReset: Int = 0

    init(cols: Int = 80, rows: Int = 24) {
        self.cols = max(cols, 16)
        self.rows = max(rows, 6)
        self.scrollBottom = self.rows - 1
        self.grid = Array(repeating: Array(repeating: TermCell.blank, count: self.cols), count: self.rows)
    }

    func resetScrollbackDelta() {
        scrollbackAddedSinceReset = 0
    }

    func clearAll() {
        scrollback.removeAll(keepingCapacity: true)
        grid = Array(repeating: Array(repeating: TermCell.blank, count: cols), count: rows)
        cursorX = 0
        cursorY = 0
        pendingWrap = false
        scrollTop = 0
        scrollBottom = rows - 1
    }

    func resize(cols newCols: Int, rows newRows: Int) {
        let clampedCols = min(max(newCols, 20), 220)
        let clampedRows = min(max(newRows, 6), 100)
        guard clampedCols != cols || clampedRows != rows else { return }

        var resizedGrid = Array(repeating: Array(repeating: TermCell.blank, count: clampedCols), count: clampedRows)

        if !isUsingAlternateScreen && clampedRows < rows {
            // Preserve lines scrolled off the top into scrollback when shrinking vertically.
            let linesToPush = max(0, (cursorY + 1) - clampedRows)
            if linesToPush > 0 {
                for r in 0..<min(linesToPush, rows) {
                    appendScrollback(grid[r])
                }
                let remain = rows - linesToPush
                for r in 0..<min(remain, clampedRows) {
                    let src = grid[r + linesToPush]
                    let copyCount = min(src.count, clampedCols)
                    for c in 0..<copyCount {
                        resizedGrid[r][c] = src[c]
                    }
                }
                cursorY = max(0, cursorY - linesToPush)
            } else {
                for r in 0..<min(rows, clampedRows) {
                    let src = grid[r]
                    let copyCount = min(src.count, clampedCols)
                    for c in 0..<copyCount {
                        resizedGrid[r][c] = src[c]
                    }
                }
            }
        } else {
            for r in 0..<min(rows, clampedRows) {
                let src = grid[r]
                let copyCount = min(src.count, clampedCols)
                for c in 0..<copyCount {
                    resizedGrid[r][c] = src[c]
                }
            }
        }

        if let alt = altGrid {
            var resizedAlt = Array(repeating: Array(repeating: TermCell.blank, count: clampedCols), count: clampedRows)
            for r in 0..<min(alt.count, clampedRows) {
                let copyCount = min(alt[r].count, clampedCols)
                for c in 0..<copyCount {
                    resizedAlt[r][c] = alt[r][c]
                }
            }
            altGrid = resizedAlt
        }

        cols = clampedCols
        rows = clampedRows
        grid = resizedGrid
        scrollTop = 0
        scrollBottom = rows - 1
        cursorX = min(max(cursorX, 0), cols - 1)
        cursorY = min(max(cursorY, 0), rows - 1)
        pendingWrap = false
    }

    func feed(_ data: Data) {
        for byte in data {
            processByte(byte)
        }
    }

    func visibleText() -> String {
        var lines: [String] = []
        lines.reserveCapacity(rows)
        for row in grid {
            var chars: [Character] = []
            chars.reserveCapacity(row.count)
            for cell in row where !cell.isWideContinuation {
                chars.append(Character(cell.scalar))
            }
            var str = String(chars)
            while str.last == " " {
                str.removeLast()
            }
            lines.append(str)
        }
        while lines.last?.isEmpty == true {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    private func emitReply(_ string: String) {
        guard !suppressReplies else { return }
        onReply?(Data(string.utf8))
    }

    private func blankCellWithBg() -> TermCell {
        var c = TermCell.blank
        c.bg = curBg
        return c
    }

    private func appendScrollback(_ line: [TermCell]) {
        guard !isUsingAlternateScreen else { return }
        scrollback.append(line)
        scrollbackAddedSinceReset += 1
        if scrollback.count > maxScrollback {
            scrollback.removeFirst(scrollback.count - maxScrollback)
        }
    }

    private static func mapDecSpecialGraphics(_ scalar: UnicodeScalar) -> UnicodeScalar {
        switch scalar.value {
        case 0x60: return "\u{25C6}" // ◆
        case 0x61: return "\u{2592}" // ▒
        case 0x66: return "\u{00B0}" // °
        case 0x67: return "\u{00B1}" // ±
        case 0x6A: return "\u{2518}" // ┘
        case 0x6B: return "\u{2510}" // ┐
        case 0x6C: return "\u{250C}" // ┌
        case 0x6D: return "\u{2514}" // └
        case 0x6E: return "\u{253C}" // ┼
        case 0x6F: return "\u{23BA}" // ⎺
        case 0x70: return "\u{23BB}" // ⎻
        case 0x71: return "\u{2500}" // ─
        case 0x72: return "\u{23BC}" // ⎼
        case 0x73: return "\u{23BD}" // ⎽
        case 0x74: return "\u{251C}" // ├
        case 0x75: return "\u{2524}" // ┤
        case 0x76: return "\u{2534}" // ┴
        case 0x77: return "\u{252C}" // ┬
        case 0x78: return "\u{2502}" // │
        case 0x79: return "\u{2264}" // ≤
        case 0x7A: return "\u{2265}" // ≥
        case 0x7B: return "\u{03C0}" // π
        case 0x7C: return "\u{2260}" // ≠
        case 0x7D: return "\u{00A3}" // £
        case 0x7E: return "\u{00B7}" // ·
        default: return scalar
        }
    }

    private static func cellWidth(for scalar: UnicodeScalar) -> Int {
        let v = scalar.value
        // Zero-width combining marks, variation selectors, and joiners.
        if (v >= 0x0300 && v <= 0x036F) ||
           (v >= 0x1AB0 && v <= 0x1AFF) ||
           (v >= 0x1DC0 && v <= 0x1DFF) ||
           (v >= 0x200B && v <= 0x200F) ||
           (v >= 0x20D0 && v <= 0x20FF) ||
           (v >= 0xFE00 && v <= 0xFE0F) ||
           (v >= 0xFE20 && v <= 0xFE2F) ||
           v == 0xFEFF {
            return 0
        }
        // Common East Asian Wide + Emoji ranges (2 cells).
        if (v >= 0x1100 && v <= 0x115F) ||
           (v >= 0x2E80 && v <= 0x303E) ||
           (v >= 0x3041 && v <= 0x33FF) ||
           (v >= 0x3400 && v <= 0x4DBF) ||
           (v >= 0x4E00 && v <= 0xA4CF) ||
           (v >= 0xAC00 && v <= 0xD7A3) ||
           (v >= 0xF900 && v <= 0xFAFF) ||
           (v >= 0xFE30 && v <= 0xFE6F) ||
           (v >= 0xFF01 && v <= 0xFF60) ||
           (v >= 0xFFE0 && v <= 0xFFE6) ||
           (v >= 0x1F300 && v <= 0x1FAFF) {
            return 2
        }
        return 1
    }

    private func processByte(_ byte: UInt8) {
        switch parseState {
        case .ground:
            if utf8Expected > 0 {
                if (byte & 0xC0) == 0x80 {
                    utf8Buffer.append(byte)
                    if utf8Buffer.count == utf8Expected {
                        if let str = String(bytes: utf8Buffer, encoding: .utf8),
                           let scalar = str.unicodeScalars.first {
                            putScalar(scalar)
                        } else {
                            putScalar("\u{FFFD}")
                        }
                        utf8Buffer.removeAll(keepingCapacity: true)
                        utf8Expected = 0
                    }
                    return
                } else {
                    utf8Buffer.removeAll(keepingCapacity: true)
                    utf8Expected = 0
                }
            }

            if byte == 0x1B {
                parseState = .escape
                return
            }
            if byte < 0x20 || byte == 0x7F {
                handleControl(byte)
                return
            }
            if byte < 0x80 {
                let raw = UnicodeScalar(byte)
                let activeGraphics = useG1 ? g1Graphics : g0Graphics
                putScalar(activeGraphics ? Self.mapDecSpecialGraphics(raw) : raw)
                return
            }
            if (byte & 0xE0) == 0xC0 {
                utf8Buffer = [byte]
                utf8Expected = 2
            } else if (byte & 0xF0) == 0xE0 {
                utf8Buffer = [byte]
                utf8Expected = 3
            } else if (byte & 0xF8) == 0xF0 {
                utf8Buffer = [byte]
                utf8Expected = 4
            }

        case .escape:
            switch byte {
            case 0x5B: // '[' CSI
                csiBuffer.removeAll(keepingCapacity: true)
                parseState = .csi
            case 0x5D: // ']' OSC
                oscBuffer.removeAll(keepingCapacity: true)
                parseState = .osc
            case 0x50, 0x5E, 0x5F: // 'P' DCS, '^' PM, '_' APC
                parseState = .dcs
            case 0x28: // '(' Designate G0 charset
                parseState = .escapeCharset(0)
            case 0x29: // ')' Designate G1 charset
                parseState = .escapeCharset(1)
            case 0x2A, 0x2B, 0x23, 0x20: // G2/G3/DECALN/7-bit control announcements
                parseState = .escapeIntermediate
            case 0x37: // '7' DECSC
                saveCursor(into: &decSavedCursor)
                parseState = .ground
            case 0x38: // '8' DECRC
                restoreCursor(from: decSavedCursor)
                parseState = .ground
            case 0x3D, 0x3E: // '=' DECKPAM / '>' DECKPNM
                parseState = .ground
            case 0x44: // 'D' IND
                lineFeed()
                parseState = .ground
            case 0x45: // 'E' NEL
                cursorX = 0
                pendingWrap = false
                lineFeed()
                parseState = .ground
            case 0x4D: // 'M' RI (Reverse Index)
                reverseIndex()
                parseState = .ground
            case 0x63: // 'c' RIS (Full Reset)
                fullReset()
                parseState = .ground
            default:
                parseState = .ground
            }

        case .escapeCharset(let slot):
            let isGraphics = (byte == 0x30) // '0' DEC Special Graphics
            if slot == 0 {
                g0Graphics = isGraphics
            } else {
                g1Graphics = isGraphics
            }
            parseState = .ground

        case .escapeIntermediate:
            parseState = .ground

        case .csi:
            if byte == 0x1B {
                parseState = .escape
                return
            }
            if byte < 0x20 {
                handleControl(byte)
                return
            }
            if byte >= 0x40 && byte <= 0x7E {
                dispatchCSI(finalByte: byte)
                csiBuffer.removeAll(keepingCapacity: true)
                parseState = .ground
            } else if csiBuffer.count < 160 {
                csiBuffer.append(byte)
            }

        case .osc:
            if byte == 0x07 {
                handleOSC()
                oscBuffer.removeAll(keepingCapacity: true)
                parseState = .ground
            } else if byte == 0x1B {
                parseState = .oscEsc
            } else if oscBuffer.count < 256 {
                oscBuffer.append(byte)
            }

        case .oscEsc:
            if byte == 0x5C { // '\' ST
                handleOSC()
                oscBuffer.removeAll(keepingCapacity: true)
                parseState = .ground
            } else if byte == 0x1B {
                parseState = .oscEsc
            } else {
                parseState = .osc
            }

        case .dcs:
            if byte == 0x1B {
                parseState = .dcsEsc
            }

        case .dcsEsc:
            if byte == 0x5C {
                parseState = .ground
            } else {
                parseState = .dcs
            }
        }
    }

    private func handleOSC() {
        guard !oscBuffer.isEmpty, let body = String(bytes: oscBuffer, encoding: .utf8) else { return }
        // Reply to xterm foreground/background color queries so Vim & agy
        // detect dark background instantaneously without startup timeouts.
        if body == "10;?" {
            emitReply("\u{1B}]10;rgb:e5e5/eded/e5e5\u{1B}\\")
        } else if body == "11;?" {
            emitReply("\u{1B}]11;rgb:0000/0000/0000\u{1B}\\")
        }
    }

    private func handleControl(_ byte: UInt8) {
        switch byte {
        case 0x08: // BS
            pendingWrap = false
            if cursorX > 0 {
                cursorX -= 1
            }
        case 0x09: // TAB
            pendingWrap = false
            let nextTab = ((cursorX / 8) + 1) * 8
            cursorX = min(nextTab, cols - 1)
        case 0x0A, 0x0B, 0x0C: // LF, VT, FF
            lineFeed()
        case 0x0D: // CR
            cursorX = 0
            pendingWrap = false
        case 0x0E: // SO (Shift Out -> G1)
            useG1 = true
        case 0x0F: // SI (Shift In -> G0)
            useG1 = false
        default:
            break
        }
    }

    private func putScalar(_ scalar: UnicodeScalar) {
        let width = Self.cellWidth(for: scalar)
        if width == 0 {
            return
        }
        lastPrintedScalar = scalar

        if pendingWrap {
            if autoWrap {
                cursorX = 0
                lineFeed()
            } else {
                cursorX = cols - 1
            }
            pendingWrap = false
        }
        guard cursorY >= 0 && cursorY < rows && cursorX >= 0 && cursorX < cols else { return }

        if width == 2 && cursorX == cols - 1 && autoWrap {
            grid[cursorY][cursorX] = blankCellWithBg()
            cursorX = 0
            lineFeed()
        }

        if insertMode {
            let shift = min(width, cols - cursorX)
            if cursorX + shift < cols {
                for c in stride(from: cols - 1, through: cursorX + shift, by: -1) {
                    grid[cursorY][c] = grid[cursorY][c - shift]
                }
            }
        }

        // Clean broken wide-character neighbors if overwriting half of a wide cell.
        if grid[cursorY][cursorX].isWideContinuation && cursorX > 0 {
            grid[cursorY][cursorX - 1] = blankCellWithBg()
        }

        grid[cursorY][cursorX] = TermCell(
            scalar: scalar,
            fg: curFg,
            bg: curBg,
            bold: curBold,
            dim: curDim,
            italic: curItalic,
            underline: curUnderline,
            inverse: curInverse,
            hidden: curHidden,
            strikethrough: curStrikethrough,
            isWideContinuation: false
        )

        if width == 2 && cursorX + 1 < cols {
            var cont = blankCellWithBg()
            cont.fg = curFg
            cont.bg = curBg
            cont.inverse = curInverse
            cont.isWideContinuation = true
            grid[cursorY][cursorX + 1] = cont
            if cursorX + 2 >= cols {
                cursorX = cols - 1
                pendingWrap = true
            } else {
                cursorX += 2
            }
        } else {
            if cursorX == cols - 1 {
                pendingWrap = true
            } else {
                cursorX += 1
            }
        }
    }

    private func lineFeed() {
        pendingWrap = false
        if cursorY == scrollBottom {
            scrollUp(lines: 1, top: scrollTop, bottom: scrollBottom)
        } else if cursorY < rows - 1 {
            cursorY += 1
        }
    }

    private func reverseIndex() {
        pendingWrap = false
        if cursorY == scrollTop {
            scrollDown(lines: 1, top: scrollTop, bottom: scrollBottom)
        } else if cursorY > 0 {
            cursorY -= 1
        }
    }

    private func scrollUp(lines: Int, top: Int, bottom: Int) {
        guard top >= 0 && bottom < rows && top <= bottom else { return }
        let count = min(max(lines, 1), bottom - top + 1)
        if top == 0 && bottom == rows - 1 {
            for i in 0..<count {
                appendScrollback(grid[i])
            }
        }
        let blankRow = Array(repeating: blankCellWithBg(), count: cols)
        if count < (bottom - top + 1) {
            for r in top...(bottom - count) {
                grid[r] = grid[r + count]
            }
        }
        for r in (bottom - count + 1)...bottom {
            grid[r] = blankRow
        }
    }

    private func scrollDown(lines: Int, top: Int, bottom: Int) {
        guard top >= 0 && bottom < rows && top <= bottom else { return }
        let count = min(max(lines, 1), bottom - top + 1)
        let blankRow = Array(repeating: blankCellWithBg(), count: cols)
        if count < (bottom - top + 1) {
            for r in stride(from: bottom, through: top + count, by: -1) {
                grid[r] = grid[r - count]
            }
        }
        for r in top..<(top + count) {
            grid[r] = blankRow
        }
    }

    private func saveCursor(into target: inout SavedCursor) {
        target = SavedCursor(
            x: cursorX,
            y: cursorY,
            fg: curFg,
            bg: curBg,
            bold: curBold,
            dim: curDim,
            italic: curItalic,
            underline: curUnderline,
            inverse: curInverse,
            hidden: curHidden,
            strikethrough: curStrikethrough,
            originMode: originMode,
            autoWrap: autoWrap,
            g0Graphics: g0Graphics,
            g1Graphics: g1Graphics,
            useG1: useG1
        )
    }

    private func restoreCursor(from saved: SavedCursor) {
        cursorX = min(max(saved.x, 0), cols - 1)
        cursorY = min(max(saved.y, 0), rows - 1)
        curFg = saved.fg
        curBg = saved.bg
        curBold = saved.bold
        curDim = saved.dim
        curItalic = saved.italic
        curUnderline = saved.underline
        curInverse = saved.inverse
        curHidden = saved.hidden
        curStrikethrough = saved.strikethrough
        originMode = saved.originMode
        autoWrap = saved.autoWrap
        g0Graphics = saved.g0Graphics
        g1Graphics = saved.g1Graphics
        useG1 = saved.useG1
        pendingWrap = false
    }

    private func softReset() {
        cursorVisible = true
        appCursorKeys = false
        bracketedPaste = false
        mouseTrackingEnabled = false
        sgrMouseMode = false
        autoWrap = true
        originMode = false
        insertMode = false
        g0Graphics = false
        g1Graphics = false
        useG1 = false
        scrollTop = 0
        scrollBottom = rows - 1
        pendingWrap = false
        resetSGR()
    }

    private func fullReset() {
        let wasAlt = isUsingAlternateScreen
        isUsingAlternateScreen = false
        altGrid = nil
        grid = Array(repeating: Array(repeating: TermCell.blank, count: cols), count: rows)
        cursorX = 0
        cursorY = 0
        softReset()
        if wasAlt {
            onAltScreenChanged?(false)
        }
    }

    private func resetSGR() {
        curFg = .defaultFg
        curBg = .defaultBg
        curBold = false
        curDim = false
        curItalic = false
        curUnderline = false
        curInverse = false
        curHidden = false
        curStrikethrough = false
    }

    private func enterAlternateScreen(saveCursorFirst: Bool) {
        if saveCursorFirst {
            saveCursor(into: &primarySavedCursor)
        }
        if !isUsingAlternateScreen {
            altGrid = grid
            grid = Array(repeating: Array(repeating: TermCell.blank, count: cols), count: rows)
            isUsingAlternateScreen = true
            cursorX = 0
            cursorY = 0
            pendingWrap = false
            scrollTop = 0
            scrollBottom = rows - 1
            onAltScreenChanged?(true)
        }
    }

    private func leaveAlternateScreen(restoreCursorAfter: Bool) {
        if isUsingAlternateScreen {
            if let saved = altGrid {
                grid = saved
                altGrid = nil
            }
            isUsingAlternateScreen = false
            scrollTop = 0
            scrollBottom = rows - 1
            pendingWrap = false
            onAltScreenChanged?(false)
        }
        if restoreCursorAfter {
            restoreCursor(from: primarySavedCursor)
        }
    }

    private struct CSIParam {
        var value: Int
        var subparams: [Int] = []
    }

    private func parseCSI(_ bytes: [UInt8]) -> (prefix: UInt8?, intermediate: UInt8?, params: [CSIParam]) {
        var idx = 0
        var prefix: UInt8?
        if let first = bytes.first, (first == 0x3F || first == 0x3E || first == 0x3D || first == 0x3C) {
            prefix = first
            idx = 1
        }
        var end = bytes.count
        var intermediate: UInt8?
        while end > idx && bytes[end - 1] >= 0x20 && bytes[end - 1] <= 0x2F {
            intermediate = bytes[end - 1]
            end -= 1
        }
        if idx >= end {
            return (prefix, intermediate, [])
        }
        var params: [CSIParam] = []
        var curGroup: [Int] = []
        var curVal = 0
        var hasDigit = false
        while idx < end {
            let b = bytes[idx]
            if b >= 0x30 && b <= 0x39 {
                curVal = min(curVal * 10 + Int(b - 0x30), 65535)
                hasDigit = true
            } else if b == 0x3A { // ':' subparameter separator
                curGroup.append(hasDigit ? curVal : 0)
                curVal = 0
                hasDigit = false
            } else if b == 0x3B { // ';' parameter separator
                curGroup.append(hasDigit ? curVal : 0)
                let head = curGroup.first ?? 0
                let tail = curGroup.count > 1 ? Array(curGroup.dropFirst()) : []
                params.append(CSIParam(value: head, subparams: tail))
                curGroup.removeAll(keepingCapacity: true)
                curVal = 0
                hasDigit = false
            }
            idx += 1
        }
        curGroup.append(hasDigit ? curVal : 0)
        let head = curGroup.first ?? 0
        let tail = curGroup.count > 1 ? Array(curGroup.dropFirst()) : []
        params.append(CSIParam(value: head, subparams: tail))
        return (prefix, intermediate, params)
    }

    private func param(_ params: [CSIParam], _ idx: Int, default defVal: Int) -> Int {
        guard idx < params.count else { return defVal }
        let v = params[idx].value
        return v == 0 ? defVal : v
    }

    private func dispatchCSI(finalByte: UInt8) {
        let parsed = parseCSI(csiBuffer)
        let prefix = parsed.prefix
        let intermediate = parsed.intermediate
        let params = parsed.params

        // DECSTR Soft Terminal Reset: CSI ! p
        if prefix == nil && intermediate == 0x21 && finalByte == 0x70 {
            softReset()
            return
        }

        // Secondary Device Attributes: CSI > c / CSI > 0 c
        if prefix == 0x3E && intermediate == nil && finalByte == 0x63 {
            if params.isEmpty || params[0].value == 0 {
                emitReply("\u{1B}[>0;276;0c")
            }
            return
        }

        if prefix == 0x3F { // '?' DEC private modes & queries
            if intermediate != nil {
                return
            }
            if finalByte == 0x6E && params.first?.value == 6 { // DECXCPR
                emitReply("\u{1B}[?\(cursorY + 1);\(cursorX + 1)R")
                return
            }
            let enable = (finalByte == 0x68) // 'h'
            let disable = (finalByte == 0x6C) // 'l'
            guard enable || disable else { return }
            for p in params {
                switch p.value {
                case 1:
                    appCursorKeys = enable
                case 6:
                    originMode = enable
                    cursorX = 0
                    cursorY = originMode ? scrollTop : 0
                    pendingWrap = false
                case 7:
                    autoWrap = enable
                case 25:
                    cursorVisible = enable
                case 47, 1047:
                    if enable { enterAlternateScreen(saveCursorFirst: false) }
                    else { leaveAlternateScreen(restoreCursorAfter: false) }
                case 1000, 1002, 1003:
                    mouseTrackingEnabled = enable
                case 1006:
                    sgrMouseMode = enable
                case 1048:
                    if enable { saveCursor(into: &decSavedCursor) }
                    else { restoreCursor(from: decSavedCursor) }
                case 1049:
                    if enable { enterAlternateScreen(saveCursorFirst: true) }
                    else { leaveAlternateScreen(restoreCursorAfter: true) }
                case 2004:
                    bracketedPaste = enable
                default:
                    break
                }
            }
            return
        }

        if prefix != nil || intermediate != nil {
            return
        }

        switch finalByte {
        case 0x41: // 'A' CUU
            pendingWrap = false
            let n = param(params, 0, default: 1)
            let minRow = (cursorY >= scrollTop) ? scrollTop : 0
            cursorY = max(minRow, cursorY - n)

        case 0x42, 0x65: // 'B' CUD, 'e' VPR
            pendingWrap = false
            let n = param(params, 0, default: 1)
            let maxRow = (cursorY <= scrollBottom) ? scrollBottom : rows - 1
            cursorY = min(maxRow, cursorY + n)

        case 0x43, 0x61: // 'C' CUF, 'a' HPR
            pendingWrap = false
            cursorX = min(cols - 1, cursorX + param(params, 0, default: 1))

        case 0x44: // 'D' CUB
            pendingWrap = false
            cursorX = max(0, cursorX - param(params, 0, default: 1))

        case 0x45: // 'E' CNL
            pendingWrap = false
            cursorX = 0
            cursorY = min(rows - 1, cursorY + param(params, 0, default: 1))

        case 0x46: // 'F' CPL
            pendingWrap = false
            cursorX = 0
            cursorY = max(0, cursorY - param(params, 0, default: 1))

        case 0x47, 0x60: // 'G' CHA, '`' HPA
            pendingWrap = false
            cursorX = min(cols - 1, max(0, param(params, 0, default: 1) - 1))

        case 0x64: // 'd' VPA
            pendingWrap = false
            let base = originMode ? scrollTop : 0
            let maxRow = originMode ? scrollBottom : (rows - 1)
            cursorY = min(maxRow, max(base, base + param(params, 0, default: 1) - 1))

        case 0x48, 0x66: // 'H' CUP, 'f' HVP
            pendingWrap = false
            let r = param(params, 0, default: 1) - 1
            let c = param(params, 1, default: 1) - 1
            let base = originMode ? scrollTop : 0
            let maxRow = originMode ? scrollBottom : (rows - 1)
            cursorY = min(maxRow, max(base, base + r))
            cursorX = min(cols - 1, max(0, c))

        case 0x5A: // 'Z' CBT (Cursor Backward Tabulation)
            pendingWrap = false
            let n = param(params, 0, default: 1)
            for _ in 0..<n {
                if cursorX > 0 {
                    cursorX = ((cursorX - 1) / 8) * 8
                }
            }

        case 0x4A: // 'J' ED (Erase in Display)
            let mode = params.first?.value ?? 0
            let blank = blankCellWithBg()
            switch mode {
            case 0: // cursor to end
                for c in cursorX..<cols { grid[cursorY][c] = blank }
                if cursorY + 1 < rows {
                    let rowBlank = Array(repeating: blank, count: cols)
                    for r in (cursorY + 1)..<rows { grid[r] = rowBlank }
                }
            case 1: // start to cursor
                let rowBlank = Array(repeating: blank, count: cols)
                for r in 0..<cursorY { grid[r] = rowBlank }
                for c in 0...min(cursorX, cols - 1) { grid[cursorY][c] = blank }
            case 2: // entire screen
                let rowBlank = Array(repeating: blank, count: cols)
                for r in 0..<rows { grid[r] = rowBlank }
            case 3: // entire screen + scrollback
                scrollback.removeAll(keepingCapacity: true)
                let rowBlank = Array(repeating: blank, count: cols)
                for r in 0..<rows { grid[r] = rowBlank }
            default:
                break
            }

        case 0x4B: // 'K' EL (Erase in Line)
            let mode = params.first?.value ?? 0
            let blank = blankCellWithBg()
            switch mode {
            case 0:
                for c in cursorX..<cols { grid[cursorY][c] = blank }
            case 1:
                for c in 0...min(cursorX, cols - 1) { grid[cursorY][c] = blank }
            case 2:
                grid[cursorY] = Array(repeating: blank, count: cols)
            default:
                break
            }

        case 0x4C: // 'L' IL (Insert Lines)
            if cursorY >= scrollTop && cursorY <= scrollBottom {
                scrollDown(lines: param(params, 0, default: 1), top: cursorY, bottom: scrollBottom)
            }

        case 0x4D: // 'M' DL (Delete Lines)
            if cursorY >= scrollTop && cursorY <= scrollBottom {
                scrollUp(lines: param(params, 0, default: 1), top: cursorY, bottom: scrollBottom)
            }

        case 0x53: // 'S' SU (Scroll Up)
            scrollUp(lines: param(params, 0, default: 1), top: scrollTop, bottom: scrollBottom)

        case 0x54: // 'T' SD (Scroll Down)
            scrollDown(lines: param(params, 0, default: 1), top: scrollTop, bottom: scrollBottom)

        case 0x40: // '@' ICH (Insert Characters)
            let n = min(param(params, 0, default: 1), cols - cursorX)
            let blank = blankCellWithBg()
            if cursorX + n < cols {
                for c in stride(from: cols - 1, through: cursorX + n, by: -1) {
                    grid[cursorY][c] = grid[cursorY][c - n]
                }
            }
            for c in cursorX..<(cursorX + n) {
                grid[cursorY][c] = blank
            }

        case 0x50: // 'P' DCH (Delete Characters)
            let n = min(param(params, 0, default: 1), cols - cursorX)
            let blank = blankCellWithBg()
            if cursorX + n < cols {
                for c in cursorX..<(cols - n) {
                    grid[cursorY][c] = grid[cursorY][c + n]
                }
            }
            for c in (cols - n)..<cols {
                grid[cursorY][c] = blank
            }

        case 0x58: // 'X' ECH (Erase Characters)
            let n = min(param(params, 0, default: 1), cols - cursorX)
            let blank = blankCellWithBg()
            for c in cursorX..<(cursorX + n) {
                grid[cursorY][c] = blank
            }

        case 0x62: // 'b' REP (Repeat preceding graphic character)
            if let scalar = lastPrintedScalar {
                let n = min(param(params, 0, default: 1), cols * rows)
                for _ in 0..<n {
                    putScalar(scalar)
                }
            }

        case 0x68, 0x6C: // 'h' SM / 'l' RM (ANSI modes: IRM = 4)
            let enable = (finalByte == 0x68)
            for p in params where p.value == 4 {
                insertMode = enable
            }

        case 0x6D: // 'm' SGR
            applySGR(params.isEmpty ? [CSIParam(value: 0)] : params)

        case 0x72: // 'r' DECSTBM (Set Scroll Region)
            let top = max(0, param(params, 0, default: 1) - 1)
            let bottom = min(rows - 1, param(params, 1, default: rows) - 1)
            if top < bottom {
                scrollTop = top
                scrollBottom = bottom
            } else {
                scrollTop = 0
                scrollBottom = rows - 1
            }
            cursorX = 0
            cursorY = originMode ? scrollTop : 0
            pendingWrap = false

        case 0x73: // 's' SCP
            saveCursor(into: &decSavedCursor)

        case 0x75: // 'u' RCP
            restoreCursor(from: decSavedCursor)

        case 0x74: // 't' XTWINOPS
            if params.first?.value == 18 {
                emitReply("\u{1B}[8;\(rows);\(cols)t")
                if !suppressReplies {
                    onSizeQueried?(cols, rows)
                }
            }

        case 0x6E: // 'n' DSR
            let code = params.first?.value ?? 0
            if code == 6 {
                emitReply("\u{1B}[\(cursorY + 1);\(cursorX + 1)R")
                if !suppressReplies && cursorY == rows - 1 && cursorX == cols - 1 {
                    onSizeQueried?(cols, rows)
                }
            } else if code == 5 {
                emitReply("\u{1B}[0n")
            }

        case 0x63: // 'c' DA1
            if params.isEmpty || params[0].value == 0 {
                emitReply("\u{1B}[?1;2c")
            }

        default:
            break
        }
    }

    private func applySGR(_ params: [CSIParam]) {
        var i = 0
        while i < params.count {
            let entry = params[i]
            let p = entry.value
            switch p {
            case 0:
                resetSGR()
            case 1:
                curBold = true
            case 2:
                curDim = true
            case 3:
                curItalic = true
            case 4:
                curUnderline = true
            case 7:
                curInverse = true
            case 8:
                curHidden = true
            case 9:
                curStrikethrough = true
            case 22:
                curBold = false
                curDim = false
            case 23:
                curItalic = false
            case 24:
                curUnderline = false
            case 27:
                curInverse = false
            case 28:
                curHidden = false
            case 29:
                curStrikethrough = false
            case 30...37:
                curFg = .indexed(UInt8(p - 30))
            case 38, 48:
                let isFg = (p == 38)
                var resolved: TermColor?
                if !entry.subparams.isEmpty {
                    // ITU T.416 colon form: 38:5:idx or 38:2:[cs]:r:g:b
                    let sub = entry.subparams
                    if sub[0] == 5 && sub.count >= 2 {
                        resolved = .indexed(UInt8(clamping: sub[1]))
                    } else if sub[0] == 2 {
                        if sub.count >= 5 {
                            resolved = .rgb(UInt8(clamping: sub[2]), UInt8(clamping: sub[3]), UInt8(clamping: sub[4]))
                        } else if sub.count >= 4 {
                            resolved = .rgb(UInt8(clamping: sub[1]), UInt8(clamping: sub[2]), UInt8(clamping: sub[3]))
                        }
                    }
                } else if i + 2 < params.count && params[i + 1].value == 5 {
                    resolved = .indexed(UInt8(clamping: params[i + 2].value))
                    i += 2
                } else if i + 4 < params.count && params[i + 1].value == 2 {
                    resolved = .rgb(
                        UInt8(clamping: params[i + 2].value),
                        UInt8(clamping: params[i + 3].value),
                        UInt8(clamping: params[i + 4].value)
                    )
                    i += 4
                }
                if let color = resolved {
                    if isFg { curFg = color } else { curBg = color }
                }
            case 39:
                curFg = .defaultFg
            case 40...47:
                curBg = .indexed(UInt8(p - 40))
            case 49:
                curBg = .defaultBg
            case 90...97:
                curFg = .indexed(UInt8(p - 90 + 8))
            case 100...107:
                curBg = .indexed(UInt8(p - 100 + 8))
            default:
                break
            }
            i += 1
        }
    }
}

/// CoreGraphics-rendered interactive VT100/xterm-256color terminal view with
/// direct `UIKeyInput`, Bluetooth keyboard support, SGR mouse tap/scroll,
/// zero TextKit relayout jumps, and smooth touch scrollback.
final class SerialTerminalCanvasView: UIView, UIKeyInput, @MainActor UIEditMenuInteractionDelegate {
    var onFocusChanged: ((Bool) -> Void)?
    var onGridSizeChanged: ((Int, Int) -> Void)?
    var onGuestSizeSynced: ((Int, Int) -> Void)?
    var onAltScreenChanged: ((Bool) -> Void)?
    var onStickyModifiersConsumed: (() -> Void)?

    var stickyCtrl: Bool = false
    var stickyAlt: Bool = false
    var fontSize: CGFloat = 10.5 {
        didSet {
            if abs(oldValue - fontSize) > 0.2 {
                updateFontMetrics()
                recomputeGridSize()
                setNeedsDisplay()
            }
        }
    }

    var isActiveTab: Bool = false {
        didSet {
            if isActiveTab != oldValue {
                if isActiveTab {
                    startPollingIfNeeded()
                    // Catch up any output buffered while on Display tab without
                    // firing stale DSR/DA replies into a live login prompt.
                    drainSerial(suppressReplies: true)
                } else {
                    stopPolling()
                    if isFirstResponder {
                        _ = resignFirstResponder()
                    }
                }
            }
        }
    }

    var wantsSoftwareKeyboard: Bool = false {
        didSet {
            guard oldValue != wantsSoftwareKeyboard else { return }
            syncKeyboardResponder()
        }
    }

    private let emulator = VT100TerminalEmulator(cols: 80, rows: 24)
    private var serialCursor: UInt64 = 0
    private var scrollOffsetLines: Int = 0
    private var panResidualY: CGFloat = 0
    private var pollTimer: Timer?
    private var editMenuInteraction: UIEditMenuInteraction?
    private var regularFont: UIFont = UIFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
    private var boldFont: UIFont = UIFont.monospacedSystemFont(ofSize: 10.5, weight: .bold)
    private var cellWidth: CGFloat = 6.3
    private var cellHeight: CGFloat = 13.0
    private var isProgrammaticResponderChange = false
    private let insetX: CGFloat = 6
    private let insetY: CGFloat = 6

    // MARK: - UITextInputTraits
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var keyboardType: UIKeyboardType = .asciiCapable
    var keyboardAppearance: UIKeyboardAppearance = .dark

    override var canBecomeFirstResponder: Bool { true }
    var hasText: Bool { true }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        backgroundColor = .black
        isOpaque = true
        contentMode = .redraw
        updateFontMetrics()

        emulator.onReply = { data in
            HengeVMBridge.shared.sendSerialData(data)
        }
        emulator.onSizeQueried = { [weak self] cols, rows in
            self?.onGuestSizeSynced?(cols, rows)
        }
        emulator.onAltScreenChanged = { [weak self] inAlt in
            self?.onAltScreenChanged?(inAlt)
        }

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.numberOfTapsRequired = 1
        addGestureRecognizer(tap)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.45
        addGestureRecognizer(longPress)

        let editMenu = UIEditMenuInteraction(delegate: self)
        addInteraction(editMenu)
        editMenuInteraction = editMenu
    }

    private func updateFontMetrics() {
        regularFont = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        boldFont = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
        let sample = "M" as NSString
        let size = sample.size(withAttributes: [.font: regularFont])
        cellWidth = max(size.width, 4.0)
        cellHeight = max(ceil(regularFont.lineHeight), 9)
    }

    private func recomputeGridSize() {
        let availW = max(bounds.width - insetX * 2, cellWidth * 20)
        let availH = max(bounds.height - insetY * 2, cellHeight * 6)
        let newCols = Int(floor(availW / cellWidth))
        let newRows = Int(floor(availH / cellHeight))
        if newCols != emulator.cols || newRows != emulator.rows {
            emulator.resize(cols: newCols, rows: newRows)
            onGridSizeChanged?(emulator.cols, emulator.rows)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        recomputeGridSize()
        setNeedsDisplay()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            if isActiveTab {
                startPollingIfNeeded()
                drainSerial(suppressReplies: true)
            }
            DispatchQueue.main.async { [weak self] in
                self?.syncKeyboardResponder()
            }
        } else {
            stopPolling()
        }
    }

    func startPollingIfNeeded() {
        guard pollTimer == nil, window != nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.drainSerial()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func drainSerial(suppressReplies forceSuppress: Bool = false) {
        let bridge = HengeVMBridge.shared
        let total = bridge.serialTotalBytes
        if total < serialCursor {
            serialCursor = 0
            scrollOffsetLines = 0
            emulator.clearAll()
            setNeedsDisplay()
        }
        let initialBacklog = (total > serialCursor) ? (total - serialCursor) : 0
        let maxChunks = forceSuppress ? 16 : 4
        var dirty = false
        for _ in 0..<maxChunks {
            let latestBefore = bridge.serialTotalBytes
            let remainingBefore = (latestBefore > serialCursor) ? (latestBefore - serialCursor) : 0
            let chunk = bridge.readSerialData(fromCursor: &serialCursor, maxBytes: 16384)
            if chunk.isEmpty { break }
            // Suppress DSR/DA/OSC replies during tab catch-up or large historical
            // bursts so stale boot-time probes never leak escape bytes into login:.
            emulator.suppressReplies = forceSuppress || initialBacklog > 1024 || remainingBefore > 1024
            emulator.resetScrollbackDelta()
            emulator.feed(chunk)
            emulator.suppressReplies = false
            if scrollOffsetLines > 0 {
                scrollOffsetLines = min(
                    scrollOffsetLines + emulator.scrollbackAddedSinceReset,
                    emulator.scrollback.count
                )
            }
            dirty = true
            if chunk.count < 16384 { break }
        }
        if dirty {
            setNeedsDisplay()
        }
    }

    func clearTerminalDisplay() {
        emulator.clearAll()
        scrollOffsetLines = 0
        setNeedsDisplay()
    }

    func copyVisibleScreen() -> String {
        emulator.visibleText()
    }

    func pasteText(_ text: String) {
        guard !text.isEmpty else { return }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\r")
            .replacingOccurrences(of: "\n", with: "\r")
        if emulator.bracketedPaste {
            sendBytes(Data("\u{1B}[200~\(normalized)\u{1B}[201~".utf8))
        } else {
            sendBytes(Data(normalized.utf8))
        }
    }

    func sendSpecialSequence(_ seq: String) {
        sendBytes(Data(seq.utf8))
    }

    func sendArrow(direction: Character) {
        let prefix = emulator.appCursorKeys ? "\u{1B}O" : "\u{1B}["
        sendBytes(Data("\(prefix)\(direction)".utf8))
    }

    func sendControlByte(_ byte: UInt8) {
        sendBytes(Data([byte]))
    }

    private func sendBytes(_ data: Data) {
        guard !data.isEmpty else { return }
        if scrollOffsetLines != 0 {
            scrollOffsetLines = 0
            setNeedsDisplay()
        }
        HengeVMBridge.shared.sendSerialData(data)
    }

    private func cellCoord(for point: CGPoint) -> (col: Int, row: Int) {
        let col = min(max(Int(floor((point.x - insetX) / cellWidth)) + 1, 1), emulator.cols)
        let row = min(max(Int(floor((point.y - insetY) / cellHeight)) + 1, 1), emulator.rows)
        return (col, row)
    }

    private func sendSgrMouse(button: Int, col: Int, row: Int, release: Bool) {
        let suffix = release ? "m" : "M"
        sendBytes(Data("\u{1B}[<\(button);\(col);\(row)\(suffix)".utf8))
    }

    private func syncKeyboardResponder() {
        guard window != nil, isActiveTab else { return }
        if wantsSoftwareKeyboard {
            if !isFirstResponder {
                isProgrammaticResponderChange = true
                _ = becomeFirstResponder()
                isProgrammaticResponderChange = false
                setNeedsDisplay()
            }
        } else {
            if isFirstResponder {
                isProgrammaticResponderChange = true
                _ = resignFirstResponder()
                isProgrammaticResponderChange = false
                setNeedsDisplay()
            }
        }
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if !isProgrammaticResponderChange {
            onFocusChanged?(false)
        }
        setNeedsDisplay()
        return ok
    }

    // MARK: - UIKeyInput

    func insertText(_ text: String) {
        guard !text.isEmpty else { return }
        var out = Data()
        var consumedSticky = false
        for scalar in text.unicodeScalars {
            if scalar == "\n" || scalar == "\r" {
                out.append(0x0D)
                continue
            }
            if stickyCtrl {
                consumedSticky = true
                let v = scalar.value
                if v >= 97 && v <= 122 {
                    out.append(UInt8(v - 96))
                } else if v >= 65 && v <= 90 {
                    out.append(UInt8(v - 64))
                } else if v >= 91 && v <= 95 {
                    out.append(UInt8(v - 64))
                } else if v == 32 {
                    out.append(0x00)
                } else {
                    out.append(contentsOf: String(scalar).utf8)
                }
            } else if stickyAlt {
                consumedSticky = true
                out.append(0x1B)
                out.append(contentsOf: String(scalar).utf8)
            } else {
                out.append(contentsOf: String(scalar).utf8)
            }
        }
        if consumedSticky {
            stickyCtrl = false
            stickyAlt = false
            onStickyModifiersConsumed?()
        }
        sendBytes(out)
    }

    func deleteBackward() {
        sendControlByte(0x7F)
    }

    // MARK: - Hardware Bluetooth Keyboard

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            guard let key = press.key else { continue }
            let mods = key.modifierFlags
            let ctrl = mods.contains(.control) || stickyCtrl
            let alt = mods.contains(.alternate) || stickyAlt
            switch key.keyCode {
            case .keyboardReturnOrEnter, .keypadEnter:
                sendControlByte(0x0D)
                handled = true
            case .keyboardDeleteOrBackspace:
                sendControlByte(0x7F)
                handled = true
            case .keyboardTab:
                sendControlByte(0x09)
                handled = true
            case .keyboardEscape:
                sendControlByte(0x1B)
                handled = true
            case .keyboardUpArrow:
                sendArrow(direction: "A")
                handled = true
            case .keyboardDownArrow:
                sendArrow(direction: "B")
                handled = true
            case .keyboardRightArrow:
                sendArrow(direction: "C")
                handled = true
            case .keyboardLeftArrow:
                sendArrow(direction: "D")
                handled = true
            case .keyboardHome:
                sendSpecialSequence("\u{1B}[H")
                handled = true
            case .keyboardEnd:
                sendSpecialSequence("\u{1B}[F")
                handled = true
            case .keyboardPageUp:
                sendSpecialSequence("\u{1B}[5~")
                handled = true
            case .keyboardPageDown:
                sendSpecialSequence("\u{1B}[6~")
                handled = true
            case .keyboardDeleteForward:
                sendSpecialSequence("\u{1B}[3~")
                handled = true
            default:
                let chars = key.characters
                if !chars.isEmpty && (ctrl || alt) {
                    var out = Data()
                    for scalar in chars.unicodeScalars {
                        if ctrl {
                            let v = scalar.value
                            if v >= 97 && v <= 122 { out.append(UInt8(v - 96)) }
                            else if v >= 65 && v <= 90 { out.append(UInt8(v - 64)) }
                            else if v >= 91 && v <= 95 { out.append(UInt8(v - 64)) }
                        } else if alt {
                            out.append(0x1B)
                            out.append(contentsOf: String(scalar).utf8)
                        }
                    }
                    if !out.isEmpty {
                        if stickyCtrl || stickyAlt {
                            stickyCtrl = false
                            stickyAlt = false
                            onStickyModifiersConsumed?()
                        }
                        sendBytes(out)
                        handled = true
                    }
                }
            }
        }
        if !handled {
            super.pressesBegan(presses, with: event)
        }
    }

    // MARK: - Touch Gestures & Edit Menu

    @objc private func handleTap(_ gr: UITapGestureRecognizer) {
        let wasFocused = isFirstResponder
        if !wasFocused {
            wantsSoftwareKeyboard = true
            onFocusChanged?(true)
        }
        if emulator.mouseTrackingEnabled && emulator.sgrMouseMode {
            let coord = cellCoord(for: gr.location(in: self))
            sendSgrMouse(button: 0, col: coord.col, row: coord.row, release: false)
            sendSgrMouse(button: 0, col: coord.col, row: coord.row, release: true)
        }
    }

    @objc private func handlePan(_ gr: UIPanGestureRecognizer) {
        if gr.state == .began {
            panResidualY = 0
        }
        let dy = gr.translation(in: self).y
        gr.setTranslation(.zero, in: self)
        panResidualY += dy
        let lines = Int(panResidualY / cellHeight)
        guard lines != 0 else { return }
        panResidualY -= CGFloat(lines) * cellHeight

        if emulator.isUsingAlternateScreen {
            if emulator.mouseTrackingEnabled && emulator.sgrMouseMode {
                let coord = cellCoord(for: gr.location(in: self))
                let button = lines > 0 ? 64 : 65 // wheel up / wheel down
                for _ in 0..<min(abs(lines), 5) {
                    sendSgrMouse(button: button, col: coord.col, row: coord.row, release: false)
                }
            } else {
                let dir: Character = lines > 0 ? "A" : "B"
                for _ in 0..<min(abs(lines), 5) {
                    sendArrow(direction: dir)
                }
            }
            return
        }

        let maxScroll = emulator.scrollback.count
        let next = min(max(scrollOffsetLines + lines, 0), maxScroll)
        if next != scrollOffsetLines {
            scrollOffsetLines = next
            setNeedsDisplay()
        }
    }

    @objc private func handleLongPress(_ gr: UILongPressGestureRecognizer) {
        guard gr.state == .began else { return }
        let feedback = UIImpactFeedbackGenerator(style: .medium)
        feedback.impactOccurred()
        let config = UIEditMenuConfiguration(identifier: nil, sourcePoint: gr.location(in: self))
        editMenuInteraction?.presentEditMenu(with: config)
    }

    func editMenuInteraction(
        _ interaction: UIEditMenuInteraction,
        menuFor configuration: UIEditMenuConfiguration,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        let pasteAction = UIAction(title: "Paste", image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in
            if let clip = UIPasteboard.general.string, !clip.isEmpty {
                self?.pasteText(clip)
            }
        }
        let copyAction = UIAction(title: "Copy Screen", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
            guard let self else { return }
            UIPasteboard.general.string = self.copyVisibleScreen()
        }
        let bottomAction = UIAction(title: "Jump to Bottom", image: UIImage(systemName: "arrow.down.to.line")) { [weak self] _ in
            guard let self else { return }
            self.scrollOffsetLines = 0
            self.setNeedsDisplay()
        }
        return UIMenu(children: [pasteAction, copyAction, bottomAction])
    }

    // MARK: - CoreGraphics Drawing

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.setFillColor(UIColor.black.cgColor)
        ctx.fill(rect)

        let totalScrollback = emulator.scrollback.count
        let clampedScroll = emulator.isUsingAlternateScreen ? 0 : min(max(scrollOffsetLines, 0), totalScrollback)
        let rows = emulator.rows
        let cols = emulator.cols

        let firstRow = max(0, Int(floor((rect.minY - insetY) / cellHeight)))
        let lastRow = min(rows - 1, Int(ceil((rect.maxY - insetY) / cellHeight)))
        guard firstRow <= lastRow else { return }

        let showCursor = (clampedScroll == 0 && emulator.cursorVisible)
        let cursorX = min(max(emulator.cursorX, 0), cols - 1)
        let cursorY = min(max(emulator.cursorY, 0), rows - 1)
        let cursorSolid = showCursor && isFirstResponder

        for screenRow in firstRow...lastRow {
            let lineIndex = totalScrollback - clampedScroll + screenRow
            let cells: [TermCell]
            if emulator.isUsingAlternateScreen {
                cells = emulator.grid[screenRow]
            } else if lineIndex < totalScrollback {
                cells = emulator.scrollback[lineIndex]
            } else {
                let gridRow = lineIndex - totalScrollback
                guard gridRow >= 0 && gridRow < emulator.grid.count else { continue }
                cells = emulator.grid[gridRow]
            }

            let y = insetY + CGFloat(screenRow) * cellHeight
            let lineCols = min(cells.count, cols)

            // 1. Draw non-black background runs first.
            var c = 0
            while c < lineCols {
                let cell = cells[c]
                let bg = cell.inverse ? cell.fg : cell.bg
                if bg == .defaultBg && !cell.inverse {
                    c += 1
                    continue
                }
                let startC = c
                c += 1
                while c < lineCols {
                    let next = cells[c]
                    let nextBg = next.inverse ? next.fg : next.bg
                    if nextBg == bg {
                        c += 1
                    } else {
                        break
                    }
                }
                ctx.setFillColor(bg.uiColor(isForeground: false).cgColor)
                ctx.fill(CGRect(
                    x: insetX + CGFloat(startC) * cellWidth,
                    y: y,
                    width: CGFloat(c - startC) * cellWidth,
                    height: cellHeight
                ))
            }

            // 2. Draw solid cursor fill before glyph so the character under cursor stays readable.
            if cursorSolid && screenRow == cursorY {
                let cursorRect = CGRect(
                    x: insetX + CGFloat(cursorX) * cellWidth,
                    y: y,
                    width: cellWidth,
                    height: cellHeight
                )
                ctx.setFillColor(UIColor(red: 0.30, green: 0.90, blue: 0.45, alpha: 0.92).cgColor)
                ctx.fill(cursorRect)
            }

            // 3. Draw text runs with matching style.
            c = 0
            while c < lineCols {
                let cell = cells[c]
                if cell.isWideContinuation || cell.hidden || (cell.scalar == " " && !cell.underline && !cell.strikethrough) {
                    c += 1
                    continue
                }
                let isCursorCell = (cursorSolid && screenRow == cursorY && c == cursorX)
                let fg = cell.inverse ? cell.bg : cell.fg
                let bold = cell.bold
                let dim = cell.dim
                let underline = cell.underline
                let strikethrough = cell.strikethrough
                let startC = c
                var run = String(cell.scalar)
                c += 1
                if !isCursorCell && (c >= lineCols || !cells[c].isWideContinuation) {
                    while c < lineCols {
                        if cursorSolid && screenRow == cursorY && c == cursorX { break }
                        let next = cells[c]
                        if next.isWideContinuation || next.hidden { break }
                        if c + 1 < lineCols && cells[c + 1].isWideContinuation { break }
                        let nextFg = next.inverse ? next.bg : next.fg
                        if nextFg == fg && next.bold == bold && next.dim == dim &&
                           next.underline == underline && next.strikethrough == strikethrough {
                            run.unicodeScalars.append(next.scalar)
                            c += 1
                        } else {
                            break
                        }
                    }
                }
                var color = isCursorCell ? UIColor.black : fg.uiColor(isForeground: true)
                if dim && !isCursorCell {
                    color = color.withAlphaComponent(0.6)
                }
                var attrs: [NSAttributedString.Key: Any] = [
                    .font: bold ? boldFont : regularFont,
                    .foregroundColor: color,
                ]
                if underline {
                    attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
                }
                if strikethrough {
                    attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                }
                (run as NSString).draw(
                    at: CGPoint(x: insetX + CGFloat(startC) * cellWidth, y: y),
                    withAttributes: attrs
                )
            }

            // 4. Hollow cursor outline when unfocused so cursor position stays visible.
            if showCursor && !cursorSolid && screenRow == cursorY {
                let cursorRect = CGRect(
                    x: insetX + CGFloat(cursorX) * cellWidth + 0.5,
                    y: y + 0.5,
                    width: max(cellWidth - 1.0, 2.0),
                    height: max(cellHeight - 1.0, 2.0)
                )
                ctx.setStrokeColor(UIColor(red: 0.30, green: 0.90, blue: 0.45, alpha: 0.85).cgColor)
                ctx.setLineWidth(1.0)
                ctx.stroke(cursorRect)
            }
        }

        // 5. Subtle scrollback indicator pill when scrolled up.
        if clampedScroll > 0 {
            let label = "↑ \(clampedScroll)L" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: UIColor.white,
            ]
            let sz = label.size(withAttributes: attrs)
            let pill = CGRect(
                x: bounds.width - sz.width - 18,
                y: 8,
                width: sz.width + 12,
                height: sz.height + 6
            )
            let path = UIBezierPath(roundedRect: pill, cornerRadius: 6)
            UIColor(white: 0.22, alpha: 0.88).setFill()
            path.fill()
            label.draw(at: CGPoint(x: pill.minX + 6, y: pill.minY + 3), withAttributes: attrs)
        }
    }
}

enum SerialTerminalCommand: Equatable {
    case sendSequence(UUID, String)
    case sendByte(UUID, UInt8)
    case sendArrow(UUID, Character)
    case paste(UUID, String)
    case copyScreen(UUID)
    case clear(UUID)
}

struct SerialTerminalRepresentable: UIViewRepresentable {
    final class Coordinator {
        var lastCommandID: UUID?
    }

    var isActiveTab: Bool
    @Binding var focusKeyboard: Bool
    @Binding var stickyCtrl: Bool
    @Binding var stickyAlt: Bool
    var fontSize: CGFloat
    var pendingCommand: SerialTerminalCommand?
    var onCommandConsumed: () -> Void
    var onGridSizeChanged: (Int, Int) -> Void
    var onGuestSizeSynced: (Int, Int) -> Void
    var onAltScreenChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> SerialTerminalCanvasView {
        let view = SerialTerminalCanvasView(frame: .zero)
        view.fontSize = fontSize
        view.isActiveTab = isActiveTab
        view.wantsSoftwareKeyboard = focusKeyboard && isActiveTab
        view.stickyCtrl = stickyCtrl
        view.stickyAlt = stickyAlt
        view.onFocusChanged = { focused in
            DispatchQueue.main.async {
                if focusKeyboard != focused {
                    focusKeyboard = focused
                }
            }
        }
        view.onStickyModifiersConsumed = {
            DispatchQueue.main.async {
                stickyCtrl = false
                stickyAlt = false
            }
        }
        view.onGridSizeChanged = { cols, rows in
            DispatchQueue.main.async {
                onGridSizeChanged(cols, rows)
            }
        }
        view.onGuestSizeSynced = { cols, rows in
            DispatchQueue.main.async {
                onGuestSizeSynced(cols, rows)
            }
        }
        view.onAltScreenChanged = { inAlt in
            DispatchQueue.main.async {
                onAltScreenChanged(inAlt)
            }
        }
        return view
    }

    func updateUIView(_ uiView: SerialTerminalCanvasView, context: Context) {
        uiView.fontSize = fontSize
        uiView.isActiveTab = isActiveTab
        uiView.stickyCtrl = stickyCtrl
        uiView.stickyAlt = stickyAlt
        uiView.wantsSoftwareKeyboard = focusKeyboard && isActiveTab

        if let cmd = pendingCommand {
            let cmdID: UUID
            switch cmd {
            case .sendSequence(let id, _),
                 .sendByte(let id, _),
                 .sendArrow(let id, _),
                 .paste(let id, _),
                 .copyScreen(let id),
                 .clear(let id):
                cmdID = id
            }
            if context.coordinator.lastCommandID != cmdID {
                context.coordinator.lastCommandID = cmdID
                switch cmd {
                case .sendSequence(_, let seq):
                    uiView.sendSpecialSequence(seq)
                case .sendByte(_, let byte):
                    uiView.sendControlByte(byte)
                case .sendArrow(_, let dir):
                    uiView.sendArrow(direction: dir)
                case .paste(_, let text):
                    uiView.pasteText(text)
                case .copyScreen:
                    UIPasteboard.general.string = uiView.copyVisibleScreen()
                case .clear:
                    uiView.clearTerminalDisplay()
                }
                let consumed = onCommandConsumed
                DispatchQueue.main.async {
                    consumed()
                }
            }
        }
    }

    static func dismantleUIView(_ uiView: SerialTerminalCanvasView, coordinator: Coordinator) {
        uiView.stopPolling()
    }
}
