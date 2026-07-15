import SwiftUI

/// 磁盘挂载视图：每行一个卷，浏览选路径后直接挂载；挂载后显示取消
struct DiskMountView: View {
    @ObservedObject private var service = DiskMountService.shared

    // 每个卷对应的挂载点（默认 /Volumes/卷名，可手动改或浏览；留空则使用默认路径）
    @State private var volumeMountPoints: [String: String] = [:]
    @State private var lastMessage: (text: String, isError: Bool)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            headerCard
            availableDisksCard
            if let msg = lastMessage {
                messageBanner(msg)
            }
            Spacer()
        }
        .onAppear { loadState() }
    }

    // MARK: - Header

    private var headerCard: some View {
        TabHeaderCard(
            icon: "externaldrive",
            title: "磁盘挂载",
            subtitle: "启动磁盘已自动排除。",
            trailing: {
                Button {
                    service.refreshDiskList()
                } label: {
                    Text("刷新")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(Theme.accentStart)
            }
        )
    }

    private func messageBanner(_ msg: (text: String, isError: Bool)) -> some View {
        HStack(spacing: 6) {
            Image(systemName: msg.isError ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .font(.system(size: 11))
            Text(msg.text)
                .font(.system(size: 11))
            Spacer()
            Button {
                lastMessage = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .foregroundStyle(msg.isError ? Color.red : Color.orange)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background((msg.isError ? Color.red : Color.orange).opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - 可用磁盘

    private var availableDisksCard: some View {
        Card(padding: 12) {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "可用磁盘", icon: "externaldrive.connected.to.line.below")

                if service.diskList.isEmpty {
                    EmptyState(
                        icon: "externaldrive",
                        title: "未检测到可用磁盘",
                        subtitle: "连接外部磁盘后点击「刷新」查看"
                    )
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(service.diskList) { disk in
                            DiskRow(
                                disk: disk,
                                mountPoint: binding(for: disk)
                            ) {
                                mount(disk: disk)
                            } onUnmount: {
                                unmount(disk: disk)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - 逻辑

    private func binding(for disk: DiskMountService.DiskInfo) -> Binding<String> {
        let key = disk.volumeName ?? disk.bsdName
        let defaultPoint = "/Volumes/\(disk.volumeName ?? disk.bsdName)"
        return Binding(
            get: { volumeMountPoints[key] ?? defaultPoint },
            set: { volumeMountPoints[key] = $0 }
        )
    }

    private func preferredMountPoint(for disk: DiskMountService.DiskInfo) -> String? {
        let key = disk.volumeName ?? disk.bsdName
        let raw = volumeMountPoints[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let defaultPoint = "/Volumes/\(disk.volumeName ?? disk.bsdName)"
        return raw == defaultPoint ? nil : (raw.isEmpty ? nil : raw)
    }

    private func loadState() {
        service.refreshDiskList()
        var points: [String: String] = [:]
        for disk in service.diskList {
            let key = disk.volumeName ?? disk.bsdName
            points[key] = disk.mountPoint?.isEmpty == false ? disk.mountPoint! : "/Volumes/\(disk.volumeName ?? disk.bsdName)"
        }
        volumeMountPoints = points
    }

    private func mount(disk: DiskMountService.DiskInfo) {
        guard let vname = disk.volumeName else { return }
        let point = preferredMountPoint(for: disk)
        let result = service.mountVolume(volumeName: vname, mountPoint: point)

        if result.success, let actual = result.actualMountPoint {
            // 记忆实际挂载点，用于开机自动恢复
            ConfigStore.shared.setMountPoint(vname, actual)
            if let msg = result.errorMessage {
                // 真正的 fallback（用户指定了自定义路径但失败）才提示
                lastMessage = (msg, false)
            } else {
                lastMessage = nil
            }
        } else {
            lastMessage = (result.errorMessage ?? "挂载失败", true)
        }
    }

    private func unmount(disk: DiskMountService.DiskInfo) {
        guard let vname = disk.volumeName else { return }
        _ = service.unmountVolume(volumeName: vname)
        lastMessage = nil
    }
}

// MARK: - 单行

private struct DiskRow: View {
    let disk: DiskMountService.DiskInfo
    @Binding var mountPoint: String

    let onMount: () -> Void
    let onUnmount: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(disk.volumeName ?? "(未命名)")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text("\(disk.bsdName) · \(disk.fileSystem ?? "unknown") · \(formatBytes(disk.sizeBytes))")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if disk.isMounted {
                    Text("已挂载")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.10))
                        .clipShape(Capsule())
                }
            }

            HStack(spacing: 8) {
                if disk.isMounted {
                    Text(disk.mountPoint ?? "")
                        .font(.system(size: 11))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button {
                        onUnmount()
                    } label: {
                        Text("取消")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.secondary)
                } else {
                    HStack(spacing: 8) {
                        TextField("挂载路径（默认 /Volumes/卷名）", text: $mountPoint)
                            .font(.system(size: 11))
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(1)

                        Button {
                            browseFolder { path in
                                if let path = path { mountPoint = path }
                            }
                        } label: {
                            Text("浏览")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(.secondary)

                        Button {
                            onMount()
                        } label: {
                            Text("挂载")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(Theme.accentStart)
                    }
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Theme.cardBorder, lineWidth: 1)
                )
        )
    }

    private func browseFolder(completion: @escaping (String?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        panel.begin { result in
            if result == .OK, let url = panel.url {
                completion(url.path)
            } else {
                completion(nil)
            }
        }
    }

    private func formatSize(_ size: Int64) -> String {
        formatBytes(size)
    }
}
