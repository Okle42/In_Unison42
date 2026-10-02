// PanelControls.swift — 面板用的控制項包裝（owner：UI）
//
// 平常一律用標準元件（segmented Picker、switch Toggle、ProgressView）。
// 只有離屏截圖（ImageRenderer）時換成純 SwiftUI 畫的替身：ImageRenderer 畫不出 AppKit 背書的控制項
// （segmented、switch、ProgressView 會變成黃底禁止符號）。替身只影響 `panel-snapshot` 輸出的 PNG，
// 不會出現在真的面板裡；要看真的控制項，用 `panel-snapshot --fake <dir>` 產出的 panel-appkit-*.png。
import AppKit
import SwiftUI

private struct PanelOffscreenKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// true = ImageRenderer 離屏截圖，AppKit 背書的控制項換成替身
    var panelOffscreen: Bool {
        get { self[PanelOffscreenKey.self] }
        set { self[PanelOffscreenKey.self] = newValue }
    }
}

/// 模式分段控制（自動／音樂／影片／遊戲）
struct ModeSegmentedControl: View {
    @Binding var selection: AudioMode
    @Environment(\.panelOffscreen) private var offscreen
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if offscreen {
            HStack(spacing: 2) {
                ForEach(AudioMode.allCases, id: \.self) { m in
                    Text(m.label)
                        .font(.callout)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 3)
                        .background {
                            if m == selection {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(scheme == .dark ? Color.white.opacity(0.24) : Color.white)
                                    .shadow(color: .black.opacity(0.15), radius: 0.5, y: 0.5)
                            }
                        }
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.07)))
        } else {
            Picker("模式", selection: $selection) {
                ForEach(AudioMode.allCases, id: \.self) { m in Text(m.label).tag(m) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }
}

/// 裝置開關（mini switch）
struct DeviceSwitch: View {
    @Binding var isOn: Bool
    let accessibilityName: String
    @Environment(\.panelOffscreen) private var offscreen

    var body: some View {
        if offscreen {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? Color.accentColor : Color.primary.opacity(0.18))
                Circle().fill(.white).padding(1.5).shadow(color: .black.opacity(0.2), radius: 0.5, y: 0.5)
            }
            .frame(width: 26, height: 15)
            .accessibilityLabel(accessibilityName)
        } else {
            Toggle(accessibilityName, isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .accessibilityLabel(accessibilityName)
        }
    }
}

/// 線性進度條；fraction nil = 不確定進度
struct PanelProgressBar: View {
    let fraction: Double?
    @Environment(\.panelOffscreen) private var offscreen

    var body: some View {
        if offscreen {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.1))
                    Capsule().fill(Color.accentColor)
                        .frame(width: g.size.width * CGFloat(min(max(fraction ?? 0.3, 0), 1)))
                }
            }
            .frame(height: 5)
        } else if let f = fraction {
            ProgressView(value: min(max(f, 0), 1))
                .progressViewStyle(.linear)
                .controlSize(.small)
        } else {
            ProgressView()
                .progressViewStyle(.linear)
                .controlSize(.small)
        }
    }
}
