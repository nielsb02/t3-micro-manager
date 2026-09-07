import Foundation

public enum T3MicroAction: String, Codable, CaseIterable, Sendable {
    case dialClockwise = "dial-clockwise"
    case dialCounterclockwise = "dial-counterclockwise"
    case dialPress = "dial-press"
    case composerToggle = "composer-toggle"
    case newThread = "new-thread"
    case newProject = "new-project"
    case latestMessage = "latest-message"
    case settleThread = "settle-thread"
    case terminalToggle = "terminal-toggle"
    case commandPalette = "command-palette"

    public static let assignableActions: [Self] = [
        .newThread, .newProject, .composerToggle, .latestMessage,
        .settleThread, .terminalToggle, .commandPalette,
    ]

    public var title: String {
        switch self {
        case .dialClockwise: return "Dial clockwise"
        case .dialCounterclockwise: return "Dial counterclockwise"
        case .dialPress: return "Dial press"
        case .composerToggle: return "Focus/unfocus input"
        case .newThread: return "New chat"
        case .newProject: return "New project"
        case .latestMessage: return "Latest message"
        case .settleThread: return "Settle thread"
        case .terminalToggle: return "Toggle terminal"
        case .commandPalette: return "Command palette"
        }
    }
}

/// One consumer preserves the order of rotations and presses across asynchronous checks.
@MainActor
final class OrderedInputQueue<Input> {
    private var pending: [(input: Input, consume: @MainActor (Input) async -> Void)] = []
    private var worker: Task<Void, Never>?
    private var workers: [UUID: Task<Void, Never>] = [:]
    private var generation = 0

    func enqueue(_ input: Input, consume: @escaping @MainActor (Input) async -> Void) {
        guard pending.count < 64 else { return }
        pending.append((input, consume))
        guard worker == nil else { return }
        let epoch = generation
        let id = UUID()
        worker = Task {
            defer { workers[id] = nil }
            while !Task.isCancelled, generation == epoch, !pending.isEmpty {
                let next = pending.removeFirst()
                await next.consume(next.input)
            }
            if generation == epoch { worker = nil }
        }
        workers[id] = worker
    }

    func cancel() {
        generation += 1
        pending.removeAll()
        for task in workers.values { task.cancel() }
        worker = nil
    }

    func drain() async {
        for task in Array(workers.values) { await task.value }
    }
}

public enum MicroControlMapping {
    public static let fixedActions: [T3MicroAction] = [.dialClockwise, .dialCounterclockwise, .dialPress, .composerToggle]

    enum Input: Equatable {
        case control(T3MicroAction)
        case actionButton(Int, T3MicroAction)
        case sessionKey(Int)
    }

    static func input(slot: Int, sessionKeys: [Int], controls: [T3MicroAction: Int],
                      actionButtons: [Int: T3MicroAction] = [:], slotOffset: Int = 6) -> Input? {
        if let action = fixedActions.first(where: { controls[$0] == slot }) { return .control(action) }
        guard let key = LayerMapping.physicalKey(forAgentSlot: slot, slotOffset: slotOffset) else { return nil }
        if let action = actionButtons[key] { return .actionButton(key, action) }
        guard sessionKeys.contains(key) else { return nil }
        return .sessionKey(key)
    }

    public struct SavedBinding: Codable, Equatable, Sendable {
        public var original: String
        public var ownedCode: String
        public var recoveryOriginals: [String: String]?

        public init(original: String, ownedCode: String, recoveryOriginals: [String: String]? = nil) {
            self.original = original
            self.ownedCode = ownedCode
            self.recoveryOriginals = recoveryOriginals
        }

        func original(for installedCode: String) -> String? {
            installedCode == ownedCode ? original : recoveryOriginals?[installedCode]
        }

        mutating func retainRecovery(from previous: Self) {
            var originals = previous.recoveryOriginals ?? [:]
            originals[previous.ownedCode] = previous.original
            originals.removeValue(forKey: ownedCode)
            recoveryOriginals = originals.isEmpty ? nil : originals
        }
    }

