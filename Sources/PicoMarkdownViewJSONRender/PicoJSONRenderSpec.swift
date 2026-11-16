#if os(macOS)
import Foundation
import JSONRenderCatalog
import JSONRenderCore

/// Bounds transcript input and local state independently of the catalog.
enum PicoJSONRenderSpec {
    static let maximumSourceBytes = 32 * 1024
    static let maximumElements = 64
    static let maximumDepth = 8
    static let maximumMessageBytes = 512
    private static let maximumChartRows = 16
    // Keep the per-fence allocation budget from the original chart catalog.
    private static let maximumPropSlots = maximumElements * (10 + 5 * maximumChartRows)
    static let sendMessageAction = "sendMessage"
    static let renderLimits = RenderTreeLimits(
        maxDepth: maximumDepth,
        maxRenderedNodes: maximumElements,
        maxWork: maximumElements,
        maxResolvedPropBytes: maximumPropSlots * MemoryLayout<JSONValue>.stride,
        maxChildIDBytes: maximumElements * 64
    )

    // Exercise the real resolver and budget without creating SwiftUI views
    // or installing action handlers. The keys come from the full registry.
    @MainActor private static let validationRegistry = RendererRegistry<Bool>(
        components: NativeCatalog.registry(animatesAppearance: false).components.mapValues { _ in
            ComponentDefinition { context in
                context.children.allSatisfy { $0 } && acceptsResolvedProps(context)
            }
        }
    )

    @MainActor
    static func decode(_ source: String, allowsHostActions: Bool = false) -> Spec? {
        guard source.utf8.prefix(maximumSourceBytes + 1).count <= maximumSourceBytes else { return nil }
        let data = Data(source.utf8)
        let decoder = JSONDecoder()
        guard var spec = try? decoder.decode(Spec.self, from: data),
              (1...maximumElements).contains(spec.elements.count),
              spec.elements[spec.root]?.visible == nil else { return nil }

        let state = spec.state ?? [:]
        guard state.count <= 16, state.keys.allSatisfy(isStateKey) else { return nil }

        var visited: Set<String> = []
        guard visit(spec.root, depth: 1, in: spec.elements, visited: &visited),
              visited.count == spec.elements.count else { return nil }

        for (key, var element) in spec.elements {
            guard isIdentifier(key), validationRegistry.canRender(element.type),
                  element.slots == nil, element.repeat == nil, element.watch == nil,
                  validVisibility(element.visible, state: state),
                  validProps(element, state: state) else { return nil }
            if let actions = element.on {
                guard element.type == "Button", validButtonAction(actions) else { return nil }
                if !allowsHostActions { element.on = nil }
            }
            if element.type == "Button", element.on == nil {
                element.props["disabled"] = .bool(true)
            }
            spec.elements[key] = element
        }

        // Typed decoding can discard a malformed combination such as a
        // visibility object containing both `$state` and `$item`.
        guard let json = try? decoder.decode(JSONValue.self, from: data),
              validateSpecJSON(json).valid else { return nil }

        // A switch can reveal initially hidden children. Check every branch
        // at closure so that a later toggle cannot exhaust the render budget.
        var validationSpec = spec
        validationSpec.elements = spec.elements.mapValues { element in
            var element = element
            element.visible = nil
            return element
        }
        guard buildRenderTree(spec: validationSpec, registry: validationRegistry, store: StateStore(state),
                              limits: renderLimits)?.content == true else { return nil }
        return spec
    }

    static func message(in params: [String: JSONValue]) -> String? {
        guard params.count == 1, let message = params["message"]?.stringValue,
              validMessage(message) else { return nil }
        return message
    }

    private static func validProps(_ element: UIElement, state: [String: JSONValue]) -> Bool {
        element.props.allSatisfy { name, value in
            if let binding = value.objectValue, let path = binding["$bindState"]?.stringValue {
                return (element.type == "Switch" || element.type == "Toggle") && name == "checked"
                    && binding.count == 1 && isBooleanPath(path, state: state)
            }
            return isReadOnly(value)
        }
    }

