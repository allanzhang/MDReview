import AppKit
import SwiftUI

@MainActor
struct AboutView: View {
    @ObservedObject private var updateManager = UpdateManager.shared
    @ObservedObject private var doc = DocState.shared

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage ?? NSImage(size: NSSize(width: 128, height: 128)))
                .resizable()
                .interpolation(.high)
                .frame(width: 96, height: 96)

            VStack(spacing: 4) {
                Text("MDReview")
                    .font(.title2.weight(.semibold))
                HStack(spacing: 6) {
                    Text(L10n.format("Version %@ (%@)",
                                     language: doc.resolvedLanguage,
                                     updateManager.currentShortVersion,
                                     updateManager.currentBuildNumber))
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    Button {
                        NSWorkspace.shared.open(AboutLinks.githubProject)
                    } label: {
                        Image("GitHubIcon")
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 16, height: 16)
                            .foregroundStyle(Color.primary.opacity(0.78))
                    }
                    .buttonStyle(.plain)
                }
            }

            Text(updateManager.statusText)
                .font(.callout)
                .foregroundStyle(statusColor)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 34)

            if let notice = updateManager.notice {
                Text(notice)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            if case .downloading(let progress) = updateManager.status {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
            }

            Button {
                Task { @MainActor in
                    await updateManager.checkForUpdates(manual: true)
                }
            } label: {
                Text(L10n.string("Check for Updates…", language: doc.resolvedLanguage))
                    .frame(minWidth: 160)
            }
            .buttonStyle(.borderedProminent)
            .disabled(updateManager.isBusy)
        }
        .padding(24)
        .frame(width: 360)
        .background(AboutWindowTitleSetter(
            title: L10n.string("About MDReview", language: doc.resolvedLanguage)
        ))
    }

    private var statusColor: Color {
        if updateManager.notice != nil {
            return .red
        }
        if case .failed = updateManager.status {
            return .red
        }
        return .secondary
    }
}

private struct AboutWindowTitleSetter: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            nsView.window?.title = title
        }
    }
}

@MainActor
final class AboutWindowController: NSWindowController {
    static let shared = AboutWindowController()

    private init() {
        let hostingView = NSHostingView(rootView: AboutView())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 340),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.string("About MDReview", language: DocState.shared.resolvedLanguage)
        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
