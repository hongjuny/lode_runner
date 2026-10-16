public enum GuardEvent: Equatable, Sendable {
    case moved(Int)
    case goldTaken(Int, Position)
    case goldDropped(Int, Position)
}

private enum GuardAction { case none, left, right, up, down }

extension GameState {
    /// MOVE_GUARDS: the pattern bits select how many guards to visit this phase.
    mutating func moveGuards() -> [GuardEvent] {
        guard !guards.isEmpty else { return [] }
        let patterns: [[Int]] = [
            [0, 0, 0], [0, 1, 1], [1, 1, 1], [1, 3, 1],
            [1, 3, 3], [3, 3, 3], [3, 3, 7], [3, 7, 7],
            [7, 7, 7], [7, 7, 15], [7, 15, 15], [15, 15, 15],
        ]
        guardPhase = (guardPhase + 1) % 3
        let patternIndex = min(guards.count + guardPatternOffset, patterns.count - 1)
        var bits = patterns[patternIndex][guardPhase]
        var events: [GuardEvent] = []
        while bits != 0 {
            if bits & 1 != 0 {
                guardNumber = guardNumber % guards.count + 1
                moveGuard(at: guardNumber - 1, events: &events)
                if !alive { break }
            }
            bits >>= 1
        }
        return events
    }

    /// GUARD_RESURRECTIONS runs before hole timers, in descending guard order.
    mutating func resurrectGuards(events: inout [WorldEvent]) {
        for index in guards.indices.reversed() where guards[index].resurrectionTimer > 0 {
            guards[index].goldTimer = 127
            guards[index].resurrectionTimer -= 1
            if guards[index].resurrectionTimer != 0 { continue }
            let place = guards[index].position
            if activeBoard[row: place.row, column: place.column] == .empty {
                activeBoard[row: place.row, column: place.column] = .guardSprite
                guards[index].goldTimer = 0
                events.append(.guardResurrected(index))
            } else {
                guards[index].resurrectionTimer = 1
            }
        }
    }

    private mutating func moveGuard(at index: Int, events: inout [GuardEvent]) {
        let timer = guards[index].goldTimer
        if timer > 0 && timer < 128 {
            guards[index].goldTimer -= 1
            let remaining = guards[index].goldTimer
            if remaining >= 13 { return }
            if remaining >= 7 {
                let offsets = [2, 1, 2, 3, 2, 1]
                guards[index].xOffset = offsets[remaining - 7]
                return
            }
        }
        if guardShouldFall(index) {
            fallGuard(index, events: &events)
            return
        }
        switch determineGuardAction(index) {
        case .none:
            if guards[index].goldTimer > 0 && guards[index].goldTimer < 128 {
                guards[index].goldTimer = (guards[index].goldTimer + 1) & 0xFF
            }
        case .left: moveGuardHorizontal(index, -1, events: &events)
        case .right: moveGuardHorizontal(index, 1, events: &events)
        case .up: moveGuardVertical(index, -1, events: &events)
        case .down: moveGuardVertical(index, 1, events: &events)
        }
    }

    private func guardShouldFall(_ index: Int) -> Bool {
        let guardState = guards[index]
        let row = guardState.position.row, column = guardState.position.column
        let here = backgroundBoard[row: row, column: column]
        if here == .ladder || (here == .rope && guardState.yOffset == 2) { return false }
        if guardState.yOffset < 2 { return true }
        if row == Board.height - 1 { return false }
        let below = activeBoard[row: row + 1, column: column]
        if below == .empty || below == .playerSprite { return true }
        if below == .guardSprite { return false }
        let terrain = backgroundBoard[row: row + 1, column: column]
        return terrain != .brick && terrain != .stone && terrain != .ladder
    }

