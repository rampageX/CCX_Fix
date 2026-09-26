# 背景

## 为什么我在 Adobe Photoshop 安装某个滤镜后，只能在 滤镜 菜单看到，而在 增效工具 看不到？

Adobe 增效工具属于 UXP 插件，它并不像 .8bf 那么简单。

通常它是个用 `zip` 格式打包的 `.ccx` 文件。标准安装方法是 `.ccx`  + Adobe 的 UnifiedPluginInstallerAgent（UPIA）。Adobe 官方给出的 Windows 安装方式就是让 UPIA 安装 `.ccx`  插件。

而实际上我们单独安装的 Adobe Photoshop 根本没有这个 UPIA，我们甚至连它那个什么 Creative Cloud 也不会装。

而 Nik Collection 8 的补丁作者实际上用了一个非常粗暴但有效的方法：  

不管 UPIA，不管 Creative Cloud，不管 Marketplace,

直接把 `.ccx`  文件解包到 UXP 完整目录：
↓
```
C:\Program Files\Common Files\Adobe\UXP\Plugins\External
```
↓
Photoshop 启动后自己扫描就能找到。

# Adobe UXP CCX 安装工具（根据以上原理制作的自动化工具）

将 `.ccx` 放在 BAT 同目录，双击 `Install_CCX.bat`，启动 Photoshop。

适用 Windows PowerShell 5.1 （Windows 10/11 默认）与多语言 Windows。

## 内部工作流程

1. 普通权限搜索 `.ccx` 、用 .NET 解包并检查根目录 `manifest.json`。优先读取同目录文件；如果 PATH 中有 Everything `es.exe`，也会查询其索引。
2. 逐个显示 `Ready`、`Rejected` 或 `Already exists`。只接受 manifest 的 host/hosts 全部声明 `app: PS` 的插件，拒绝混合 Host 和其他应用。目标目录格式为 `<id>_<version>`。
3. 检查结果后输入大写 `Y`，此时才弹出 UAC。提权进程重新检查解包目录中的链接、manifest、Host、id/version 和目标路径；复制到 External 下随机临时目录，验证后改名到最终目录。
4. 安装完成后重启 Photoshop，并在“增效工具”菜单或“帮助 → 系统信息”确认插件。

默认不遍历系统目录。需要时在 BAT 顶部将 `CCX_ENABLE_SYSTEM_SEARCH=0` 改成 `1`。扫描范围包含 `Program Files、ProgramData、LocalAppData` 和 `AppData`。

工具不会下载插件，也不会删除或覆盖现有插件目录。相同目标已存在时拒绝。每个 CCX 单独检查，失败的包不会阻断其他包。安装阶段若目标被另一进程创建，当前包会失败并保留该目录。

## 安全边界

ZIP 路径拒绝 `..`、`.`、绝对路径、驱动器路径、冒号（ADS）、Windows 保留设备名、尾随点或空格、控制字符、重复路径（不区分大小写）、文件与父目录冲突、Unix 符号链接/特殊文件和 Windows reparse 标记。目标路径做规范化和父目录边界检查，并检查现有父目录及暂存文件树中的 reparse point。限制 20,000 条 ZIP 项、总解压声明长度 2 GiB、单文件 512 MiB；解压时再次核对实际长度。恶意程序如果在预检与提权之间修改了用户可写暂存目录，提权阶段会重验结构和 manifest；请只运行可信来源的工具脚本。

## 使用步骤

全盘搜索 .ccx，把这些 ccx 文件放在 BAT 旁，双击；

如果当前目录下没有 .ccx 文件，而你系统安装有 Everrting 并在运行状态，那么脚本会自动调用它搜索出硬盘上的所有 .ccx 文件，你复制过来就行。


