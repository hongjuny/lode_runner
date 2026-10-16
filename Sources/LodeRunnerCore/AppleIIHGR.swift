import Foundation

/// A visible Apple II hi-res page. Lode Runner uses the high-bit color phase,
/// which gives isolated pixels blue/orange and adjacent set pixels white.
public struct AppleIIHGR: Sendable {
    public static let width = 280
    public static let height = 192

    public enum Ink: UInt8, Sendable { case black, blue, orange, white, violet, green }

    private var bits = [Bool](repeating: false, count: width * height)
    private var phase = [Bool](repeating: true, count: (width / 7) * height)

    public init() {}

    public init(rawPageBytes: [UInt8]) {
        precondition(rawPageBytes.count == (Self.width / 7) * Self.height)
        for y in 0..<Self.height {
            for byteColumn in 0..<(Self.width / 7) {
                let index = y * (Self.width / 7) + byteColumn
                let value = rawPageBytes[index]
                phase[index] = value & 0x80 != 0
                for bit in 0..<7 where value & (1 << bit) != 0 {
                    bits[y * Self.width + byteColumn * 7 + bit] = true
                }
            }
        }
    }

    public static func bundledSplash() throws -> AppleIIHGR {
        let url = try PortResource.url("splash", extension: "bin")
        return AppleIIHGR(rawPageBytes: Array(try Data(contentsOf: url)))
    }

    public mutating func setPixel(x: Int, y: Int) {
        guard (0..<Self.width).contains(x), (0..<Self.height).contains(y) else { return }
        bits[y * Self.width + x] = true
    }

    public mutating func draw(sprite: Int, x: Int, y: Int, atlas: SpriteAtlas) {
        for sy in 0..<SpriteAtlas.height {
            for sx in 0..<SpriteAtlas.width where atlas.pixel(sprite: sprite, x: sx, y: sy) {
                setPixel(x: x + sx, y: y + sy)
            }
        }
    }

    /// Drawing a sprite to HGR replaces the ten-pixel cell, so partial dig
    /// sprites erase the intact brick instead of being ORed over it.
    public mutating func replace(sprite: Int, x: Int, y: Int, atlas: SpriteAtlas) {
        for sy in 0..<SpriteAtlas.height {
            for sx in 0..<SpriteAtlas.width {
                let px = x + sx, py = y + sy
                guard (0..<Self.width).contains(px), (0..<Self.height).contains(py) else { continue }
                bits[py * Self.width + px] = atlas.pixel(sprite: sprite, x: sx, y: sy)
                phase[py * (Self.width / 7) + px / 7] = true
            }
        }
    }

    public mutating func draw(character: Character, column: Int, row: Int, atlas: SpriteAtlas) {
        let sprite: Int
        if let digit = character.wholeNumberValue, (0...9).contains(digit) {
            sprite = 59 + digit
        } else if let ascii = character.uppercased().utf8.first,
                  (65...90).contains(ascii) {
            sprite = Int(ascii) + 4
        } else {
            switch character {
            case " ": sprite = 0
            case ">": sprite = 95
            case ".": sprite = 96
            case "(": sprite = 97
            case ")": sprite = 98
            case "/": sprite = 99
            case "-": sprite = 100
            case "<": sprite = 101
            default: return
            }
        }
        draw(sprite: sprite, x: column * 10, y: row * 11, atlas: atlas)
    }

    public mutating func draw(text: String, column: Int, row: Int, atlas: SpriteAtlas) {
        for (offset, character) in text.enumerated() {
            draw(character: character, column: column + offset, row: row, atlas: atlas)
        }
    }

    public func ink(x: Int, y: Int) -> Ink {
        guard (0..<Self.width).contains(x), (0..<Self.height).contains(y) else { return .black }
        let index = y * Self.width + x
        let here = bits[index]
        let left = x > 0 && bits[index - 1]
        let right = x + 1 < Self.width && bits[index + 1]
        // A one-bit gap between two lit pixels carries the same chroma as
        // those neighboring pixels (the brick pattern is a solid blue bar).
        let colorX = !here && left && right ? x - 1 : x
        let shifted = phase[y * (Self.width / 7) + colorX / 7]
        let color: Ink = shifted
            ? (colorX.isMultiple(of: 2) ? .blue : .orange)
            : (colorX.isMultiple(of: 2) ? .violet : .green)
        if here { return left || right ? .white : color }
        return left && right ? color : .black
    }
}
