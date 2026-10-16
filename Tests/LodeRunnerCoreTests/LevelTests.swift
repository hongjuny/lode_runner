import Foundation
import Testing
@testable import LodeRunnerCore

struct LevelTests {
    @Test func allOriginalSectorsRoundTrip() throws {
        let catalog = try LevelCatalog.bundled()
        let manifestURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("fixtures/reference_levels.json")
        let manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        let references = try #require(manifest["levels"] as? [[String: Any]])
        #expect(references.count == 150)
        for level in 1...150 {
            let sector = try catalog.sector(level: level)
            #expect(sector.replacingBoard(sector.board).bytes == sector.bytes, "level \(level)")
            let state = try LevelLoader.playState(from: sector)
            let reference = references[level - 1]
            let players = try #require(reference["player"] as? [[Int]])
            let guards = try #require(reference["guards"] as? [[Int]])
            #expect(players.count == 1, "level \(level)")
            #expect(state.player.position == Position(column: players[0][1], row: players[0][0]), "level \(level)")
            #expect(state.guards.map(\.position) == guards.reversed().prefix(5).map {
                Position(column: $0[1], row: $0[0])
            }, "level \(level)")
            for excess in guards.reversed().dropFirst(5) {
                #expect(state.activeBoard[row: excess[0], column: excess[1]] == .empty, "level \(level)")
                #expect(state.backgroundBoard[row: excess[0], column: excess[1]] == .empty, "level \(level)")
            }
            #expect(state.goldRemaining == reference["gold"] as? Int, "level \(level)")
        }
    }

    @Test func firstLevelMatchesCaptured6502State() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("fixtures/runtime/level1_start.json")
        let fixture = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [String: Any])
        let state = try LevelLoader.playState(from: LevelCatalog.bundled().sector(level: 1))

        #expect(state.activeBoard.rowsAsDigits == fixture["active_board"] as? [String])
        #expect(state.backgroundBoard.rowsAsDigits == fixture["background_board"] as? [String])
        #expect(state.goldRemaining == fixture["gold_remaining"] as? Int)
        #expect(state.invisibleLadders.count == fixture["ladder_count"] as? Int)
        let player = try #require(fixture["player"] as? [String: Int])
        #expect(state.player.position == Position(column: player["column"]!, row: player["row"]!))
        #expect(state.player.xOffset == player["x_offset"])
        #expect(state.player.yOffset == player["y_offset"])
        #expect(state.player.animation == player["animation"])
        let guards = try #require(fixture["guards"] as? [[String: Int]])
        #expect(state.guards.count == guards.count)
        for (guardState, expected) in zip(state.guards, guards) {
            #expect(guardState.position == Position(column: expected["column"]!, row: expected["row"]!))
            #expect(guardState.xOffset == expected["x_offset"])
            #expect(guardState.yOffset == expected["y_offset"])
            #expect(guardState.goldTimer == expected["gold_timer"])
            #expect(guardState.resurrectionTimer == expected["resurrection_timer"])
        }
    }

    @Test func loaderAppliesOriginalLimitsInReverseScanOrder() throws {
        var board = try Board(cells: Array(repeating: .empty, count: Board.cellCount))
        board[row: 0, column: 0] = .trap
        board[row: 0, column: 1] = .playerSprite
        board[row: 15, column: 27] = .playerSprite
        for column in 0..<6 { board[row: 14, column: column] = .guardSprite }
        for row in 1...2 {
            for column in 0..<28 { board[row: row, column: column] = .invisibleLadder }
        }
        let sector = try LevelSector(bytes: Array(repeating: 0xA5, count: 256)).replacingBoard(board)
        let state = try LevelLoader.playState(from: sector)

        #expect(Array(sector.bytes[224...]) == Array(repeating: 0xA5, count: 32))
        #expect(state.player.position == Position(column: 27, row: 15))
        #expect(state.activeBoard[row: 0, column: 1] == .empty)
        #expect(state.activeBoard[row: 0, column: 0] == .trap)
        #expect(state.guards.map(\.position) == (1...5).reversed().map { Position(column: $0, row: 14) })
        #expect(state.activeBoard[row: 14, column: 0] == .empty)
        #expect(state.backgroundBoard[row: 14, column: 5] == .empty)
        #expect(state.invisibleLadders.count == 45)
        #expect(state.invisibleLadders.first == Position(column: 27, row: 2))
        #expect(state.activeBoard[row: 1, column: 0] == .empty)
    }
}
