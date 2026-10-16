/// One MOVE_PLAYER call. Sound, drawing, timers and guard AI consume the events separately.
public enum FacingDirection: Equatable, Sendable { case left, right }

public enum PlayerAction: Equatable, Sendable { case up, down, digLeft, digRight }
public enum HorizontalAction: Equatable, Sendable { case left, right }

/// Primary I/K/U/O command and fallback J/L command are distinct in the original input state.
public struct PlayerInput: Equatable, Sendable {
    public var primary: PlayerAction?
    public var horizontal: HorizontalAction?

    public init(primary: PlayerAction? = nil, horizontal: HorizontalAction? = nil) {
        self.primary = primary
        self.horizontal = horizontal
    }
}

public struct DugHole: Equatable, Sendable {
    public let slot: Int
    public let position: Position
    public var fillTimer: Int

    public init(position: Position, fillTimer: Int, slot: Int = 0) {
        self.slot = slot
        self.position = position
        self.fillTimer = fillTimer
    }
}

public enum PlayerEvent: Equatable, Sendable {
    case moved
    case falling
    case goldCollected(Position)
    case digging(FacingDirection, Int)
    case holeOpened(Position)
}

public struct GameState: Equatable, Sendable {
    public var level: Int = 1
    public var lives: Int = 5
    public var alive: Bool = true
    public var levelCompleted: Bool = false
    public var activeBoard: Board
    public var backgroundBoard: Board
    public var player: PlayerState
    public var guards: [GuardState]
    public var invisibleLadders: [Position]
    public var goldRemaining: Int
    public var score: Int = 0
    public var holes: [DugHole] = []
    public var digDirection: FacingDirection? = nil
    public var digAnimation: Int = 0
    /// Original $9B: suppresses the landing sound after an ordinary input step.
    public var fallSoundLatch: Bool = false
    public var guardResurrectColumn: Int = 0
    public var guardPhase: Int = 2
    /// One-based GUARD_NUM in the 6502; zero means no guard selected yet.
    public var guardNumber: Int = 0
    public var guardPatternOffset: Int = 0

    public init(level start: LevelStartState, number: Int = 1, lives: Int = 5) {
        level = number
        self.lives = lives
        guardPatternOffset = max(0, (number - 1) / LevelCatalog.levelCount)
        activeBoard = start.activeBoard
        backgroundBoard = start.backgroundBoard
        player = start.player
        guards = start.guards
        invisibleLadders = start.invisibleLadders
        goldRemaining = start.goldRemaining
    }

    private var row: Int { player.position.row }
    private var column: Int { player.position.column }

    private func active(_ row: Int, _ column: Int) -> Tile {
        activeBoard[row: row, column: column]
    }

    private func background(_ row: Int, _ column: Int) -> Tile {
        backgroundBoard[row: row, column: column]
    }

    /// Advances the player only; the surrounding game loop handles timers and guards.
    public mutating func step(input: PlayerInput = .init()) -> [PlayerEvent] {
        var events: [PlayerEvent] = []
        if let digDirection {
            _ = dig(digDirection, continuing: true, events: &events)
            return events
        }
        if shouldFall {
            fall(events: &events)
            return events
        }
        fallSoundLatch = true
        if let primary = input.primary {
            let succeeded: Bool
            switch primary {
            case .up: succeeded = moveVertical(-1, events: &events)
            case .down: succeeded = moveVertical(1, events: &events)
            case .digLeft: succeeded = dig(.left, continuing: false, events: &events)
            case .digRight: succeeded = dig(.right, continuing: false, events: &events)
            }
            if succeeded { return events }
            // Digging sets both original command bytes to a sentinel, so no fallback runs.
            if primary == .digLeft || primary == .digRight { return events }
        }
        if let horizontal = input.horizontal {
            _ = moveHorizontal(horizontal == .left ? -1 : 1, events: &events)
        }
        return events
    }

    private var shouldFall: Bool {
        let here = background(row, column)
        if here == .ladder || (here == .rope && player.yOffset == 2) { return false }
        if player.yOffset < 2 { return true }
        if row == Board.height - 1 { return false }
        let below = active(row + 1, column)
        if below == .empty { return true }
        if below == .guardSprite { return false }
        let ground = background(row + 1, column)
        return ground != .brick && ground != .stone && ground != .ladder
    }

    private mutating func fall(events: inout [PlayerEvent]) {
        fallSoundLatch = false
        player.animation = player.facing == .left ? 7 : 15
        nudgeColumn(events: &events)
        player.yOffset += 1
        if player.yOffset == 5 {
            player.yOffset = 0
            changeCell(row: row + 1, column: column)
        } else {
            collectGold(events: &events)
        }
        events.append(.falling)
    }

