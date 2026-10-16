import AppKit
#if canImport(LodeRunnerCore)
import LodeRunnerCore
#endif

@main
struct LodeRunnerMac {
    @MainActor static func main() {
        let application = NSApplication.shared
        let delegate = GameAppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
    }
}

@MainActor
private final class GameAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow?
    private var gameView: GameView?
    private var speedMenu: NSMenu?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let view = GameView(frame: NSRect(x: 0, y: 0, width: 900, height: 650))
        let window = NSWindow(
            contentRect: view.frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Lode Runner"
        window.minSize = NSSize(width: 560, height: 384)
        window.center()
        window.contentView = view
        window.delegate = self
        window.appearance = NSAppearance(named: .darkAqua)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        self.window = window
        self.gameView = view

        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Lode Runner", action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)
        let controlsItem = NSMenuItem()
        let controlsMenu = NSMenu(title: "Controls")
        controlsMenu.addItem(withTitle: "Move: I J K L or arrow keys", action: nil, keyEquivalent: "")
        controlsMenu.addItem(withTitle: "Dig: U O", action: nil, keyEquivalent: "")
        controlsMenu.addItem(withTitle: "Pause: Space", action: nil, keyEquivalent: "")
        controlsItem.submenu = controlsMenu
        mainMenu.addItem(controlsItem)
        let speedItem = NSMenuItem()
        let speedMenu = NSMenu(title: "Speed")
        for multiplier in 1...4 {
            let title = multiplier == 1 ? "1×  Classic pace (estimate)" : "\(multiplier)×"
            let item = speedMenu.addItem(withTitle: title, action: #selector(selectSpeed(_:)),
                                         keyEquivalent: String(multiplier))
            item.keyEquivalentModifierMask = .command
            item.target = self
            item.tag = multiplier
            item.state = multiplier == 1 ? .on : .off
        }
        speedItem.submenu = speedMenu
        mainMenu.addItem(speedItem)
        self.speedMenu = speedMenu
        NSApplication.shared.mainMenu = mainMenu
        NSApplication.shared.activate(ignoringOtherApps: true)
        view.start()
    }

    @objc private func selectSpeed(_ sender: NSMenuItem) {
        gameView?.setSpeed(multiplier: sender.tag)
        speedMenu?.items.forEach { $0.state = $0.tag == sender.tag ? .on : .off }
    }

    func windowWillClose(_ notification: Notification) {
        NSApplication.shared.terminate(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        gameView?.setWindowFocused(false)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        gameView?.setWindowFocused(true)
    }
}

@MainActor
private final class GameView: NSView {
    // FRAME_PERIOD starts at 6 in the 6502 source. The equivalent fixed
    // game-step rate is an estimate because rendering and guard work vary.
    private static let classicStepsPerSecond = 24.0
    private let catalog = try! LevelCatalog.bundled()
    private let sprites = try! SpriteAtlas.bundled()
    private let splash = try! AppleIIHGR.bundledSplash()
    private let audio = SoundOutput()
    private var game: GameState
    private var timer: Timer?
    private var speedMultiplier = 1
    private var stepAccumulator = 0.0
    private var lastTimerTime: TimeInterval?
    private var pressed: Set<String> = []
    private var queuedDig: PlayerAction?
    private var digVisual: (direction: FacingDirection, frame: Int)?
    private var transitionTicks = 0
    private var transition: Transition = .none
    private static let deathHoldSteps = 12
    private static let gameOverDisplaySteps = 72
    private static let irisSteps = 10
    private static let splashIdleSeconds = 10.0
    private var windowFocused = true
    private var userPaused = false
    private var showingSplash = true
    private var demoPlaying = false
    private var splashIdleTime = 0.0

