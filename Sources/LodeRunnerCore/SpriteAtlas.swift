import Foundation

/// Original 104 sprites, each 10 visible pixels wide and 11 pixels high.
public struct SpriteAtlas: Sendable {
    public static let spriteCount = 104
    public static let width = 10
    public static let height = 11
    private static let playerAnimations = [
        0x0B, 0x0C, 0x0D, 0x18, 0x19, 0x1A, 0x0F, 0x13,
        0x09, 0x10, 0x11, 0x15, 0x16, 0x17, 0x25, 0x14, 0x0E, 0x12,
    ]
    private static let guardAnimations = [
        0x08, 0x2B, 0x2C, 0x30, 0x31, 0x32, 0x36, 0x28,
        0x29, 0x2A, 0x2D, 0x2E, 0x2F, 0x35, 0x33, 0x34,
    ]
    private let bytes: [UInt8]

    public init(bytes: [UInt8]) {
        precondition(bytes.count == Self.spriteCount * Self.height * 2)
        self.bytes = bytes
    }

    public static func bundled() throws -> SpriteAtlas {
        let url = try PortResource.url("sprites", extension: "bin")
        return SpriteAtlas(bytes: Array(try Data(contentsOf: url)))
    }

    public func pixel(sprite: Int, x: Int, y: Int) -> Bool {
        precondition((0..<Self.spriteCount).contains(sprite))
        precondition((0..<Self.width).contains(x) && (0..<Self.height).contains(y))
        let byteIndex = y * 2 * Self.spriteCount + (x < 7 ? 0 : Self.spriteCount) + sprite
        return bytes[byteIndex] & (1 << (x < 7 ? x : x - 7)) != 0
    }

    public static func playerSprite(animation: Int) -> Int {
        playerAnimations[max(0, min(animation, playerAnimations.count - 1))]
    }

    public static func guardSprite(animation: Int) -> Int {
        guardAnimations[max(0, min(animation, guardAnimations.count - 1))]
    }

    /// The 6502 uses one counter for both directions: left 0...12, right 12...24.
    public static func digAnimationFrame(direction: FacingDirection, rawFrame: Int) -> Int? {
        let frame = rawFrame - (direction == .right ? 12 : 0)
        return (0...12).contains(frame) ? frame : nil
    }

    /// DIG_BRICK_SPRITES, with each image shown for two game steps.
    public static func digBrickSprite(frame: Int) -> Int? {
        guard (0..<12).contains(frame) else { return nil }
        return 0x1F + frame / 2
    }

    /// DIG_DEBRIS_LEFT_SPRITES and DIG_DEBRIS_RIGHT_SPRITES.
    public static func digDebrisSprite(direction: FacingDirection, frame: Int) -> Int? {
        guard (0..<8).contains(frame) else { return nil }
        if frame >= 4 { return 0x1D + (frame - 4) / 2 }
        return (direction == .left ? 0x1B : 0x26) + frame / 2
    }

    public static func screenPosition(_ position: Position, xOffset: Int, yOffset: Int) -> Position {
        let rowOffsets = [-5, -3, 0, 2, 4]
        return Position(column: position.column * width + (xOffset - 2) * 2,
                        row: position.row * height + rowOffsets[max(0, min(yOffset, 4))])
    }

    public func overlaps(sprite first: Int, at firstPosition: Position,
                         sprite second: Int, at secondPosition: Position) -> Bool {
        let left = max(firstPosition.column, secondPosition.column)
        let right = min(firstPosition.column + Self.width, secondPosition.column + Self.width)
        let top = max(firstPosition.row, secondPosition.row)
        let bottom = min(firstPosition.row + Self.height, secondPosition.row + Self.height)
        guard left < right, top < bottom else { return false }
        for y in top..<bottom {
            for x in left..<right {
                if pixel(sprite: first, x: x - firstPosition.column, y: y - firstPosition.row),
                   pixel(sprite: second, x: x - secondPosition.column, y: y - secondPosition.row) {
                    return true
                }
            }
        }
        return false
    }
}