    private static func isReadOnly(_ value: JSONValue) -> Bool {
        switch value {
        case .object(let object):
            if let path = object["$state"]?.stringValue {
                return object.count == 1 && path.hasPrefix("/")
            }
            return object.keys.allSatisfy { !$0.hasPrefix("$") }
                && object.values.allSatisfy(isReadOnly)
        case .array(let values):
            return values.allSatisfy(isReadOnly)
        default:
            return true
        }
    }

    private static func acceptsResolvedProps(_ context: ComponentRenderContext<Bool>) -> Bool {
        let props = context.props
        guard props.values.allSatisfy({ ($0.stringValue?.utf8.count ?? 0) <= 2_048 }) else { return false }
        let type = context.element.type
        if type == "Button" || type == "Switch" || type == "Toggle" {
            let label = props["label"]?.stringValue ?? (type == "Button" ? props["text"]?.stringValue : nil)
            return label?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
        guard type == "BarChart" || type == "LineChart" else { return true }
        if let height = props["height"]?.doubleValue, !(100...320).contains(height) { return false }
        guard let rows = props["data"]?.arrayValue else { return true }
        guard rows.count <= maximumChartRows else { return false }

        let xKey = props["xKey"]?.stringValue ?? "x"
        let yKey = props["yKey"]?.stringValue ?? "y"
        return rows.allSatisfy { row in
            guard let values = row.objectValue else { return true }
            if let label = values[xKey], label.displayString.utf8.count > 128 { return false }
            // Validate the numeric strings Swift Charts receives through the
            // pinned catalog as well as ordinary JSON numbers.
            let value = values[yKey]?.doubleValue
                ?? values[yKey]?.stringValue.flatMap { Double($0.filter { "0123456789.-".contains($0) }) }
            return value.map { (-1e12...1e12).contains($0) } ?? true
        }
    }

    private static func visit(
        _ key: String,
        depth: Int,
        in elements: [String: UIElement],
        visited: inout Set<String>
    ) -> Bool {
        guard depth <= maximumDepth, let element = elements[key], visited.insert(key).inserted else {
            return false
        }
        return (element.children ?? []).allSatisfy {
            visit($0, depth: depth + 1, in: elements, visited: &visited)
        }
    }

    private static func validVisibility(_ condition: VisibilityCondition?, state: [String: JSONValue]) -> Bool {
        guard let condition else { return true }
        guard case .singleCondition(.stateCondition(let comparison)) = condition,
              comparison.eq?.boolValue != nil, comparison.neq == nil, comparison.not == nil,
              comparison.gt == nil, comparison.gte == nil, comparison.lt == nil,
              comparison.lte == nil else { return false }
        return isBooleanPath(comparison.state, state: state)
    }

    private static func validButtonAction(_ actions: [String: ActionBindingList]) -> Bool {
        guard actions.count == 1, case .actionBinding(let binding)? = actions["press"],
              binding.action == sendMessageAction, binding.confirm == nil, binding.onSuccess == nil,
              binding.onError == nil, binding.preventDefault == nil,
              let params = binding.params, params.count == 1,
              case .value(.string(let message))? = params["message"] else { return false }
        return validMessage(message)
    }

    private static func validMessage(_ message: String) -> Bool {
        message.utf8.count <= maximumMessageBytes
            && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func isBooleanPath(_ path: String, state: [String: JSONValue]) -> Bool {
        path.hasPrefix("/") && state[String(path.dropFirst())]?.boolValue != nil
    }

    private static func isStateKey(_ key: String) -> Bool {
        isIdentifier(key) && !["__proto__", "constructor", "prototype"].contains(key)
    }

    private static func isIdentifier(_ key: String) -> Bool {
        (1...64).contains(key.utf8.count) && key.utf8.allSatisfy { byte in
            (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || byte == 45 || byte == 95
        }
    }
}
#endif
