import Foundation
import Testing
@testable import LodeRunnerCore

struct PlayerEngineTests {
    private func firstLevel() throws -> GameState {
        try GameState(level: LevelLoader.playState(from: LevelCatalog.bundled().sector(level: 1)))
    }

    private func runtimeFixture(_ name: String) throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("fixtures/runtime/\(name).json")
        return try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    @Test func oneLeftMoveMatches6502Capture() throws {
        var game = try firstLevel()
        let events = game.step(input: PlayerInput(horizontal: .left))
        let fixture = try runtimeFixture("level1_left_once")
        let player = try #require(fixture["player"] as? [String: Int])
        #expect(game.player.position == Position(column: player["column"]!, row: player["row"]!))
        #expect(game.player.xOffset == player["x_offset"])
        #expect(game.player.yOffset == player["y_offset"])
        #expect(game.player.animation == player["animation"])
        #expect(game.player.facing == .left)
        #expect(game.activeBoard.rowsAsDigits == fixture["active_board"] as? [String])
        #expect(game.backgroundBoard.rowsAsDigits == fixture["background_board"] as? [String])
        #expect(events == [.moved])
    }

    @Test func rightMovementCollectsGoldAtExactAlignment() throws {
        var game = try firstLevel()
        _ = game.step(input: PlayerInput(horizontal: .left))
        var collected: [PlayerEvent] = []
        for _ in 0..<20 {
            let events = game.step(input: PlayerInput(horizontal: .right))
            if events.contains(.goldCollected(Position(column: 17, row: 14))) {
                collected = events
                break
            }
        }
        let fixture = try runtimeFixture("level1_gold_pickup")
        let player = try #require(fixture["player"] as? [String: Int])
        #expect(collected.contains(.goldCollected(Position(column: 17, row: 14))))
        #expect(game.player.position == Position(column: player["column"]!, row: player["row"]!))
        #expect(game.player.xOffset == player["x_offset"])
        #expect(game.player.yOffset == player["y_offset"])
        #expect(game.goldRemaining == fixture["gold_remaining"] as? Int)
        #expect(game.score == 250)
        #expect(game.activeBoard[row: 14, column: 17] == .playerSprite)
        #expect(game.backgroundBoard[row: 14, column: 17] == .empty)
    }

    @Test func digThenFallUsesOriginalPriorityAndOffsets() throws {
        var game = try firstLevel()
        for index in 0...12 {
            let events = game.step(input: PlayerInput(primary: .digLeft, horizontal: .right))
            #expect(events.contains(.digging(.left, index)))
            if index < 12 { #expect(game.activeBoard[row: 15, column: 13] == .brick) }
        }
        let fixture = try runtimeFixture("level1_hole_open")
        #expect(game.player.position == Position(column: 14, row: 14))
        #expect(game.player.animation == 0)
        #expect(game.activeBoard[row: 15, column: 13] == .empty)
        #expect(game.backgroundBoard[row: 15, column: 13] == .brick)
        #expect(game.holes == [DugHole(position: Position(column: 13, row: 15), fillTimer: 180)])
        let capturedBoard = try #require(fixture["active_board"] as? [String])
        #expect(game.activeBoard.rowsAsDigits[14] == capturedBoard[14])
        #expect(game.activeBoard.rowsAsDigits[15] == capturedBoard[15])

        // The original capture occurs five surrounding game loops later. Timers and guards
        // are outside this player-only unit, so compare the player's state and board cells.
        for _ in 0..<12 {
            if game.player.position == Position(column: 13, row: 15) { break }
            _ = game.step(input: PlayerInput(horizontal: .left))
        }
        let fallen = try runtimeFixture("level1_fall_into_hole")
        let player = try #require(fallen["player"] as? [String: Int])
        #expect(game.player.position == Position(column: player["column"]!, row: player["row"]!))
        #expect(game.player.xOffset == player["x_offset"])
        #expect(game.player.yOffset == player["y_offset"])
        #expect(game.player.animation == player["animation"])
        #expect(game.activeBoard[row: 15, column: 13] == .playerSprite)
        #expect(game.backgroundBoard[row: 15, column: 13] == .brick)
    }

    @Test func ladderAndBlockedMovement() throws {
        var game = try firstLevel()
        let start = game.player
        #expect(game.step(input: PlayerInput(primary: .down)).isEmpty)
        #expect(game.player == start)
        // On a ladder, up is permitted and movement preserves column alignment.
        game.player.position = Position(column: 4, row: 14)
        game.activeBoard[row: 14, column: 14] = .empty
        game.activeBoard[row: 14, column: 4] = .playerSprite
        game.backgroundBoard[row: 14, column: 4] = .ladder
        #expect(game.step(input: PlayerInput(primary: .up)).contains(.moved))
        #expect(game.player.yOffset == 1)
        #expect(game.player.animation == 16)
    }

    @Test func blockedPrimaryFallsBackToHorizontalAndRopeChangesAnimation() throws {
        var game = try firstLevel()
        // At level start there is no ladder above, so I fails and J runs.
        #expect(game.step(input: PlayerInput(primary: .up, horizontal: .left)) == [.moved])
        #expect(game.player.xOffset == 1)
        #expect(game.player.facing == .left)

        game = try firstLevel()
        game.backgroundBoard[row: 14, column: 14] = .rope
        #expect(game.step(input: PlayerInput(horizontal: .right)) == [.moved])
        #expect(game.player.xOffset == 3)
        #expect(game.player.animation == 11)
    }

    @Test func fallingPreemptsInput() throws {
        var game = try firstLevel()
        game.activeBoard[row: 15, column: 14] = .empty
        let events = game.step(input: PlayerInput(horizontal: .left))
        #expect(events == [.falling])
        #expect(game.player.position == Position(column: 14, row: 14))
        #expect(game.player.xOffset == 2)
        #expect(game.player.yOffset == 3)
        #expect(game.player.animation == 15)
    }
}
