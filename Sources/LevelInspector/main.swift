import Foundation
import LodeRunnerCore

do {
    let arguments = CommandLine.arguments
    guard arguments.count == 3, arguments[1] == "--level", let level = Int(arguments[2]) else {
        throw InspectorError.usage
    }
    let state = try LevelLoader.playState(from: LevelCatalog.bundled().sector(level: level))
    print("Level \(level)")
    print("Player: (\(state.player.position.column), \(state.player.position.row))")
    print("Guards: \(state.guards.map { "(\($0.position.column), \($0.position.row))" }.joined(separator: ", "))")
    print("Gold: \(state.goldRemaining); invisible ladders: \(state.invisibleLadders.count)")
    for row in state.activeBoard.rowsAsDigits { print(row) }
} catch {
    fputs("\(error)\n", stderr)
    exit(1)
}

private enum InspectorError: Error, CustomStringConvertible {
    case usage
    var description: String { "Usage: LevelInspector --level 1...150" }
}
