import Testing
@testable import LodeRunnerCore

struct SpriteCollisionTests {
    @Test func originalBitmapMasksDetectOverlap() throws {
        let atlas = try SpriteAtlas.bundled()
        let same = Position(column: 20, row: 30)
        #expect(atlas.overlaps(sprite: SpriteAtlas.playerSprite(animation: 8), at: same,
                               sprite: SpriteAtlas.guardSprite(animation: 0), at: same))
        #expect(!atlas.overlaps(sprite: SpriteAtlas.playerSprite(animation: 8), at: same,
                                sprite: SpriteAtlas.guardSprite(animation: 0),
                                at: Position(column: 40, row: 30)))
    }

    @Test func movingPlayerDiesOnGuardPixelsUnlessGoldWasCollected() throws {
        let start = try LevelLoader.playState(from: LevelCatalog.bundled().sector(level: 1))
        var game = GameState(level: start)
        game.guards[0].position = game.player.position
        let collision = game.advance(input: PlayerInput(horizontal: .left))
        #expect(collision.worldEvents.contains(.playerDied))
        #expect(!game.alive)
        #expect(game.lives == 4)

        game = GameState(level: start)
        game.guards[0].position = game.player.position
        game.player.xOffset = 1
        game.backgroundBoard[row: 14, column: 14] = .gold
        let collected = game.advance(input: PlayerInput(horizontal: .right))
        #expect(collected.playerEvents.contains(.goldCollected(Position(column: 14, row: 14))))
        #expect(!collected.worldEvents.contains(.playerDied))
        #expect(game.alive)
    }
}