    private mutating func fallGuard(_ index: Int, events: inout [GuardEvent]) {
        let original = guards[index]
        nudgeGuardColumn(index, events: &events)
        guards[index].animation = guards[index].facing == .left ? 6 : 13
        guards[index].yOffset += 1
        if guards[index].yOffset > 4 {
            guards[index].yOffset = 0
            crossGuardCell(index, row: original.position.row + 1,
                           column: original.position.column, events: &events)
        } else if guards[index].yOffset == 2 {
            takeGuardGold(index, events: &events)
            let place = guards[index].position
            if backgroundBoard[row: place.row, column: place.column] == .brick {
                if guards[index].goldTimer >= 128 { goldRemaining = (goldRemaining - 1) & 0xFF }
                guards[index].goldTimer = guardGoldTimerStart
                score += 75
            }
        }
        events.append(.moved(index))
    }

    private mutating func moveGuardHorizontal(_ index: Int, _ direction: Int,
                                              events: inout [GuardEvent]) {
        let place = guards[index].position
        if direction < 0 {
            if guards[index].xOffset <= 2 {
                if place.column == 0 { return }
                let tile = activeBoard[row: place.row, column: place.column - 1]
                if tile == .guardSprite || tile == .stone || tile == .brick ||
                    backgroundBoard[row: place.row, column: place.column - 1] == .trap { return }
            }
            guards[index].facing = .left
        } else {
            if guards[index].xOffset >= 2 {
                if place.column == Board.width - 1 { return }
                let tile = activeBoard[row: place.row, column: place.column + 1]
                if tile == .guardSprite || tile == .stone || tile == .brick ||
                    backgroundBoard[row: place.row, column: place.column + 1] == .trap { return }
            }
            guards[index].facing = .right
        }
        nudgeGuardRow(index, events: &events)
        guards[index].xOffset += direction
        if guards[index].xOffset < 0 || guards[index].xOffset > 4 {
            guards[index].xOffset = direction < 0 ? 4 : 0
            crossGuardCell(index, row: place.row, column: place.column + direction,
                           events: &events)
        } else {
            takeGuardGold(index, events: &events)
        }
        let newPlace = guards[index].position
        let rope = backgroundBoard[row: newPlace.row, column: newPlace.column] == .rope
        advanceGuardAnimation(index, lower: direction < 0 ? (rope ? 3 : 0) : (rope ? 10 : 7),
                              upper: direction < 0 ? (rope ? 5 : 2) : (rope ? 12 : 9))
        events.append(.moved(index))
    }

    private mutating func moveGuardVertical(_ index: Int, _ direction: Int,
                                            events: inout [GuardEvent]) {
        let place = guards[index].position
        if direction < 0 {
            if guards[index].yOffset <= 2 {
                if place.row == 0 { return }
                let above = activeBoard[row: place.row - 1, column: place.column]
                if above == .brick || above == .stone || above == .trap || above == .guardSprite { return }
            }
        } else if guards[index].yOffset >= 2 {
            if place.row == Board.height - 1 { return }
            let below = activeBoard[row: place.row + 1, column: place.column]
            if below == .brick || below == .stone || below == .guardSprite { return }
        }
        nudgeGuardColumn(index, events: &events)
        guards[index].yOffset += direction
        if guards[index].yOffset < 0 || guards[index].yOffset > 4 {
            guards[index].yOffset = direction < 0 ? 4 : 0
            crossGuardCell(index, row: place.row + direction, column: place.column,
                           events: &events)
        } else {
            takeGuardGold(index, events: &events)
        }
        advanceGuardAnimation(index, lower: 14, upper: 15)
        events.append(.moved(index))
    }

    private mutating func crossGuardCell(_ index: Int, row: Int, column: Int,
                                         events: inout [GuardEvent]) {
        let old = guards[index].position
        dropGuardGold(index, events: &events)
        let oldTerrain = backgroundBoard[row: old.row, column: old.column]
        activeBoard[row: old.row, column: old.column] = oldTerrain == .brick ? .empty : oldTerrain
        if activeBoard[row: row, column: column] == .playerSprite { alive = false }
        guards[index].position = Position(column: column, row: row)
        activeBoard[row: row, column: column] = .guardSprite

        // A guard carrying gold loses it when it enters a brick cell while falling.
        if backgroundBoard[row: row, column: column] == .brick,
           guards[index].goldTimer >= 128 {
            let aboveRow = row - 1
            if aboveRow >= 0,
               backgroundBoard[row: aboveRow, column: column] == .empty {
                backgroundBoard[row: aboveRow, column: column] = .gold
                activeBoard[row: aboveRow, column: column] = .gold
                events.append(.goldDropped(index, Position(column: column, row: aboveRow)))
            } else {
                goldRemaining = (goldRemaining - 1) & 0xFF
            }
            guards[index].goldTimer = 0
        }
    }

