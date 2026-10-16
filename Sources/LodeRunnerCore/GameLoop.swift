public enum WorldEvent: Equatable, Sendable {
    case ladderRevealed(Position)
    case holeFillWarning(Position, Int)
    case holeFilled(Position)
    case guardBuried(Int)
    case guardResurrected(Int)
    case playerDied
    case levelCleared(Int)
}

public struct GameTickResult: Equatable, Sendable {
    public let playerEvents: [PlayerEvent]
    public let worldEvents: [WorldEvent]
    public var guardEvents: [GuardEvent] = []
}

extension GameState {
    /// Main loop through MOVE_GUARDS. Pixel overlap collision remains a renderer boundary.
    public mutating func advance(input: PlayerInput = .init()) -> GameTickResult {
        guard alive, !levelCompleted else {
            return GameTickResult(playerEvents: [], worldEvents: [])
        }
        let playerEvents = step(input: input)
        var worldEvents: [WorldEvent] = []
        if shouldCheckPlayerSpriteCollision(playerEvents), playerSpriteTouchesGuard() {
            alive = false
        }
        if !alive {
            finishDeath(events: &worldEvents)
            return GameTickResult(playerEvents: playerEvents, worldEvents: worldEvents)
        }
        if goldRemaining == 0 { revealExitLadders(events: &worldEvents) }
        if player.position.row == 0, player.yOffset == 2,
           goldRemaining == 0 || goldRemaining == 255 {
            levelCompleted = true
            level += 1
            lives = min(lives + 1, 255)
            score += 1_500
            worldEvents.append(.levelCleared(level))
            return GameTickResult(playerEvents: playerEvents, worldEvents: worldEvents)
        }
        handleHoleTimers(events: &worldEvents)
        if !alive { finishDeath(events: &worldEvents) }
        if !alive { return GameTickResult(playerEvents: playerEvents, worldEvents: worldEvents) }
        let guardEvents = moveGuards()
        if !alive { finishDeath(events: &worldEvents) }
        return GameTickResult(playerEvents: playerEvents, worldEvents: worldEvents,
                              guardEvents: guardEvents)
    }

    private mutating func finishDeath(events: inout [WorldEvent]) {
        lives = (lives - 1) & 0xFF
        events.append(.playerDied)
    }

    private func shouldCheckPlayerSpriteCollision(_ playerEvents: [PlayerEvent]) -> Bool {
        let drewPlayer = playerEvents.contains { event in
            switch event {
            case .moved, .falling, .digging: return true
            default: return false
            }
        }
        let collectedGold = playerEvents.contains { event in
            if case .goldCollected = event { return true }
            return false
        }
        return drewPlayer && !collectedGold
    }

    private func playerSpriteTouchesGuard() -> Bool {
        let atlas = GameSpriteData.atlas
        let playerPosition = SpriteAtlas.screenPosition(player.position,
                                                        xOffset: player.xOffset,
                                                        yOffset: player.yOffset)
        let playerSprite = SpriteAtlas.playerSprite(animation: player.animation)
        return guards.contains { guardState in
            guard guardState.resurrectionTimer == 0 else { return false }
            let guardPosition = SpriteAtlas.screenPosition(guardState.position,
                                                           xOffset: guardState.xOffset,
                                                           yOffset: guardState.yOffset)
            return atlas.overlaps(sprite: playerSprite, at: playerPosition,
                                  sprite: SpriteAtlas.guardSprite(animation: guardState.animation),
                                  at: guardPosition)
        }
    }

    private mutating func revealExitLadders(events: inout [WorldEvent]) {
        var pending: [Position] = []
        // Original table entries are 1-based and examined from last to first.
        for position in invisibleLadders.reversed() {
            let row = position.row, column = position.column
            if backgroundBoard[row: row, column: column] != .empty {
                pending.append(position)
                continue
            }
            backgroundBoard[row: row, column: column] = .ladder
            if activeBoard[row: row, column: column] == .empty {
                activeBoard[row: row, column: column] = .ladder
            }
            events.append(.ladderRevealed(position))
        }
        invisibleLadders = pending.reversed()
        if pending.isEmpty { goldRemaining = 255 }
    }

    private mutating func handleHoleTimers(events: inout [WorldEvent]) {
        resurrectGuards(events: &events)
        guardResurrectColumn = (guardResurrectColumn + 1) % Board.width
        guard !holes.isEmpty else { return }
        // BRICK_FILL_TIMERS is traversed from slot 30 down to 0.
        for index in holes.indices.sorted(by: { holes[$0].slot > holes[$1].slot }) {
            holes[index].fillTimer -= 1
            let position = holes[index].position
            let timer = holes[index].fillTimer
            if timer == 20 || timer == 10 {
                events.append(.holeFillWarning(position, timer))
            }
            if timer != 0 { continue }
            let row = position.row, column = position.column
            let occupant = activeBoard[row: row, column: column]
            if occupant == .playerSprite { alive = false }
            if occupant == .gold { goldRemaining = (goldRemaining - 1) & 0xFF }
            if occupant == .guardSprite { buryGuard(at: position, events: &events) }
            activeBoard[row: row, column: column] = .brick
            events.append(.holeFilled(position))
        }
        holes.removeAll { $0.fillTimer == 0 }
    }

    private mutating func buryGuard(at position: Position, events: inout [WorldEvent]) {
        guard let index = guards.firstIndex(where: { $0.position == position && $0.resurrectionTimer == 0 }) else {
            return
        }
        if guards[index].goldTimer >= 128 { goldRemaining = (goldRemaining - 1) & 0xFF }
        guards[index].goldTimer = 127
        guards[index].resurrectionTimer = 20
        guards[index].xOffset = 2
        guards[index].yOffset = 2
        guards[index].animation = 0
        score += 75

        // The original searches empty background cells from row 1, starting at
        // GUARD_RESURRECT_COL, and records the destination before the timer expires.
        for row in 1..<Board.height {
            let columns = row == 1 ? guardResurrectColumn..<Board.width : 0..<Board.width
            if let column = columns.first(where: { backgroundBoard[row: row, column: $0] == .empty }) {
                guards[index].position = Position(column: column, row: row)
                guardResurrectColumn = column
                break
            }
        }
        events.append(.guardBuried(index))
    }
}

private enum GameSpriteData {
    static let atlas = try! SpriteAtlas.bundled()
}
