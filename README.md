# Adobe UXP CCX 安装工具（v13 安全重构）

适用 Windows PowerShell 5.1 与多语言 Windows。双击 `Install_CCX.bat`；将 `.ccx` 放在 BAT 同目录。不需要 7-Zip。BAT 仅使用 ASCII 字符、CRLF 换行；PS1 使用 UTF-8 BOM、CRLF。脚本没有固定中文系统路径，目标根目录由 Windows 的 ProgramFiles 环境变量确定。

## 使用流程

1. 普通权限搜索 CCX、用 .NET 解包并检查根目录 `manifest.json`。优先读取同目录文件；如果 PATH 中有 Everything `es.exe`，也会查询其索引。
2. 逐个显示 `Ready`、`Rejected` 或 `Already exists`。只接受 manifest 的 host/hosts 全部声明 `app: PS` 的插件，拒绝混合 Host 和其他应用。目标目录格式为 `<id>_<version>`。
3. 检查结果后输入大写 `Y`，此时才弹出 UAC。提权进程重新检查解包目录中的链接、manifest、Host、id/version 和目标路径；复制到 External 下随机临时目录，验证后改名到最终目录。
4. 安装完成后重启 Photoshop，并在“增效工具”菜单或“帮助 → 系统信息”确认插件。

默认不遍历系统目录。需要时在 BAT 顶部将 `CCX_ENABLE_SYSTEM_SEARCH=0` 改成 `1`。扫描范围包含 Program Files、ProgramData、LocalAppData 和 AppData。工具不会下载插件，也不会删除或覆盖现有插件目录。相同目标已存在时拒绝。每个 CCX 单独检查，失败的包不会阻断其他包。安装阶段若目标被另一进程创建，当前包会失败并保留该目录。

## 安全边界

ZIP 路径拒绝 `..`、`.`、绝对路径、驱动器路径、冒号（ADS）、Windows 保留设备名、尾随点或空格、控制字符、重复路径（不区分大小写）、文件与父目录冲突、Unix 符号链接/特殊文件和 Windows reparse 标记。目标路径做规范化和父目录边界检查，并检查现有父目录及暂存文件树中的 reparse point。限制 20,000 条 ZIP 项、总解压声明长度 2 GiB、单文件 512 MiB；解压时再次核对实际长度。恶意程序如果在预检与提权之间修改了用户可写暂存目录，提权阶段会重验结构和 manifest；请只运行可信来源的工具脚本。

## 测试步骤

1. **正常包**：把已知 Photoshop UXP CCX 放在 BAT 旁，双击；确认扫描前没有 UAC，输入 `Y` 后才弹 UAC；安装后重启 Photoshop 检查。
2. **取消**：重新运行，或用另一份合法 CCX，确认提示处输入 `N`；不应弹 UAC，也不应新建目标目录。
3. **重复安装**：再次放入相同包；显示 `Already exists`，不删除已安装目录，也不弹 UAC。
4. **不合法包**：准备测试 ZIP，分别加入 `../escape.txt`、`C:/escape.txt`、`dir:stream`、重复条目、符号链接条目、子目录才有 `manifest.json`、非 PS Host，以及非法 id/version；每个应显示 `Rejected`，且无 UAC。不要用真正需要保留的插件制作破坏性测试包。
5. **多语言路径**：把工具和 CCX 放在包含中文、空格和括号的路径；用非中文 Windows 重复正常安装与取消测试。目标路径由该机器的 ProgramFiles 决定。
6. **拒绝 UAC**：选 `Y` 后在系统对话框点否；应显示失败，不出现最终插件目录。

当前环境没有 Windows PowerShell/UAC，实际 Windows 运行和 Photoshop 识别需按上述步骤在你的机器上验证。
