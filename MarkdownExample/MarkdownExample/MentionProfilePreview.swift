import SwiftUI

struct MentionProfilePreview: View {
    let profile: ExampleMentionProfile
    let dismiss: () -> Void

    @ScaledMetric(relativeTo: .title2) private var avatarSize: CGFloat = 56

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Group {
                    if profile.isBot {
                        Image(systemName: "sparkles")
                            .font(.title2)
                    } else {
                        Text(profile.avatarInitials)
                            .font(.title2.bold())
                    }
                }
                .frame(width: avatarSize, height: avatarSize)
                .background(.quaternary, in: .rect(cornerRadius: 14))
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(profile.name)
                        .font(.title2.bold())
                        .accessibilityAddTraits(.isHeader)
                    Text(profile.handle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if profile.isBot {
                        Text("BOT")
                            .font(.footnote.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: .capsule)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text(profile.role)
                .font(.headline)
            Label(profile.status, systemImage: profile.statusSymbol)
                .font(.callout)

            Text(profile.bio)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            HStack {
                Text("Demo profile")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("Close", action: dismiss)
                    .keyboardShortcut(.cancelAction)
                    .frame(minHeight: 44)
            }
        }
        .padding()
        .frame(minWidth: 280, idealWidth: 320, maxWidth: 360, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
    }
}
