import Testing
@testable import LodeRunnerCore

@Suite struct AppleIIHGRTests {
    @Test func adjacentPixelsBecomeWhiteAndSeparatedPixelsUsePhaseColors() {
        var page = AppleIIHGR()
        page.setPixel(x: 2, y: 0)
        #expect(page.ink(x: 2, y: 0) == .blue)
        page.setPixel(x: 4, y: 0)
        #expect(page.ink(x: 3, y: 0) == .blue)
        page.setPixel(x: 5, y: 0)
        #expect(page.ink(x: 4, y: 0) == .white)
        #expect(page.ink(x: 5, y: 0) == .white)
        #expect(page.ink(x: 6, y: 0) == .black)
    }

    @Test func statusLettersAndDigitsComeFromOriginalAtlas() throws {
        let atlas = try SpriteAtlas.bundled()
        var actual = AppleIIHGR()
        var expected = AppleIIHGR()
        actual.draw(character: "A", column: 0, row: 16, atlas: atlas)
        expected.draw(sprite: 69, x: 0, y: 176, atlas: atlas)
        actual.draw(character: "0", column: 1, row: 16, atlas: atlas)
        expected.draw(sprite: 59, x: 10, y: 176, atlas: atlas)
        for y in 176..<187 {
            for x in 0..<20 {
                #expect(actual.ink(x: x, y: y) == expected.ink(x: x, y: y))
            }
        }
    }

    @Test func bundledSplashContainsOriginalColorArtwork() throws {
        let page = try AppleIIHGR.bundledSplash()
        var colored = 0
        for y in 0..<AppleIIHGR.height {
            for x in 0..<AppleIIHGR.width where page.ink(x: x, y: y) != .black {
                colored += 1
            }
        }
        #expect(colored > 3_000)
        #expect(page.ink(x: 0, y: 0) == .black)
    }

    @Test func diggingUsesOriginalBrickAndDebrisSequence() throws {
        #expect(SpriteAtlas.digAnimationFrame(direction: .left, rawFrame: 0) == 0)
        #expect(SpriteAtlas.digAnimationFrame(direction: .left, rawFrame: 12) == 12)
        #expect(SpriteAtlas.digAnimationFrame(direction: .right, rawFrame: 12) == 0)
        #expect(SpriteAtlas.digAnimationFrame(direction: .right, rawFrame: 15) == 3)
        #expect(SpriteAtlas.digAnimationFrame(direction: .right, rawFrame: 24) == 12)
        #expect(SpriteAtlas.digAnimationFrame(direction: .right, rawFrame: 25) == nil)
        #expect(SpriteAtlas.digBrickSprite(frame: 0) == 0x1F)
        #expect(SpriteAtlas.digBrickSprite(frame: 3) == 0x20)
        #expect(SpriteAtlas.digBrickSprite(frame: 11) == 0x24)
        #expect(SpriteAtlas.digBrickSprite(frame: 12) == nil)
        #expect(SpriteAtlas.digDebrisSprite(direction: .left, frame: 0) == 0x1B)
        #expect(SpriteAtlas.digDebrisSprite(direction: .right, frame: 2) == 0x27)
        #expect(SpriteAtlas.digDebrisSprite(direction: .left, frame: 7) == 0x1E)
        #expect(SpriteAtlas.digDebrisSprite(direction: .right, frame: 8) == nil)

        let atlas = try SpriteAtlas.bundled()
        var page = AppleIIHGR()
        page.draw(sprite: 1, x: 0, y: 0, atlas: atlas)
        page.replace(sprite: 0x1F, x: 0, y: 0, atlas: atlas)
        var expected = AppleIIHGR()
        expected.draw(sprite: 0x1F, x: 0, y: 0, atlas: atlas)
        for y in 0..<11 {
            for x in 0..<10 {
                #expect(page.ink(x: x, y: y) == expected.ink(x: x, y: y))
            }
        }
    }
}