    private enum Transition: Equatable { case none, restartLevel, nextLevel, gameOver }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        let first = try! LevelLoader.playState(from: catalog.sector(level: 1))
        game = GameState(level: first)
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    func start() {
        let timer = Timer(timeInterval: 1.0 / 60.0, target: self,
                          selector: #selector(tick(_:)), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        lastTimerTime = ProcessInfo.processInfo.systemUptime
    }

    func setSpeed(multiplier: Int) {
        guard (1...4).contains(multiplier) else { return }
        speedMultiplier = multiplier
        stepAccumulator = 0
        lastTimerTime = ProcessInfo.processInfo.systemUptime
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { timer?.invalidate(); timer = nil }
        super.viewWillMove(toWindow: newWindow)
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) { return }
        if showingSplash {
            restartGame()
            return
        }
        if demoPlaying {
            restartGame()
            return
        }
        if event.keyCode == 49 {
            if !event.isARepeat { userPaused.toggle(); pressed.removeAll(); needsDisplay = true }
            return
        }
        if event.keyCode == 36 || event.keyCode == 76 {
            if transition == .gameOver { restartGame() }
            return
        }
        if userPaused || transition != .none { return }
        if let key = keyName(event) {
            pressed.insert(key)
            if !event.isARepeat {
                if key == "digLeft" { queuedDig = .digLeft }
                if key == "digRight" { queuedDig = .digRight }
            }
        }
    }

    override func keyUp(with event: NSEvent) {
        if let key = keyName(event) { pressed.remove(key) }
    }

    override func flagsChanged(with event: NSEvent) {
        // Modifier changes do not alter the original directional command state.
    }

    private func keyName(_ event: NSEvent) -> String? {
        // Hardware positions keep the Apple II controls usable with Korean IMEs.
        switch event.keyCode {
        case 123: return "left"
        case 124: return "right"
        case 125: return "down"
        case 126: return "up"
        case 34, 13: return "up"       // I, W
        case 40, 1: return "down"      // K, S
        case 38, 0: return "left"      // J, A
        case 37, 2: return "right"     // L, D
        case 32, 6: return "digLeft"   // U, Z
        case 31, 7: return "digRight"  // O, X
        default: break
        }
        guard let character = event.charactersIgnoringModifiers?.lowercased().first else { return nil }
        switch character {
        case "i", "w": return "up"
        case "k", "s": return "down"
        case "j", "a": return "left"
        case "l", "d": return "right"
        case "u", "z": return "digLeft"
        case "o", "x": return "digRight"
        default: return nil
        }
    }

    private var currentInput: PlayerInput {
        let primary: PlayerAction?
        if pressed.contains("digLeft") { primary = .digLeft }
        else if pressed.contains("digRight") { primary = .digRight }
        else if pressed.contains("up") { primary = .up }
        else if pressed.contains("down") { primary = .down }
        else { primary = nil }
        let horizontal: HorizontalAction?
        if pressed.contains("left") { horizontal = .left }
        else if pressed.contains("right") { horizontal = .right }
        else { horizontal = nil }
        return PlayerInput(primary: primary, horizontal: horizontal)
    }

    @objc private func tick(_ timer: Timer) {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = min(max(0, now - (lastTimerTime ?? now)), 0.25)
        lastTimerTime = now
        guard windowFocused, !userPaused else {
            stepAccumulator = 0
            return
        }
        if showingSplash {
            splashIdleTime += elapsed
            if splashIdleTime >= Self.splashIdleSeconds { restartGame(demo: true) }
            stepAccumulator = 0
            return
        }
        stepAccumulator += elapsed * Self.classicStepsPerSecond * Double(speedMultiplier)
        let stepCount = min(Int(stepAccumulator), 8)
        stepAccumulator -= Double(stepCount)
        guard stepCount > 0 else { return }
        for _ in 0..<stepCount {
            if !advanceOneStep() { break }
        }
        needsDisplay = true
    }

