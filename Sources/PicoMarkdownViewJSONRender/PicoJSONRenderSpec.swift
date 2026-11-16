#if os(macOS)
import Foundation
import JSONRenderCore

/// Limits the parts of json-render that model output can use inside a transcript.
enum PicoJSONRenderSpec {
    static let maximumSourceBytes = 32 * 1024
    static let maximumElements = 64
    static let maximumDepth = 8
    static let maximumMessageBytes = 512
    private static let maximumChartRows = 16
    // The resolver charges two slots per object entry and one per array
    // entry. A chart has up to five props and two object entries per row.
    private static let maximumPropSlots = maximumElements * (2 * 5 + (1 + 2 * 2) * maximumChartRows)
    static let sendMessageAction = "sendMessage"
    static let renderLimits = RenderTreeLimits(
        maxDepth: maximumDepth,
        maxRenderedNodes: maximumElements,
        maxWork: maximumElements,
        maxResolvedPropBytes: maximumPropSlots * MemoryLayout<JSONValue>.stride,
        maxChildIDBytes: maximumElements * 64
    )

    private enum Component: String {
        case card = "Card"
        case stack = "Stack"
        case text = "Text"
        case metric = "Metric"
        case barChart = "BarChart"
        case button = "Button"
        case toggle = "Switch"
    }

    static func supportsComponent(_ name: String) -> Bool {
        Component(rawValue: name) != nil
    }

    static func decode(_ source: String, allowsHostActions: Bool = false) -> Spec? {
        guard source.utf8.prefix(maximumSourceBytes + 1).count <= maximumSourceBytes else { return nil }
        let data = Data(source.utf8)
        let decoder = JSONDecoder()
        guard let spec = try? decoder.decode(Spec.self, from: data),
              (1...maximumElements).contains(spec.elements.count),
              spec.elements[spec.root]?.visible == nil else { return nil }

        let state = spec.state ?? [:]
        guard state.count <= 16,
              state.allSatisfy({ isStateKey($0.key) && $0.value.boolValue != nil }),
              spec.elements.allSatisfy({ key, element in
                  isIdentifier(key) && accepts(element, state: state, allowsHostActions: allowsHostActions)
              }) else { return nil }

        // A small elements dictionary can still describe a large graph if its
        // children are reused. Require one connected tree with unique parents.
        var visited: Set<String> = []
        guard visit(spec.root, depth: 1, in: spec.elements, visited: &visited),
              visited.count == spec.elements.count else { return nil }

        // Typed decoding can discard malformed combinations such as a
        // visibility condition with both `$state` and `$item`.
        guard let json = try? decoder.decode(JSONValue.self, from: data),
              validateSpecJSON(json).valid else { return nil }
        return spec
    }

    static func message(in params: [String: JSONValue]) -> String? {
        guard params.count == 1, let message = params["message"]?.stringValue,
              validMessage(message) else { return nil }
        return message
    }

    private static func accepts(
        _ element: UIElement,
        state: [String: JSONValue],
        allowsHostActions: Bool
    ) -> Bool {
        guard let component = Component(rawValue: element.type),
              element.slots == nil, element.repeat == nil, element.watch == nil,
              validVisibility(element.visible, state: state) else { return false }
        if component == .button {
            guard allowsHostActions, validButtonAction(element.on) else { return false }
        } else if element.on != nil {
            return false
        }

        let props = element.props
        let hasChildren = !(element.children ?? []).isEmpty
        switch component {
        case .card:
            return props.hasOnly("title", "description")
                && props.optionalText("title", upTo: 128)
                && props.optionalText("description", upTo: 512)
                && (hasChildren || props["title"] != nil || props["description"] != nil)
        case .stack:
            return hasChildren && props.hasOnly("direction", "gap", "align")
                && props.optionalChoice("direction", from: ["vertical", "horizontal"])
                && props.optionalNumber("gap", in: 0...32)
                && props.optionalChoice("align", from: ["start", "center", "end", "stretch"])
        case .text:
            return !hasChildren && props.hasOnly("text", "variant")
                && props.hasText("text", upTo: 2_048)
                && props.optionalChoice("variant", from: ["body", "lead", "caption", "muted", "code"])
        case .metric:
            let validValue = props.hasText("value", upTo: 64) || props["value"]?.doubleValue?.isFinite == true
            return !hasChildren && props.hasOnly("label", "value", "detail", "trend")
                && props.hasText("label", upTo: 128) && validValue
                && props.optionalText("detail", upTo: 128)
                && props.optionalChoice("trend", from: ["up", "down", "neutral"])
        case .barChart:
            return !hasChildren && validChart(props)
        case .button:
            return !hasChildren && props.hasOnly("label", "variant", "disabled")
                && props.hasText("label", upTo: 128)
                && props.optionalChoice("variant", from: ["primary", "secondary", "danger"])
                && (props["disabled"] == nil || props["disabled"]?.boolValue != nil)
        case .toggle:
            guard !hasChildren, props.hasOnly("label", "description", "checked"),
                  props.hasText("label", upTo: 128), props.optionalText("description", upTo: 256),
                  let binding = props["checked"]?.objectValue, binding.count == 1,
                  let path = binding["$bindState"]?.stringValue else { return false }
            return isBooleanPath(path, state: state)
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

    private static func validButtonAction(_ actions: [String: ActionBindingList]?) -> Bool {
        guard let actions, actions.count == 1, case .actionBinding(let binding)? = actions["press"],
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

    private static func validChart(_ props: [String: JSONValue]) -> Bool {
        guard props.hasOnly("title", "data", "xKey", "yKey", "height"),
              props.optionalText("title", upTo: 128),
              props.optionalText("xKey", upTo: 32), props.optionalText("yKey", upTo: 32),
              props.optionalNumber("height", in: 100...320),
              let rows = props["data"]?.arrayValue, (1...maximumChartRows).contains(rows.count) else { return false }

        let xKey = props["xKey"]?.stringValue ?? "x"
        let yKey = props["yKey"]?.stringValue ?? "y"
        guard isIdentifier(xKey), isIdentifier(yKey), xKey != yKey else { return false }
        return rows.allSatisfy { row in
            guard let values = row.objectValue, values.count == 2, values.hasText(xKey, upTo: 32),
                  let value = values[yKey]?.doubleValue else { return false }
            return (-1e12...1e12).contains(value)
        }
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

private extension Dictionary where Key == String, Value == JSONValue {
    func hasOnly(_ names: String...) -> Bool {
        keys.allSatisfy { names.contains($0) }
    }

    func hasText(_ name: String, upTo limit: Int) -> Bool {
        guard let value = self[name]?.stringValue else { return false }
        return value.utf8.count <= limit && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func optionalText(_ name: String, upTo limit: Int) -> Bool {
        self[name] == nil || hasText(name, upTo: limit)
    }

    func optionalChoice(_ name: String, from options: [String]) -> Bool {
        guard let value = self[name] else { return true }
        return value.stringValue.map { options.contains($0) } ?? false
    }

    func optionalNumber(_ name: String, in bounds: ClosedRange<Double>) -> Bool {
        guard let value = self[name] else { return true }
        return value.doubleValue.map { bounds.contains($0) } ?? false
    }
}
#endif
