import Foundation
import Testing
@testable import LodeRunnerCore

struct GuardEngineTests {
    private func firstLevel() throws -> GameState {
        try GameState(level: LevelLoader.playState(from: LevelCatalog.bundled().sector(level: 1)))
    }

    private func runtimeFixture(_ name: String) throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("fixtures/runtime/\(name).json")
        return try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    @Test func firstTickMatchesCapturedGuardState() throws {
        var game = try firstLevel()
        let result = game.advance(input: PlayerInput(horizontal: .left))
        let fixture = try runtimeFixture("level1_left_once")
        let guards = try #require(fixture["guards"] as? [[String: Int]])
        #expect(game.guardPhase == fixture["guard_phase"] as? Int)
        #expect(result.guardEvents.contains(.moved(0)))
        for (actual, expected) in zip(game.guards, guards) {
            #expect(actual.position == Position(column: expected["column"]!, row: expected["row"]!))
            #expect(actual.xOffset == expected["x_offset"])
            #expect(actual.yOffset == expected["y_offset"])
            #expect(actual.goldTimer == expected["gold_timer"])
            #expect(actual.resurrectionTimer == expected["resurrection_timer"])
        }
        let capturedActive = try #require(fixture["active_board"] as? [String])
        #expect(game.activeBoard.rowsAsDigits == capturedActive)
        #expect(game.backgroundBoard.rowsAsDigits == fixture["background_board"] as? [String])
    }

    @Test func guardsMatchHoleOpeningCaptureAfterThirteenTicks() throws {
        var game = try firstLevel()
        for _ in 0...12 { _ = game.advance(input: PlayerInput(primary: .digLeft)) }
        let fixture = try runtimeFixture("level1_hole_open")
        let guards = try #require(fixture["guards"] as? [[String: Int]])
        #expect(game.guardPhase == fixture["guard_phase"] as? Int)
        for (actual, expected) in zip(game.guards, guards) {
            #expect(actual.position == Position(column: expected["column"]!, row: expected["row"]!))
            #expect(actual.xOffset == expected["x_offset"])
            #expect(actual.yOffset == expected["y_offset"])
            #expect(actual.goldTimer == expected["gold_timer"])
        }
        let capturedActive = try #require(fixture["active_board"] as? [String])
        #expect(game.activeBoard.rowsAsDigits == capturedActive)
        #expect(game.backgroundBoard.rowsAsDigits == fixture["background_board"] as? [String])
    }

    @Test func fallCaptureMatchesAtOriginalMidMoveBreakPoint() throws {
        var game = try firstLevel()
        for _ in 0...12 { _ = game.advance(input: PlayerInput(primary: .digLeft)) }
        for _ in 0..<5 { _ = game.advance(input: PlayerInput(horizontal: .left)) }
        // $656F is inside MOVE_PLAYER. This final player call has not run
        // HANDLE_TIMERS or MOVE_GUARDS yet in the captured state.
        _ = game.step(input: PlayerInput(horizontal: .left))
        let fixture = try runtimeFixture("level1_fall_into_hole")
        let player = try #require(fixture["player"] as? [String: Int])
        let guards = try #require(fixture["guards"] as? [[String: Int]])
        #expect(game.player.position == Position(column: player["column"]!, row: player["row"]!))
        #expect(game.player.xOffset == player["x_offset"])
        #expect(game.player.yOffset == player["y_offset"])
        #expect(game.player.animation == player["animation"])
        #expect(game.holes[0].fillTimer == 174)
        #expect(game.guardPhase == fixture["guard_phase"] as? Int)
        for (actual, expected) in zip(game.guards, guards) {
            #expect(actual.position == Position(column: expected["column"]!, row: expected["row"]!))
            #expect(actual.xOffset == expected["x_offset"])
            #expect(actual.yOffset == expected["y_offset"])
            #expect(actual.goldTimer == expected["gold_timer"])
        }
        let capturedActive = try #require(fixture["active_board"] as? [String])
        #expect(Array(game.activeBoard.rowsAsDigits.dropLast()) == Array(capturedActive.dropLast()))
        // $656F stops between updating PLAYER_ROW and writing the new active
        // sprite. A complete Swift player step has already written that sprite.
        #expect(game.activeBoard[row: 15, column: 13] == .playerSprite)
        #expect(Array(capturedActive[15])[13] == "0")
        #expect(game.backgroundBoard.rowsAsDigits == fixture["background_board"] as? [String])
    }

