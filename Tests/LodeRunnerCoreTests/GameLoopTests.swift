import Testing
@testable import LodeRunnerCore

struct GameLoopTests {
    private func firstLevel() throws -> GameState {
        try GameState(level: LevelLoader.playState(from: LevelCatalog.bundled().sector(level: 1)))
    }

    @Test func diggingTimerStartsAt179InTheSameGameTick() throws {
        var game = try firstLevel()
        for _ in 0...12 {
            _ = game.advance(input: PlayerInput(primary: .digLeft))
        }
        #expect(game.holes == [DugHole(position: Position(column: 13, row: 15), fillTimer: 179)])
        #expect(game.activeBoard[row: 15, column: 13] == .empty)
        #expect(game.backgroundBoard[row: 15, column: 13] == .brick)
    }

    @Test func exitLaddersAppearWhenLastGoldIsGone() throws {
        var game = try firstLevel()
        let ladders = game.invisibleLadders
        game.goldRemaining = 0
        let result = game.advance()
        #expect(result.worldEvents.filter {
            if case .ladderRevealed = $0 { return true }
            return false
        }.count == ladders.count)
        #expect(game.goldRemaining == 255)
        #expect(game.invisibleLadders.isEmpty)
        for position in ladders {
            #expect(game.activeBoard[row: position.row, column: position.column] == .ladder)
            #expect(game.backgroundBoard[row: position.row, column: position.column] == .ladder)
        }
    }

    @Test func occupiedExitLadderRemainsPending() throws {
        var game = try firstLevel()
        let occupied = try #require(game.invisibleLadders.first)
        game.backgroundBoard[row: occupied.row, column: occupied.column] = .gold
        game.goldRemaining = 0
        _ = game.advance()
        #expect(game.goldRemaining == 0)
        #expect(game.invisibleLadders == [occupied])
        game.backgroundBoard[row: occupied.row, column: occupied.column] = .empty
        _ = game.advance()
        #expect(game.goldRemaining == 255)
        #expect(game.invisibleLadders.isEmpty)
    }

    @Test func levelClearUpdatesLevelLivesAndScore() throws {
        var game = try firstLevel()
        game.activeBoard[row: 14, column: 14] = .empty
        game.activeBoard[row: 0, column: 14] = .playerSprite
        game.backgroundBoard[row: 0, column: 14] = .ladder
        game.player.position = Position(column: 14, row: 0)
        game.goldRemaining = 0
        let result = game.advance()
        #expect(result.worldEvents.contains(.levelCleared(2)))
        #expect(game.levelCompleted)
        #expect(game.level == 2)
        #expect(game.lives == 6)
        #expect(game.score == 1_500)
        #expect(game.advance().worldEvents.isEmpty)
    }

    @Test func levelAfter150ReturnsToFirstDiskLevelWithFasterGuards() throws {
        let catalog = try LevelCatalog.bundled()
        let lastLevel = try LevelLoader.playState(from: catalog.sector(level: 150))
        var game = GameState(level: lastLevel, number: 150)
        let start = game.player.position
        game.activeBoard[row: start.row, column: start.column] = .empty
        game.player.position = Position(column: start.column, row: 0)
        game.activeBoard[row: 0, column: start.column] = .playerSprite
        game.backgroundBoard[row: 0, column: start.column] = .ladder
        game.goldRemaining = 0
        let result = game.advance()
        #expect(result.worldEvents.contains(.levelCleared(151)))
        #expect(game.level == 151)
        let firstAgain = try LevelLoader.playState(
            from: catalog.progressionSector(displayedLevel: game.level))
        let restarted = GameState(level: firstAgain, number: game.level, lives: game.lives)
        #expect(restarted.player.position == Position(column: 14, row: 14))
        #expect(restarted.level == 151)
        #expect(restarted.guardPatternOffset == 1)
        #expect(restarted.lives == game.lives)
    }

    @Test func closingBrickKillsPlayerAtExactTimerExpiry() throws {
        var game = try firstLevel()
        game.activeBoard[row: 14, column: 14] = .empty
        game.activeBoard[row: 15, column: 13] = .playerSprite
        game.player.position = Position(column: 13, row: 15)
        game.holes = [DugHole(position: game.player.position, fillTimer: 1)]
        let result = game.advance()
        #expect(result.worldEvents == [.holeFilled(Position(column: 13, row: 15)), .playerDied])
        #expect(game.activeBoard[row: 15, column: 13] == .brick)
        #expect(!game.alive)
        #expect(game.lives == 4)
        #expect(game.holes.isEmpty)
    }

    @Test func holeWarningsFireAt20And10WithoutChangingLogicalBoard() throws {
        var game = try firstLevel()
        let hole = Position(column: 13, row: 15)
        game.activeBoard[row: hole.row, column: hole.column] = .empty
        game.holes = [DugHole(position: hole, fillTimer: 21)]
        #expect(game.advance().worldEvents == [.holeFillWarning(hole, 20)])
        for _ in 0..<9 { _ = game.advance() }
        #expect(game.advance().worldEvents == [.holeFillWarning(hole, 10)])
        #expect(game.activeBoard[row: hole.row, column: hole.column] == .empty)
        #expect(game.holes[0].fillTimer == 10)
    }

    @Test func closingBrickBuriesGuardAndStartsResurrection() throws {
        var game = try firstLevel()
        let hole = Position(column: 13, row: 15)
        game.activeBoard[row: hole.row, column: hole.column] = .guardSprite
        game.guards[0].position = hole
        game.guards[0].goldTimer = 245
        game.holes = [DugHole(position: hole, fillTimer: 1)]
        let result = game.advance()
        #expect(result.worldEvents.contains(.guardBuried(0)))
        #expect(game.activeBoard[row: hole.row, column: hole.column] == .brick)
        #expect(game.guards[0].resurrectionTimer == 20)
        // MOVE_GUARDS runs after HANDLE_TIMERS in the same game tick.
        #expect(game.guards[0].goldTimer == 126)
        #expect(game.guards[0].position == Position(column: 1, row: 1))
        #expect(game.goldRemaining == 5)
        #expect(game.score == 75)
    }
}
