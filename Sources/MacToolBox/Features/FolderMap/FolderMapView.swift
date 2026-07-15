import SwiftUI

/// 文件夹映射（软链接）视图：自由选择源目录与目标位置，建立软链接。
/// 与磁盘挂载完全解耦，源可以是任意目录。
struct FolderMapView: View {
    @ObservedObject private var service = FolderMapService.shared

    @State private var targetPath: String = ""
    @State private var linkPath: String = ""
    @State private var lastMessage: (text: String, isError: Bool)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            headerCard
            createCard
            listCard
            Spacer()
        }
        .onAppear { service.reload() }
    }

    // MARK: - Header

    private var headerCard: some View {
        TabHeaderCard(
            icon: "link",
            title: "文件夹映射",
            subtitle: "通过软链接把任意目录指向另一个位置，访问链接即访问源目录。"
        )
    }

    // MARK: - 创建

    private var createCard: some View {
        Card(padding: 12) {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "新建映射", icon: "link.badge.plus")

                VStack(alignment: .leading, spacing: 8) {
                    fieldLabel("源目录（要被指向的目录）")
                    HStack(spacing: 8) {
                        TextField("/Volumes/samsung 或任意文件夹", text: $targetPath)
                            .font(.system(size: 11))
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(1)
                        Button { browseTarget() } label: {
                            Text("浏览").font(.system(size: 11, weight: .semibold))
                        }
                        .buttonStyle(.bordered).controlSize(.small).tint(.secondary)
                    }

                    fieldLabel("链接位置（软链接放在哪，含文件名）")
                    HStack(spacing: 8) {
                        TextField("/Users/you/Documents/link-name", text: $linkPath)
                            .font(.system(size: 11))
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(1)
                        Button { browseLink() } label: {
                            Text("浏览").font(.system(size: 11, weight: .semibold))
                        }
                        .buttonStyle(.bordered).controlSize(.small).tint(.secondary)
                    }
                }

                if let msg = lastMessage {
                    HStack(spacing: 6) {
                        Image(systemName: msg.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .font(.system(size: 11))
                        Text(msg.text).font(.system(size: 11))
                        Spacer()
                        Button { lastMessage = nil } label: {
                            Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                    .foregroundStyle(msg.isError ? Color.red : Color.green)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background((msg.isError ? Color.red : Color.green).opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                HStack {
                    Spacer()
                    Button {
                        createLink()
                    } label: {
                        Text("创建软链接")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(Theme.accentStart)
                    .disabled(targetPath.trimmingCharacters(in: .whitespaces).isEmpty ||
                              linkPath.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    // MARK: - 已创建列表

    private var listCard: some View {
        Card(padding: 12) {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "已创建映射", icon: "list.bullet")

                if service.entries.isEmpty {
                    EmptyState(
                        icon: "link",
                        title: "还没有任何映射",
                        subtitle: "在上方选择源目录与链接位置后点击「创建软链接」"
                    )
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(service.entries) { entry in
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(entry.linkPath)
                                            .font(.system(size: 11, weight: .medium))
                                            .textSelection(.enabled)
                                        if entry.isValid {
                                            Text("有效")
                                                .font(.system(size: 9, weight: .medium))
                                                .foregroundStyle(.green)
                                                .padding(.horizontal, 5).padding(.vertical, 1)
                                                .background(Color.green.opacity(0.10))
                                                .clipShape(Capsule())
                                        } else {
                                            Text("目标失效")
                                                .font(.system(size: 9, weight: .medium))
                                                .foregroundStyle(.red)
                                                .padding(.horizontal, 5).padding(.vertical, 1)
                                                .background(Color.red.opacity(0.10))
                                                .clipShape(Capsule())
                                        }
                                    }
                                    Text("→ \(entry.targetPath)")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                                Spacer()
                                Button {
                                    service.remove(entry.linkPath)
                                    lastMessage = ("已删除映射：\(entry.linkPath)", false)
                                } label: {
                                    Text("删除")
                                        .font(.system(size: 11, weight: .semibold))
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .tint(.secondary)
                            }
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Theme.cardBackground)
                                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.cardBorder, lineWidth: 1))
                            )
                        }
                    }
                }
            }
        }
    }

    // MARK: - 逻辑

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
    }

    private func createLink() {
        let result = service.create(targetPath: targetPath, linkPath: linkPath)
        switch result {
        case .success(let link, let target):
            lastMessage = ("已创建软链接：\(link) → \(target)", false)
        case .targetOccupied(let path):
            lastMessage = ("目标位置已存在且非空，未覆盖：\(path)", true)
        case .failed(let msg):
            lastMessage = (msg, true)
        }
    }

    private func browseTarget() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择源目录"
        panel.begin { result in
            if result == .OK, let url = panel.url {
                targetPath = url.path
                // 若链接位置还没填，自动预填为「源目录名」
                if linkPath.trimmingCharacters(in: .whitespaces).isEmpty {
                    linkPath = url.lastPathComponent
                }
            }
        }
    }

    private func browseLink() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择链接所在目录"
        panel.begin { result in
            if result == .OK, let url = panel.url {
                let name = (targetPath as NSString).lastPathComponent
                let fallback = name.isEmpty ? "link" : name
                linkPath = (url.path as NSString).appendingPathComponent(fallback)
            }
        }
    }
}