    @Test func phasePatternRotatesSelectedGuards() throws {
        var game = try firstLevel()
        let first = game.advance()
        let second = game.advance()
        let third = game.advance()
        #expect(first.guardEvents.contains(.moved(0)))
        #expect(second.guardEvents.contains(.moved(1)))
        #expect(second.guardEvents.contains(.moved(2)))
        #expect(third.guardEvents.contains(.moved(0)))
        #expect(game.guardPhase == 2)
    }

    @Test func trappedGuardClimbsOutInsteadOfFallingBackIntoHole() throws {
        var game = try firstLevel()
        let old = game.guards[0].position
        game.activeBoard[row: old.row, column: old.column] =
            game.backgroundBoard[row: old.row, column: old.column]
        let hole = Position(column: 5, row: 5)
        game.backgroundBoard[row: hole.row, column: hole.column] = .brick
        game.activeBoard[row: hole.row, column: hole.column] = .guardSprite
        game.backgroundBoard[row: hole.row - 1, column: hole.column] = .empty
        game.activeBoard[row: hole.row - 1, column: hole.column] = .empty
        game.guards[0].position = hole
        game.guards[0].yOffset = 1
        game.guards[0].goldTimer = 7
        game.guardNumber = game.guards.count

        _ = game.moveGuards()
        #expect(game.guards[0].position == hole)
        #expect(game.guards[0].yOffset == 0)
        #expect(game.guards[0].goldTimer == 6)

        game.guardNumber = game.guards.count
        _ = game.moveGuards()
        #expect(game.guards[0].position == Position(column: hole.column, row: hole.row - 1))
        #expect(game.guards[0].yOffset == 4)
        #expect(game.guards[0].goldTimer == 5)
    }

    @Test func freeGuardStillFallsIntoOpenSpace() throws {
        var game = try firstLevel()
        let old = game.guards[0].position
        game.activeBoard[row: old.row, column: old.column] =
            game.backgroundBoard[row: old.row, column: old.column]
        let place = Position(column: 5, row: 5)
        game.backgroundBoard[row: place.row, column: place.column] = .empty
        game.activeBoard[row: place.row, column: place.column] = .guardSprite
        game.backgroundBoard[row: place.row + 1, column: place.column] = .empty
        game.activeBoard[row: place.row + 1, column: place.column] = .empty
        game.guards[0].position = place
        game.guards[0].yOffset = 2
        game.guards[0].goldTimer = 0
        game.guardNumber = game.guards.count

        _ = game.moveGuards()
        #expect(game.guards[0].position == place)
        #expect(game.guards[0].yOffset == 3)
    }

    @Test func resurrectionWaitsForEmptyActiveCell() throws {
        var game = try firstLevel()
        let place = Position(column: 1, row: 1)
        game.guards[0].position = place
        game.guards[0].resurrectionTimer = 1
        game.guards[0].goldTimer = 127
        game.activeBoard[row: place.row, column: place.column] = .brick
        let blocked = game.advance()
        #expect(!blocked.worldEvents.contains(.guardResurrected(0)))
        #expect(game.guards[0].resurrectionTimer == 1)
        game.activeBoard[row: place.row, column: place.column] = .empty
        let unblocked = game.advance()
        #expect(unblocked.worldEvents.contains(.guardResurrected(0)))
        #expect(game.guards[0].resurrectionTimer == 0)
        #expect(game.activeBoard[row: place.row, column: place.column] == .guardSprite)
    }

    @Test func carriedGoldDropsWhenTimerWrapsAtCellBoundary() throws {
        var game = try firstLevel()
        game.guards[0].xOffset = 0
        game.guards[0].goldTimer = 255
        let original = game.guards[0].position
        let events = game.moveGuards()
        #expect(events.contains(.goldDropped(0, original)))
        #expect(game.guards[0].position == Position(column: original.column - 1, row: original.row))
        #expect(game.guards[0].goldTimer == 0)
        #expect(game.backgroundBoard[row: original.row, column: original.column] == .gold)
        #expect(game.activeBoard[row: original.row, column: original.column] == .gold)
    }
}