    private mutating func nudgeGuardColumn(_ index: Int, events: inout [GuardEvent]) {
        if guards[index].xOffset == 2 { return }
        guards[index].xOffset += guards[index].xOffset < 2 ? 1 : -1
        takeGuardGold(index, events: &events)
    }

    private mutating func nudgeGuardRow(_ index: Int, events: inout [GuardEvent]) {
        if guards[index].yOffset == 2 { return }
        guards[index].yOffset += guards[index].yOffset < 2 ? 1 : -1
        takeGuardGold(index, events: &events)
    }

    private mutating func takeGuardGold(_ index: Int, events: inout [GuardEvent]) {
        let guardState = guards[index]
        let place = guardState.position
        guard guardState.xOffset == 2, guardState.yOffset == 2,
              guardState.goldTimer < 128,
              backgroundBoard[row: place.row, column: place.column] == .gold else { return }
        // $53 is GUARD_RESURRECT_COL here, reused as a variable pickup delay.
        guards[index].goldTimer = 255 - guardResurrectColumn
        backgroundBoard[row: place.row, column: place.column] = .empty
        events.append(.goldTaken(index, place))
    }

    private mutating func dropGuardGold(_ index: Int, events: inout [GuardEvent]) {
        guard guards[index].goldTimer >= 128 else { return }
        guards[index].goldTimer = (guards[index].goldTimer + 1) & 0xFF
        guard guards[index].goldTimer == 0 else { return }
        let place = guards[index].position
        if backgroundBoard[row: place.row, column: place.column] == .empty {
            backgroundBoard[row: place.row, column: place.column] = .gold
            events.append(.goldDropped(index, place))
        } else {
            guards[index].goldTimer = 255
        }
    }

    private mutating func advanceGuardAnimation(_ index: Int, lower: Int, upper: Int) {
        guards[index].animation += 1
        if guards[index].animation <= lower || guards[index].animation > upper {
            guards[index].animation = lower
        }
    }

    private var guardGoldTimerStart: Int {
        let values = [0x26, 0x26, 0x2E, 0x44, 0x47, 0x49, 0x4A, 0x4B, 0x4C, 0x4D, 0x4E, 0x4F, 0x50]
        return values[min(guardPatternOffset, values.count - 1)]
    }

    private func determineGuardAction(_ index: Int) -> GuardAction {
        let place = guards[index].position
        let row = place.row, column = place.column
        if backgroundBoard[row: row, column: column] == .brick,
           guards[index].goldTimer > 0, guards[index].goldTimer < 128 { return .up }

        // On the player's row, the original checks whether there is support
        // beneath every intervening cell before taking the direct route.
        if row == player.position.row, column != player.position.column {
            let direction = column < player.position.column ? 1 : -1
            var scan = column + direction
            var direct = true
            while true {
                let here = backgroundBoard[row: row, column: scan]
                if here != .ladder && here != .rope && row < Board.height - 1 {
                    let below = backgroundBoard[row: row + 1, column: scan]
                    if below == .empty || below == .trap { direct = false; break }
                }
                if scan == player.position.column { break }
                scan += direction
            }
            if direct { return direction < 0 ? .left : .right }
        }

        var best = 255
        var action: GuardAction = .none
        func consider(_ candidateRow: Int, _ candidateColumn: Int, _ candidateAction: GuardAction) {
            let distance = pseudoDistance(row: candidateRow, column: candidateColumn, guardColumn: column)
            if distance < best { best = distance; action = candidateAction }
        }
        if row < Board.height - 1 {
            let below = backgroundBoard[row: row + 1, column: column]
            if below != .brick && below != .stone {
                consider(candidateBelow(row: row, column: column), column, .down)
            }
        }
        if row > 0 && backgroundBoard[row: row, column: column] == .ladder {
            consider(candidateAbove(row: row, column: column), column, .up)
        }
        let limits = guardHorizontalLimits(row: row, column: column)
        if limits.left < column {
            for candidateColumn in limits.left..<column {
                considerHorizontal(row: row, column: candidateColumn, action: .left, consider: consider)
            }
        }
        if limits.right > column {
            for candidateColumn in (column + 1...limits.right).reversed() {
                considerHorizontal(row: row, column: candidateColumn, action: .right, consider: consider)
            }
        }
        return action
    }