    private func advanceOneStep() -> Bool {
        if transition != .none {
            if transition == .gameOver {
                transitionTicks -= 1
                if transitionTicks <= 0 {
                    restartGame(showSplash: true)
                    return false
                }
                return true
            }
            transitionTicks -= 1
            if transition == .restartLevel, transitionTicks == Self.irisSteps {
                loadLevel(game.level)
            }
            if transitionTicks <= 0 {
                if transition != .restartLevel { loadLevel(game.level) }
                transition = .none
            }
            return true
        }
        var input = currentInput
        if let queuedDig, game.digDirection == nil {
            input.primary = queuedDig
            self.queuedDig = nil
        }
        let result = game.advance(input: input)
        digVisual = result.playerEvents.compactMap { event in
            if case .digging(let direction, let frame) = event {
                return (direction: direction, frame: frame)
            }
            return nil
        }.first
        if result.playerEvents.contains(where: {
            if case .goldCollected = $0 { return true }
            return false
        }) { playSound(.gold) }
        else if result.playerEvents.contains(where: {
            if case .holeOpened = $0 { return true }
            return false
        }) { playSound(.hole) }
        else if result.playerEvents.contains(where: {
            if case .digging(_, let frame) = $0 { return frame % 4 == 0 }
            return false
        }) { playSound(.dig) }
        if result.worldEvents.contains(.playerDied) {
            playSound(.death)
            transition = game.lives > 0 ? .restartLevel : .gameOver
            transitionTicks = game.lives > 0
                ? Self.deathHoldSteps + 2 * Self.irisSteps
                : Self.deathHoldSteps + Self.gameOverDisplaySteps
        } else if game.levelCompleted {
            playSound(.levelClear)
            transition = .nextLevel
            transitionTicks = 12
        }
        return true
    }

    private func loadLevel(_ number: Int) {
        guard let level = try? LevelLoader.playState(
            from: catalog.progressionSector(displayedLevel: number)) else { return }
        let carriedScore = game.score
        let carriedLives = game.lives
        game = GameState(level: level, number: number, lives: carriedLives)
        game.score = carriedScore
        pressed.removeAll()
        queuedDig = nil
        digVisual = nil
    }

    private func playSound(_ cue: SoundOutput.Cue) {
        if !demoPlaying { audio.play(cue) }
    }

    private func restartGame(showSplash: Bool = false, demo: Bool = false) {
        let level = try! LevelLoader.playState(from: catalog.sector(level: 1))
        game = GameState(level: level)
        pressed.removeAll()
        queuedDig = nil
        digVisual = nil
        userPaused = false
        showingSplash = showSplash
        demoPlaying = demo
        splashIdleTime = 0
        transition = .none
        transitionTicks = 0
        needsDisplay = true
    }

    func setWindowFocused(_ focused: Bool) {
        windowFocused = focused
        if !focused { pressed.removeAll(); queuedDig = nil }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setShouldAntialias(false)
        context.interpolationQuality = .none
        context.setFillColor(NSColor.black.cgColor)
        context.fill(bounds)

        let frame = showingSplash ? splash : gameFrame()
        let pixel = max(1, floor(min(bounds.width / CGFloat(AppleIIHGR.width),
                                     bounds.height / CGFloat(AppleIIHGR.height))))
        let origin = NSPoint(x: floor((bounds.width - CGFloat(AppleIIHGR.width) * pixel) / 2),
                             y: floor((bounds.height - CGFloat(AppleIIHGR.height) * pixel) / 2))
        let colors: [CGColor] = [
            NSColor.black.cgColor,
            NSColor(calibratedRed: 0.14, green: 0.59, blue: 0.94, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.98, green: 0.47, blue: 0.20, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.94, green: 0.94, blue: 0.92, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.68, green: 0.24, blue: 0.83, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.22, green: 0.76, blue: 0.31, alpha: 1).cgColor,
        ]
        let irisRadius: Double? = {
            guard transition == .restartLevel,
                  transitionTicks <= 2 * Self.irisSteps else { return nil }
            let stepsFromCenter = transitionTicks > Self.irisSteps
                ? transitionTicks - Self.irisSteps : Self.irisSteps - transitionTicks
            return Double(stepsFromCenter) * 170.0 / Double(Self.irisSteps)
        }()
        for y in 0..<AppleIIHGR.height {
            for x in 0..<AppleIIHGR.width {
                if let irisRadius, y < Board.height * SpriteAtlas.height {
                    let dx = Double(x - 140), dy = Double(y - 88)
                    if dx * dx + dy * dy > irisRadius * irisRadius { continue }
                }
                let ink = frame.ink(x: x, y: y)
                if ink != .black {
                    context.setFillColor(colors[Int(ink.rawValue)])
                    context.fill(CGRect(x: origin.x + CGFloat(x) * pixel,
                                        y: origin.y + CGFloat(y) * pixel,
                                        width: pixel, height: pixel))
                }
            }
        }
    }

