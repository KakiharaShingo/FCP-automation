import SwiftUI
import AppKit

struct MainView: View {
    @EnvironmentObject var appState: AppState
    
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    
    // 超高輝度の洗練されたエメラルドグリーン
    let themeColor = Color(red: 0.15, green: 0.95, blue: 0.65)
    let darkGray = Color(red: 0.1, green: 0.1, blue: 0.12)

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 300)
        } detail: {
            detailView
                .animation(.smooth(duration: 0.3), value: appState.selectedTab)
        }
        .navigationTitle("")
        .toolbar {
            ToolbarItem(placement: .status) {
                if appState.isTranscribing {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(themeColor)
                            .scaleEffect(0.7)
                        Text("Transcription in progress...")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(themeColor)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 5)
                    .background(
                        Capsule()
                            .fill(themeColor.opacity(0.1))
                            .overlay(
                                Capsule()
                                    .strokeBorder(themeColor.opacity(0.2), lineWidth: 0.5)
                            )
                    )
                }
            }
        }
        .tint(themeColor)
        .preferredColorScheme(.dark)
    }

    private var sidebar: some View {
        ZStack {
            // macOS標準の深い透過背景
            VisualEffectView(material: .sidebar, blendingMode: .behindWindow)
                .ignoresSafeArea()
            
            // うっすらとした緑のアンビエントライト
            LinearGradient(
                colors: [themeColor.opacity(0.15), .clear, themeColor.opacity(0.05)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                // ブランドセクション
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(themeColor.gradient)
                                .frame(width: 32, height: 32)
                                .shadow(color: themeColor.opacity(0.5), radius: 8, y: 4)
                            
                            Image(systemName: "wand.and.stars.inverse")
                                .font(.system(size: 14, weight: .black))
                                .foregroundStyle(.black)
                        }
                        
                        VStack(alignment: .leading, spacing: 0) {
                            Text("FCP AUTO")
                                .font(.system(size: 16, weight: .black, design: .rounded))
                                .foregroundStyle(.primary)
                                .tracking(1)
                            Text("ADVANCED EDITOR")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(themeColor)
                                .opacity(0.8)
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 40)
                .padding(.bottom, 32)

                // カテゴリ見出し
                Text("WORKSPACE")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 12)
                    .tracking(2)

                // ナビゲーションメニュー
                VStack(spacing: 6) {
                    ForEach(AppState.TabItem.allCases, id: \.self) { tab in
                        sidebarButton(for: tab)
                    }
                }
                .padding(.horizontal, 12)
                
                Spacer()
                
                // フッター/設定など（画像イメージに合わせる）
                HStack(spacing: 16) {
                    Image(systemName: "gearshape.fill")
                    Image(systemName: "bell.badge.fill")
                    Spacer()
                    Circle()
                        .fill(.ultraThinMaterial)
                        .frame(width: 28, height: 28)
                        .overlay(Text("JS").font(.system(size: 10, weight: .bold)))
                }
                .foregroundStyle(.secondary)
                .padding(24)
            }
        }
    }

    private func sidebarButton(for tab: AppState.TabItem) -> some View {
        let isSelected = appState.selectedTab == tab
        
        return Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                appState.selectedTab = tab
            }
        } label: {
            HStack(spacing: 16) {
                Image(systemName: tab.icon)
                    .font(.system(size: 16, weight: isSelected ? .bold : .medium))
                    .foregroundStyle(isSelected ? .black : themeColor.opacity(0.8))
                    .frame(width: 24)
                
                Text(tab.rawValue)
                    .font(.system(size: 14, weight: isSelected ? .bold : .medium))
                    .foregroundStyle(isSelected ? .black : .primary.opacity(0.8))
                
                Spacer()
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(themeColor.gradient)
                        .shadow(color: themeColor.opacity(0.4), radius: 10, y: 4)
                } else {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.02))
                }
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var detailView: some View {
        ZStack {
            // メイン背景
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()
            
            // コンテンツエリアのフローティング効果
            ZStack {
                // 背後のグローエフェクト
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(themeColor.opacity(0.03))
                    .blur(radius: 40)
                    .offset(x: -20, y: -20)

                Group {
                    switch appState.selectedTab {
                    case .transcription:
                        TranscriptionView()
                    case .editing:
                        EditingView()
                    case .timeline:
                        TimelineView()
                    case .plugins:
                        PluginView()
                    case .export:
                        ExportView()
                    case .youtubeEditor:
                        YouTubeEditorView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(darkGray)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.5), radius: 30, x: 0, y: 15)
            }
            .padding(20)
        }
    }
}

// MARK: - Helper Views

struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }
    
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

// MARK: - Preview (Canvas)
#Preview("MainView - FCP Automation") {
    MainView()
        .environmentObject(AppState())
        .frame(width: 1000, height: 750)
}