    private func considerHorizontal(row: Int, column: Int, action: GuardAction,
                                    consider: (Int, Int, GuardAction) -> Void) {
        if row < Board.height - 1 {
            let below = backgroundBoard[row: row + 1, column: column]
            if below != .brick && below != .stone {
                consider(candidateBelow(row: row, column: column), column, action)
            }
        }
        if row > 0 && backgroundBoard[row: row, column: column] == .ladder {
            consider(candidateAbove(row: row, column: column), column, action)
        }
    }

    private func pseudoDistance(row: Int, column: Int, guardColumn: Int) -> Int {
        if row == player.position.row { return abs(column - guardColumn) }
        return row > player.position.row ? 200 + row - player.position.row
                                         : 100 + player.position.row - row
    }

    private func guardHorizontalLimits(row: Int, column: Int) -> (left: Int, right: Int) {
        var left = column
        while left > 0 {
            let next = left - 1
            let tile = activeBoard[row: row, column: next]
            if tile == .brick || tile == .stone { break }
            left = next
            if tile == .ladder || tile == .rope || row == Board.height - 1 { continue }
            let below = backgroundBoard[row: row + 1, column: next]
            if below != .brick && below != .stone && below != .ladder { break }
        }
        var right = column
        while right < Board.width - 1 {
            let next = right + 1
            let tile = activeBoard[row: row, column: next]
            if tile == .brick || tile == .stone { break }
            right = next
            if tile == .ladder || tile == .rope || row == Board.height - 1 { continue }
            let below = backgroundBoard[row: row + 1, column: next]
            if below != .brick && below != .stone && below != .ladder { break }
        }
        return (left, right)
    }

    private func candidateBelow(row: Int, column: Int) -> Int {
        for candidate in row..<Board.height {
            if candidate == Board.height - 1 { return candidate }
            let below = backgroundBoard[row: candidate + 1, column: column]
            if below == .brick || below == .stone { return candidate }
            if backgroundBoard[row: candidate, column: column] == .empty { continue }
            if candidate >= player.position.row {
                if column > 0 {
                    let left = backgroundBoard[row: candidate, column: column - 1]
                    let belowLeft = backgroundBoard[row: candidate + 1, column: column - 1]
                    if left == .rope || belowLeft == .brick || belowLeft == .stone || belowLeft == .ladder {
                        return candidate
                    }
                }
                if column < Board.width - 1 {
                    let right = backgroundBoard[row: candidate, column: column + 1]
                    let belowRight = backgroundBoard[row: candidate + 1, column: column + 1]
                    if right == .rope || belowRight == .brick || belowRight == .stone || belowRight == .ladder {
                        return candidate
                    }
                }
            }
        }
        return Board.height - 1
    }

    private func candidateAbove(row: Int, column: Int) -> Int {
        var candidate = row
        while candidate > 0 && backgroundBoard[row: candidate, column: column] == .ladder {
            let newRow = candidate - 1
            if newRow <= player.position.row {
                if column > 0 {
                    let left = backgroundBoard[row: candidate, column: column - 1]
                    let aboveLeft = backgroundBoard[row: newRow, column: column - 1]
                    if left == .brick || left == .stone || left == .ladder || aboveLeft == .rope {
                        return newRow
                    }
                }
                if column < Board.width - 1 {
                    let right = backgroundBoard[row: newRow, column: column + 1]
                    let belowRight = backgroundBoard[row: candidate, column: column + 1]
                    if right == .rope || belowRight == .brick || belowRight == .stone || belowRight == .ladder {
                        return newRow
                    }
                }
            }
            candidate = newRow
        }
        return candidate
    }
}