    private mutating func moveVertical(_ direction: Int, events: inout [PlayerEvent]) -> Bool {
        if direction < 0 {
            if background(row, column) == .ladder {
                if player.yOffset <= 2 {
                    if row == 0 { return false }
                    let above = active(row - 1, column)
                    if above == .brick || above == .stone || above == .trap { return false }
                }
            } else if player.yOffset <= 2 || row == Board.height - 1 || background(row + 1, column) != .ladder {
                return false
            }
        } else if player.yOffset >= 2 {
            if row == Board.height - 1 { return false }
            let below = active(row + 1, column)
            if below == .stone || below == .brick { return false }
        }
        nudgeColumn(events: &events)
        player.yOffset += direction
        if player.yOffset < 0 {
            player.yOffset = 4
            changeCell(row: row - 1, column: column)
        } else if player.yOffset > 4 {
            player.yOffset = 0
            changeCell(row: row + 1, column: column)
        } else {
            collectGold(events: &events)
        }
        advanceAnimation(lower: 16, upper: 17)
        events.append(.moved)
        return true
    }

    private mutating func moveHorizontal(_ direction: Int, events: inout [PlayerEvent]) -> Bool {
        if direction < 0 {
            if player.xOffset <= 2 {
                if column == 0 { return false }
                let left = active(row, column - 1)
                if left == .brick || left == .stone || left == .trap { return false }
            }
            player.facing = .left
        } else {
            if player.xOffset >= 2 {
                if column == Board.width - 1 { return false }
                let right = active(row, column + 1)
                if right == .brick || right == .stone || right == .trap { return false }
            }
            player.facing = .right
        }
        nudgeRow(events: &events)
        player.xOffset += direction
        if player.xOffset < 0 {
            player.xOffset = 4
            changeCell(row: row, column: column - 1)
        } else if player.xOffset > 4 {
            player.xOffset = 0
            changeCell(row: row, column: column + 1)
        } else {
            collectGold(events: &events)
        }
        let rope = background(row, column) == .rope
        advanceAnimation(lower: direction < 0 ? (rope ? 3 : 0) : (rope ? 11 : 8),
                         upper: direction < 0 ? (rope ? 5 : 2) : (rope ? 13 : 10))
        events.append(.moved)
        return true
    }

    private mutating func changeCell(row newRow: Int, column newColumn: Int) {
        let terrain = background(row, column)
        activeBoard[row: row, column: column] = terrain == .brick ? .empty : terrain
        player.position = Position(column: newColumn, row: newRow)
        activeBoard[row: newRow, column: newColumn] = .playerSprite
    }

    private mutating func advanceAnimation(lower: Int, upper: Int) {
        player.animation += 1
        if player.animation <= lower || player.animation > upper { player.animation = lower }
    }

    private mutating func nudgeColumn(events: inout [PlayerEvent]) {
        if player.xOffset == 2 { return }
        player.xOffset += player.xOffset < 2 ? 1 : -1
        collectGold(events: &events)
    }

    private mutating func nudgeRow(events: inout [PlayerEvent]) {
        if player.yOffset == 2 { return }
        player.yOffset += player.yOffset < 2 ? 1 : -1
        collectGold(events: &events)
    }

    private mutating func collectGold(events: inout [PlayerEvent]) {
        guard player.xOffset == 2, player.yOffset == 2,
              background(row, column) == .gold else { return }
        backgroundBoard[row: row, column: column] = .empty
        goldRemaining = (goldRemaining - 1) & 0xFF
        score += 250
        events.append(.goldCollected(player.position))
    }

    private mutating func dig(_ direction: FacingDirection, continuing: Bool,
                              events: inout [PlayerEvent]) -> Bool {
        if !continuing {
            digDirection = direction
            digAnimation = direction == .left ? 0 : 12
        }
        let targetColumn = column + (direction == .left ? -1 : 1)
        guard row < Board.height - 1, (0..<Board.width).contains(targetColumn),
              active(row + 1, targetColumn) == .brick,
              active(row, targetColumn) == .empty else {
            digDirection = nil
            return false
        }
        nudgeColumn(events: &events)
        nudgeRow(events: &events)
        player.animation = direction == .left
            ? (digAnimation < 6 ? 6 : 0)
            : (digAnimation < 18 ? 14 : 8)
        events.append(.digging(direction, digAnimation))
        if digAnimation == (direction == .left ? 12 : 24) {
            digDirection = nil
            let hole = Position(column: targetColumn, row: row + 1)
            activeBoard[row: hole.row, column: hole.column] = .empty
            if let slot = (0..<30).first(where: { candidate in
                !holes.contains(where: { $0.slot == candidate })
            }) {
                holes.append(DugHole(position: hole, fillTimer: 180, slot: slot))
            }
            events.append(.holeOpened(hole))
        } else {
            digAnimation += 1
        }
        return true
    }
}
