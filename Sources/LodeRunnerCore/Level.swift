import Foundation

enum PortResource {
    static func url(_ name: String, extension fileExtension: String) throws -> URL {
        if let url = Bundle.main.url(forResource: name, withExtension: fileExtension) {
            return url
        }
        #if SWIFT_PACKAGE
        if let url = Bundle.module.url(forResource: name, withExtension: fileExtension) {
            return url
        }
        #endif
        throw CocoaError(.fileNoSuchFile)
    }
}

public enum Tile: UInt8, CaseIterable, Sendable {
    case empty = 0
    case brick = 1
    case stone = 2
    case ladder = 3
    case rope = 4
    case trap = 5
    case invisibleLadder = 6
    case gold = 7
    case guardSprite = 8
    case playerSprite = 9
}

public enum LevelError: Error, Equatable {
    case invalidSectorSize(Int)
    case invalidBoardSize(Int)
    case invalidCatalogSize(Int)
    case levelOutOfRange(Int)
    case missingPlayer
}

public struct Position: Equatable, Sendable {
    public let column: Int
    public let row: Int

    public init(column: Int, row: Int) {
        self.column = column
        self.row = row
    }
}

public struct Board: Equatable, Sendable {
    public static let width = 28
    public static let height = 16
    public static let cellCount = width * height

    private var cells: [Tile]

    public init(cells: [Tile]) throws {
        guard cells.count == Self.cellCount else { throw LevelError.invalidBoardSize(cells.count) }
        self.cells = cells
    }

    public subscript(row row: Int, column column: Int) -> Tile {
        get {
            precondition((0..<Self.height).contains(row) && (0..<Self.width).contains(column))
            return cells[row * Self.width + column]
        }
        set {
            precondition((0..<Self.height).contains(row) && (0..<Self.width).contains(column))
            cells[row * Self.width + column] = newValue
        }
    }

    public var rowsAsDigits: [String] {
        (0..<Self.height).map { row in
            String((0..<Self.width).map { column in
                Character(String(self[row: row, column: column].rawValue))
            })
        }
    }
}

/// One original 256-byte disk sector. The trailing 32 bytes survive edits.
public struct LevelSector: Equatable, Sendable {
    public static let byteCount = 256
    public static let packedBoardByteCount = 224

    public let bytes: [UInt8]

    public init(bytes: [UInt8]) throws {
        guard bytes.count == Self.byteCount else { throw LevelError.invalidSectorSize(bytes.count) }
        self.bytes = bytes
    }

    public var board: Board {
        var cells: [Tile] = []
        cells.reserveCapacity(Board.cellCount)
        for byte in bytes.prefix(Self.packedBoardByteCount) {
            cells.append(Tile(rawValue: byte & 0x0F) ?? .empty)
            cells.append(Tile(rawValue: byte >> 4) ?? .empty)
        }
        // The packed length fixes the board size, so this cannot throw.
        return try! Board(cells: cells)
    }

    public func replacingBoard(_ board: Board) -> LevelSector {
        var encoded = bytes
        for row in 0..<Board.height {
            for pair in 0..<(Board.width / 2) {
                let low = board[row: row, column: pair * 2].rawValue
                let high = board[row: row, column: pair * 2 + 1].rawValue
                encoded[row * (Board.width / 2) + pair] = low | (high << 4)
            }
        }
        return try! LevelSector(bytes: encoded)
    }
}

public struct LevelCatalog: Sendable {
    public static let levelCount = 150
    private let bytes: [UInt8]

    public init(bytes: [UInt8]) throws {
        guard bytes.count == Self.levelCount * LevelSector.byteCount else {
            throw LevelError.invalidCatalogSize(bytes.count)
        }
        self.bytes = bytes
    }

    public static func bundled() throws -> LevelCatalog {
        let url = try PortResource.url("levels", extension: "bin")
        return try LevelCatalog(bytes: Array(Data(contentsOf: url)))
    }

    /// One-based level number, matching the game's displayed level.
    public func sector(level: Int) throws -> LevelSector {
        guard (1...Self.levelCount).contains(level) else { throw LevelError.levelOutOfRange(level) }
        let start = (level - 1) * LevelSector.byteCount
        return try LevelSector(bytes: Array(bytes[start..<(start + LevelSector.byteCount)]))
    }

    /// After level 150, the original loader returns to the first disk level.
    public func progressionSector(displayedLevel: Int) throws -> LevelSector {
        guard displayedLevel > 0 else { throw LevelError.levelOutOfRange(displayedLevel) }
        return try sector(level: (displayedLevel - 1) % Self.levelCount + 1)
    }
}

public struct PlayerState: Equatable, Sendable {
    public var position: Position
    public var xOffset: Int
    public var yOffset: Int
    public var animation: Int
    /// Nil until a movement selects a facing direction; level loading leaves it uninitialized.
    public var facing: FacingDirection? = nil
}

public struct GuardState: Equatable, Sendable {
    public var position: Position
    public var xOffset: Int
    public var yOffset: Int
    public var goldTimer: Int
    public var resurrectionTimer: Int
    public var animation: Int = 0
    public var facing: FacingDirection? = nil
}

/// Logical state after DRAW_LEVEL_PAGE2; screen-specific trap rendering is separate.
public struct LevelStartState: Equatable, Sendable {
    public let activeBoard: Board
    public let backgroundBoard: Board
    public let player: PlayerState
    public let guards: [GuardState]
    public let invisibleLadders: [Position]
    public let goldRemaining: Int
}

public enum LevelLoader {
    public static func playState(from sector: LevelSector) throws -> LevelStartState {
        var active = sector.board
        var background = active
        var player: PlayerState?
        var guards: [GuardState] = []
        var ladders: [Position] = []
        var gold = 0

        // The 6502 scans from bottom right to top left; this also determines array order.
        for row in (0..<Board.height).reversed() {
            for column in (0..<Board.width).reversed() {
                let position = Position(column: column, row: row)
                switch active[row: row, column: column] {
                case .invisibleLadder:
                    if ladders.count < 45 { ladders.append(position) }
                    active[row: row, column: column] = .empty
                    background[row: row, column: column] = .empty
                case .gold:
                    gold = (gold + 1) & 0xFF
                case .guardSprite:
                    if guards.count < 5 {
                        guards.append(GuardState(position: position, xOffset: 2, yOffset: 2,
                                                 goldTimer: 0, resurrectionTimer: 0))
                        background[row: row, column: column] = .empty
                    } else {
                        active[row: row, column: column] = .empty
                        background[row: row, column: column] = .empty
                    }
                case .playerSprite:
                    if player == nil {
                        player = PlayerState(position: position, xOffset: 2, yOffset: 2, animation: 8)
                        background[row: row, column: column] = .empty
                    } else {
                        active[row: row, column: column] = .empty
                        background[row: row, column: column] = .empty
                    }
                default:
                    break
                }
            }
        }
        guard let player else { throw LevelError.missingPlayer }
        return LevelStartState(activeBoard: active, backgroundBoard: background,
                               player: player, guards: guards, invisibleLadders: ladders,
                               goldRemaining: gold)
    }
}