    private func gameFrame() -> AppleIIHGR {
        var frame = AppleIIHGR()
        for row in 0..<Board.height {
            for column in 0..<Board.width {
                let terrain = game.backgroundBoard[row: row, column: column]
                let active = game.activeBoard[row: row, column: column]
                let tile: Tile = terrain == .brick && active != .brick && active != .stone
                    ? .empty : terrain
                let sprite = tile == .trap ? 1 : Int(tile.rawValue)
                if sprite != 0 {
                    frame.draw(sprite: sprite, x: column * 10, y: row * 11, atlas: sprites)
                }
            }
        }
        if let digVisual,
           let phase = SpriteAtlas.digAnimationFrame(direction: digVisual.direction,
                                                     rawFrame: digVisual.frame),
           let brick = SpriteAtlas.digBrickSprite(frame: phase) {
            let column = game.player.position.column + (digVisual.direction == .left ? -1 : 1)
            let row = game.player.position.row
            frame.replace(sprite: brick, x: column * 10, y: (row + 1) * 11, atlas: sprites)
            if let debris = SpriteAtlas.digDebrisSprite(direction: digVisual.direction,
                                                        frame: phase) {
                frame.draw(sprite: debris, x: column * 10, y: row * 11, atlas: sprites)
            }
        }
        for hole in game.holes where hole.fillTimer <= 20 {
            let sprite = hole.fillTimer <= 10 ? 0x38 : 0x37
            frame.draw(sprite: sprite, x: hole.position.column * 10,
                       y: hole.position.row * 11, atlas: sprites)
        }
        for guardState in game.guards where guardState.resurrectionTimer == 0 {
            let screen = SpriteAtlas.screenPosition(guardState.position,
                                                    xOffset: guardState.xOffset,
                                                    yOffset: guardState.yOffset)
            frame.draw(sprite: SpriteAtlas.guardSprite(animation: guardState.animation),
                       x: screen.column, y: screen.row, atlas: sprites)
        }
        let player = game.player
        let playerScreen = SpriteAtlas.screenPosition(player.position,
                                                      xOffset: player.xOffset,
                                                      yOffset: player.yOffset)
        // A filled hole covers the player before the death tune starts.
        if game.alive || game.activeBoard[row: player.position.row,
                                          column: player.position.column] != .brick {
            frame.draw(sprite: SpriteAtlas.playerSprite(animation: player.animation),
                       x: playerScreen.column, y: playerScreen.row, atlas: sprites)
        }

        // PUT_STATUS writes its own letter and digit sprites on game row 16.
        frame.draw(text: "SCORE        MEN    LEVEL   ", column: 0, row: 16, atlas: sprites)
        frame.draw(text: String(format: "%07d", game.score % 10_000_000),
                   column: 5, row: 16, atlas: sprites)
        frame.draw(text: String(format: "%03d", game.lives % 1_000),
                   column: 16, row: 16, atlas: sprites)
        frame.draw(text: String(format: "%03d", game.level % 1_000),
                   column: 25, row: 16, atlas: sprites)
        let overlay: String?
        if !windowFocused || userPaused { overlay = "PAUSED" }
        else { switch transition {
        case .none: overlay = nil
        case .restartLevel: overlay = nil
        case .nextLevel: overlay = "LEVEL CLEAR"
        case .gameOver: overlay = transitionTicks <= Self.gameOverDisplaySteps ? "GAME OVER" : nil
        } }
        if let overlay {
            let column = max(0, (Board.width - overlay.count) / 2)
            frame.draw(text: overlay, column: column, row: 8, atlas: sprites)
        }
        return frame
    }
}
