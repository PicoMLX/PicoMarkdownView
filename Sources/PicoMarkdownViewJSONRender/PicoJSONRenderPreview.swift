#if os(macOS)
import JSONRenderCatalog
import JSONRenderCore
import JSONRenderSwiftUI
import PicoMarkdownView
import SwiftUI

extension PicoEmbeddedBlockRenderer {
    /// Renders a closed `json-render` fence with native SwiftUI components and
    /// local state. Import PicoMarkdownViewJSONRender to opt in; invalid or
    /// unsupported specs keep their ordinary code presentation.
    public static var jsonRender: PicoEmbeddedBlockRenderer {
        makeJSONRender(onAction: nil)
    }

    /// Also accepts `sendMessage` buttons. The application decides what to do
    /// with the message when the user activates one.
    public static func jsonRender(
        onAction: @escaping @MainActor @Sendable (PicoJSONRenderAction) -> Void
    ) -> PicoEmbeddedBlockRenderer {
        makeJSONRender(onAction: onAction)
    }

    private static func makeJSONRender(
        onAction: (@MainActor @Sendable (PicoJSONRenderAction) -> Void)?
    ) -> PicoEmbeddedBlockRenderer {
        PicoEmbeddedBlockRenderer(selectors: [.fencedCode(language: "json-render")], interaction: .interactive) { context in
            guard let spec = PicoJSONRenderSpec.decode(context.source, allowsHostActions: onAction != nil) else {
                return nil
            }
            var actions: [String: ActionHandler] = [:]
            if let onAction {
                actions[PicoJSONRenderSpec.sendMessageAction] = { params in
                    guard let message = PicoJSONRenderSpec.message(in: params) else { return }
                    await onAction(.sendMessage(message))
                }
            }
            var components = NativeCatalog.components.filter { PicoJSONRenderSpec.supportsComponent($0.key) }
            // The upstream switch draws its label separately from an untitled
            // Toggle. Use a native control with its own accessible label.
            components["Switch"] = ComponentDefinition { AnyView(PicoJSONRenderSwitch(context: $0)) }
            return AnyView(PicoJSONRenderPreview(
                context: context,
                spec: spec,
                registry: RendererRegistry(components: components, actions: actions)
            ))
        }
    }
}

@MainActor
private struct PicoJSONRenderPreview: View {
    let context: PicoEmbeddedBlockContext
    let spec: Spec
    let registry: RendererRegistry<AnyView>
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        JSONRenderView(spec: spec, registry: registry, limits: PicoJSONRenderSpec.renderLimits)
            .jsonRenderTextScale(context.bodyFontSize / 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .transaction { transaction in
                if reduceMotion {
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                }
            }
            .overlay {
                if context.isSelected {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.16))
                        .overlay { Rectangle().strokeBorder(Color.accentColor, lineWidth: 1) }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityAddTraits(context.isSelected ? .isSelected : [])
    }
}

private struct PicoJSONRenderSwitch: View {
    let context: ComponentRenderContext<AnyView>
    @Environment(\.jsonRenderTextScale) private var textScale

    var body: some View {
        if let path = context.binding("checked"), let label = context.props.string("label") {
            let isOn = Binding {
                context.stateValue(at: path)?.boolValue ?? false
            } set: { value in
                context.setState(at: path, to: .bool(value))
            }
            Toggle(isOn: isOn) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: label)
                        .font(.system(size: 13 * textScale))
                    if let description = context.props.string("description") {
                        Text(verbatim: description)
                            .font(.system(size: 11 * textScale))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .toggleStyle(.switch)
        }
    }
}
#endif