    static func code(_ slot: Int) -> String { String(format: "KV_OAI_AG%02d", slot) }

    /// Include every assigned physical button, for both sessions and actions.
    public static func slots(config: [String: Any], target: LayerTarget, sessionKeys: [Int], slotOffset: Int = 6) throws -> [T3MicroAction: Int] {
        guard [0, 6].contains(slotOffset) else { throw LayerMapping.Failure.invalidKeys }
        let selected = try LayerMapping.selectedLayer(config: config, target: target)
        try LayerMapping.validate(keys: sessionKeys, keymap: selected.keymap)
        var remaining = selected.layout
        for action in fixedActions { try set("", action: action, layout: &remaining) }
        var matrix = selected.keymap
        for key in sessionKeys {
            let position = Pad.position(of: key)!
            matrix[position.row][position.column] = ""
        }
        remaining["keymap"] = matrix
        let sessionSlots = Set(sessionKeys.compactMap { LayerMapping.agentSlot(forPhysicalKey: $0, slotOffset: slotOffset) })
        var occupied = Set<Int>()
        func scan(_ value: Any) {
            if let string = value as? String, string.hasPrefix("KV_OAI_AG"),
               let slot = Int(string.dropFirst(9)) { occupied.insert(slot) }
            else if let array = value as? [Any] { array.forEach(scan) }
            else if let dictionary = value as? [String: Any] { dictionary.values.forEach(scan) }
        }
        scan(remaining)
        if let conflict = sessionSlots.intersection(occupied).sorted().first {
            throw LayerMapping.Failure.conflictingBinding(code(conflict))
        }
        let free = (slotOffset...19).filter { !sessionSlots.contains($0) && !occupied.contains($0) }
        guard free.count >= fixedActions.count else {
            throw ConfigurationError.invalid("The dial and joystick down need four free agent slots. Assign at most \(16 - slotOffset) session and action buttons in total, or free other agent bindings on this layer in Input.")
        }
        return Dictionary(uniqueKeysWithValues: zip(fixedActions, free))
    }

    static func binding(_ action: T3MicroAction, layout: [String: Any]) throws -> String {
        if let index = encoderIndex(action), let encoders = layout["encoders"] as? [[String]],
           let dial = encoders.first, dial.indices.contains(index) { return dial[index] }
        if action == .composerToggle, let joystick = layout["joystick"] as? [String: Any],
           joystick["type"] as? String == "RADIAL", let sectors = joystick["sectors"] as? [[String: Any]],
           let index = southIndex(sectors), let code = sectors[index]["k"] as? String { return code }
        throw ConfigurationError.invalid("This layer needs a dial with rotation and press bindings, and one radial joystick down sector. Configure those controls in Input, then read the layers again.")
    }

    static func set(_ code: String, action: T3MicroAction, layout: inout [String: Any]) throws {
        _ = try binding(action, layout: layout)
        if let index = encoderIndex(action) {
            var encoders = layout["encoders"] as! [[String]]
            encoders[0][index] = code
            layout["encoders"] = encoders
        } else {
            var joystick = layout["joystick"] as! [String: Any]
            var sectors = joystick["sectors"] as! [[String: Any]]
            sectors[southIndex(sectors)!]["k"] = code
            joystick["sectors"] = sectors
            layout["joystick"] = joystick
        }
    }

    private static func encoderIndex(_ action: T3MicroAction) -> Int? {
        switch action {
        case .dialClockwise: return 0
        case .dialCounterclockwise: return 1
        case .dialPress: return 2
        default: return nil
        }
    }

    private static func southIndex(_ sectors: [[String: Any]]) -> Int? {
        let matching = sectors.indices.filter { index in
            guard let a1 = sectors[index]["a1"] as? Double, let a2 = sectors[index]["a2"] as? Double else { return false }
            return abs(KeymapManager.sectorCentre(a1, a2) - 0.75) < 0.01
        }
        return matching.count == 1 ? matching.first : nil
    }
}
