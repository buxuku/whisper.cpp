**这是什么？** 这是给 **CPU 比较老（不支持 AVX2 指令集）的电脑** 准备的 SmartSub「自定义加速包」（whisper.cpp 语音识别组件），属于**实验性**版本。SmartSub 自带的标准加速包要求 CPU 支持 AVX2，老电脑用它转写时可能直接闪退；换成本页的文件，就有机会在老电脑上继续使用本地语音识别。

> **使用前请先了解**
>
> - 这些文件只使用 SSE4.2 + AVX 指令集，**速度明显比标准包慢**，建议优先选用体积较小的语音模型。
> - **还没有在真实的老 CPU 上实测过**（只做了静态检查和模拟器测试，详见文末「技术细节」），请当作实验性功能使用。
> - 只提供 **Windows** 和 **Linux（x64）** 版本，**没有 macOS 版本**。
> - SmartSub **不会自动下载、更新**这些文件，需要你按下面的步骤手动下载、手动导入。
> - 需要 SmartSub 3.0 或更高版本（更早的版本没有「自定义加速包」入口），建议升级到[最新版](https://github.com/buxuku/SmartSub/releases)。

整个过程只有三步：**① 下载一个文件 → ② 放进一个固定的文件夹 → ③ 在 SmartSub 里点「选择文件」导入。**

## 一、我需要这个包吗？

**适合使用**——同时满足下面两点：

1. 你的电脑是 Windows 或 Linux，CPU 比较老，大致是 2011～2014 年前后的型号，例如：型号以 2 或 3 开头的英特尔酷睿 i3 / i5 / i7（如 i5-2400、i7-3770、i5-3210M），或 AMD FX / A 系列。
2. 在 SmartSub 里转写时遇到了下面任意一种情况：
   - 软件突然闪退、直接退出；
   - 较新版本的 SmartSub 提示「这台电脑的 CPU 可能不支持内置语音识别」。

**不需要使用**：英特尔第 4 代及更新的酷睿 i3 / i5 / i7（2013 年起）、AMD 锐龙（Ryzen）等较新的 CPU，直接用 SmartSub 自带的加速包就行。

**用不了**：连 AVX 指令集都不支持的 CPU，例如英特尔第 1 代酷睿（2008～2010 年）及更早的型号，以及部分奔腾（Pentium）、赛扬（Celeron）、凌动（Atom）。这类电脑加载本页的文件同样会闪退，请改用 SmartSub 里的云端语音识别或其他引擎。

**怎么查看自己的 CPU 型号？**

- Windows：按 `Ctrl + Shift + Esc` 打开任务管理器，点「性能」→「CPU」，右上角就是型号。也可以在「设置 → 系统 → 关于」里查看「处理器」。
- Linux：打开终端，输入 `lscpu | grep "Model name"`。想直接确认支持哪些指令集，可以输入 `grep -o -w -E 'avx|avx2' /proc/cpuinfo | sort -u`：只显示 `avx`，说明适合用本页的文件；`avx` 和 `avx2` 都有，说明不需要；什么都没有，说明用不了。

## 二、第 1 步：下载对应的文件

根据你的系统，从下表里选**一个**文件，点击文件名即可下载（本页底部的 Assets 列表里也有同样的文件）：

| 你的电脑 | 请下载这个文件 | 大小 |
| --- | --- | --- |
| Windows（不确定选哪个，就选这个） | [`addon-windows-x64-avx.node`](https://github.com/buxuku/whisper.cpp/releases/download/legacy-cpu/addon-windows-x64-avx.node) | 约 2 MB |
| Windows，并且显卡支持 Vulkan、想用显卡加速（进阶，可选） | [`addon-windows-vulkan-avx.node`](https://github.com/buxuku/whisper.cpp/releases/download/legacy-cpu/addon-windows-vulkan-avx.node) | 约 44 MB |
| Linux（64 位 x64，Ubuntu 22.04 及以上） | [`addon-linux-x64-avx.node`](https://github.com/buxuku/whisper.cpp/releases/download/legacy-cpu/addon-linux-x64-avx.node) | 约 3 MB |

下载时请注意：

- 只需要下载**一个**文件。Windows 用户一般选第一个；第二个（显卡版）没有做过运行时检查，如果导入后出问题，请换回第一个。
- 下载下来的是一个以 `.node` 结尾的文件，**不是压缩包，不需要解压，也不需要改名，更不要双击运行**。SmartSub 界面上写着「下载后需要解压出 addon.node 文件」，那是针对标准加速包压缩包的说法，不适用于本页的文件。
- 浏览器如果提示这个文件「不常见」或「可能有风险」，请选择「保留」。
- Assets 列表里的 `Source code (zip)` 和 `Source code (tar.gz)` 是 GitHub 自动生成的源码包，用不到，不要下载。
- **不要**去 SmartSub 里「下载加速包」按钮指向的 `latest` 页面下载：那里是标准包，需要 AVX2，在老 CPU 上会闪退。
- 下载很慢或打不开 GitHub：请换个网络，或使用你习惯的 GitHub 加速方式。暂时没有提供国内镜像。

## 三、第 2 步：把文件放进一个固定的文件夹

SmartSub 导入时**不会复制这个文件，只会记住它所在的位置**。所以不要把它留在「下载」文件夹里（清理下载文件夹后就会失效），请先放到一个固定的地方：

- Windows：新建文件夹 `C:\SmartSub-addon`，把下载好的文件移进去。
- Linux：新建文件夹 `~/smartsub-addon`，把下载好的文件移进去。

之后请不要移动或删除这个文件，也建议保持原来的文件名；否则需要重新导入。

## 四、第 3 步：在 SmartSub 里导入

1. 打开 SmartSub。
2. 点击左侧导航栏的 **「引擎」**（3.3 及更早的版本里叫「引擎与模型」）。
3. 在页面左边的引擎列表里，找到 **「本地引擎」** 分组，点击 **「whisper.cpp（内置）」**。
4. 在右边找到 **「GPU 加速」** 区域，点击 **「GPU 加速 · 管理 / 高级」** 把它展开（默认是收起的）。
5. 先看一下 **「加速模式」**：请选择 **「自动（推荐）」**。不要选「仅 CPU」——这个模式下 SmartSub 会忽略自定义加速包，导入了也不会生效。
6. 往下找到 **「自定义加速包」** 这一栏，点击右边的 **「选择文件」**。
7. 在弹出的窗口里，找到刚才放好的 `.node` 文件（例如 `C:\SmartSub-addon\addon-windows-x64-avx.node`），选中后点「打开」。
8. 看到提示 **「自定义加速包已设置，重启应用后生效」**，并且这一栏显示 **「已启用自定义加速包」** 和文件路径，就说明导入成功了。
9. **完全退出 SmartSub，再重新打开**，让设置生效。
10. 找一段 1 分钟左右的短音频或短视频试着转写一次。能正常生成字幕、软件没有闪退，就大功告成。

找不到上面的菜单？

- 这个入口只有 Windows 和 Linux 版本才有，macOS 版本没有。
- 界面名称可能随版本略有不同，建议先把 SmartSub 升级到[最新版](https://github.com/buxuku/SmartSub/releases)。

## 五、取消导入，换回自带的加速包

回到同一个位置（引擎 → whisper.cpp（内置）→ GPU 加速 · 管理 / 高级 → 自定义加速包），点击这一栏右边红色的 **「×」**，出现「已取消自定义加速包」的提示即可，SmartSub 会改回使用自带的加速包。想换成另一个文件，重新点「选择文件」就行。

## 六、常见问题

**1. 导入后转写还是闪退，或者软件直接退出？**

- 确认下载的文件和你的系统对应（Windows 用文件名里带 `windows` 的，Linux 用带 `linux` 的），并且文件名里有 `-avx`；
- 确认「加速模式」是「自动（推荐）」；
- 如果用的是 Vulkan 版，请换成 `addon-windows-x64-avx.node`；
- 还是不行，说明这台电脑的 CPU 可能连 AVX 也不支持，或者这个实验性的文件不适合你的机型。请先点红色「×」取消自定义加速包，然后改用云端语音识别或其他引擎。也欢迎到 [SmartSub Issues](https://github.com/buxuku/SmartSub/issues) 反馈，请附上 CPU 型号和 SmartSub 版本号。

**2. 转写特别慢？**

这是正常现象：这些文件没有 AVX2、FMA 等加速指令，比标准包慢很多。可以优先选用体积较小的模型。

**3. Windows 提示「找不到指定的模块」，或缺少 `VCRUNTIME140.dll`、`MSVCP140.dll`？**

请安装微软官方的「Microsoft Visual C++ 运行库（x64）」：[点此下载](https://aka.ms/vs/17/release/vc_redist.x64.exe)（[官方说明页](https://learn.microsoft.com/cpp/windows/latest-supported-vc-redist)），安装后重新打开 SmartSub。

**4. Linux 提示 `GLIBC_2.34 not found` 之类的错误？**

说明系统版本太旧。本页的 Linux 文件需要 glibc 2.34 或更高，也就是 Ubuntu 22.04 及以上，或同等新的发行版。

**5. 怎么确认下载的文件是完整的？（可选）**

1. 下载本页的 [`SHA256SUMS.txt`](https://github.com/buxuku/whisper.cpp/releases/download/legacy-cpu/SHA256SUMS.txt)，用记事本打开，找到你那个文件名所在的行，行首的一长串字符就是它的校验值。
2. 在存放文件的文件夹里计算校验值，看和上面是否完全一致（字母大小写不影响比较）：
   - Windows：在文件夹顶部的地址栏里输入 `powershell` 并回车，在打开的窗口里输入 `Get-FileHash -Algorithm SHA256 .\addon-windows-x64-avx.node`，看 `Hash` 那一列（文件名换成你自己的）。
   - Linux：在该文件夹里打开终端，输入 `sha256sum addon-linux-x64-avx.node`（文件名换成你自己的）。

**6. SmartSub 升级后需要重新导入吗？**

SmartSub 只记住文件的路径，升级软件后一般不需要重新导入。如果升级后转写出现异常，请回到本页下载最新的文件重新导入，或点红色「×」取消。

## 技术细节（可选阅读）

<details>
<summary>点击展开技术细节</summary>

- **文件清单**：`addon-windows-x64-avx.node`（Windows，仅 CPU）、`addon-windows-vulkan-avx.node`（Windows，Vulkan 显卡加速）、`addon-linux-x64-avx.node`（Linux，仅 CPU）、`SHA256SUMS.txt`（校验值）、`build-info.json`（构建信息）。
- **指令集基线**：SSE4.2 + AVX。没有 AVX2 / FMA / F16C / BMI，因此推理明显慢于标准包。
- **运行环境**：与标准包相同（Windows 需要 Microsoft Visual C++ 运行库；Linux 需要 glibc 2.34 及以上，即 Ubuntu 22.04 及以上）。
- **已做的检查**：对所有文件中的 ggml / whisper 库做了静态指令集扫描；对仅 CPU 的两个文件做了本机冒烟转写，并读取了 addon 自带的 `system_info`；对 Linux 文件在 qemu-user（IvyBridge / SandyBridge）模拟环境下完整转写了一次。**尚未在真实的不支持 AVX2 的 CPU 上运行过；Windows Vulkan 文件没有运行时检查。**
- **关于扫描结果里的「已放行」**：Windows 库里仍有少数 MSVC 运行库函数，会在运行时经过 CPU 能力判断后才选择 AVX2 路径。静态扫描把它们单独列为「已放行」，构建日志里有对应的反汇编。
- **来源**：上游 `{{UPSTREAM_REPO}}` 标签 `{{UP_TAG}}`（提交 `{{UP_COMMIT}}`）加上 `.github/upstream/patches` 里的补丁（详见 `build-info.json`），构建时间 {{BUILT_AT}}，[构建记录]({{RUN_URL}})。

</details>

---

**What is this?** Experimental builds of the SmartSub "Custom Addon" (the whisper.cpp speech-recognition component) for computers whose **CPU does not support the AVX2 instruction set**. The standard acceleration packs that SmartSub uses require AVX2, so on an older computer SmartSub can crash during transcription. With the files on this page you may be able to keep using local speech recognition on that computer.

> **Before you start**
>
> - These files only use the SSE4.2 + AVX instruction sets, so they are **noticeably slower than the standard packs**. Prefer smaller speech models.
> - They have **not been tested on a real older CPU yet** (only static checks and emulator tests; see "Technical details" at the end). Please treat them as experimental.
> - **Windows** and **Linux (x64)** only. **There is no macOS build.**
> - SmartSub **never downloads or updates** these files for you. Follow the steps below to download and import them manually.
> - Requires SmartSub 3.0 or later (earlier versions have no Custom Addon option). Upgrading to the [latest version](https://github.com/buxuku/SmartSub/releases) is recommended.

The whole process has three steps: **1) download one file → 2) put it in a permanent folder → 3) import it in SmartSub with "Browse".**

## 1. Do I need this?

**You need it** if both of these are true:

1. You are on Windows or Linux and your CPU is fairly old, roughly from 2011-2014. For example: an Intel Core i3 / i5 / i7 whose model number starts with 2 or 3 (such as i5-2400, i7-3770 or i5-3210M), or an AMD FX / A-series CPU.
2. SmartSub shows one of these problems when transcribing:
   - the app suddenly crashes or quits;
   - a newer version of SmartSub shows "This computer's CPU may not support built-in speech recognition".

**You do not need it** on 4th-generation (2013) or newer Intel Core i3 / i5 / i7, AMD Ryzen, and other newer CPUs. The packs that come with SmartSub work for them.

**It will not work** on CPUs that do not even support AVX, such as 1st-generation Intel Core (2008-2010) and older, and some Pentium, Celeron and Atom models. Loading these files on such a computer will crash as well. Use cloud speech recognition or another engine in SmartSub instead.

**How do I check my CPU?**

- Windows: press `Ctrl + Shift + Esc` to open Task Manager, go to **Performance → CPU**, and the model name is shown at the top right. You can also find it under **Settings → System → About → Processor**.
- Linux: open a terminal and run `lscpu | grep "Model name"`. To check the instruction sets directly, run `grep -o -w -E 'avx|avx2' /proc/cpuinfo | sort -u`. If it prints only `avx`, the files on this page are for you. If it prints both `avx` and `avx2`, you do not need them. If it prints nothing, they will not work.

## 2. Step 1: Download the right file

Pick **one** file from the table for your system and click its name to download it (the same files are in the Assets list at the bottom of this page):

| Your computer | File to download | Size |
| --- | --- | --- |
| Windows (if you are not sure, choose this one) | [`addon-windows-x64-avx.node`](https://github.com/buxuku/whisper.cpp/releases/download/legacy-cpu/addon-windows-x64-avx.node) | about 2 MB |
| Windows, with a Vulkan-capable graphics card, if you want GPU acceleration (advanced, optional) | [`addon-windows-vulkan-avx.node`](https://github.com/buxuku/whisper.cpp/releases/download/legacy-cpu/addon-windows-vulkan-avx.node) | about 44 MB |
| Linux (64-bit x64, Ubuntu 22.04 or newer) | [`addon-linux-x64-avx.node`](https://github.com/buxuku/whisper.cpp/releases/download/legacy-cpu/addon-linux-x64-avx.node) | about 3 MB |

Please note:

- Download only **one** file. Most Windows users should pick the first one. The second one (GPU) has no runtime check, so if something goes wrong after importing it, switch back to the first one.
- The downloaded file ends in `.node`. It is **not an archive: do not extract it, do not rename it, and do not double-click it.** SmartSub's on-screen tip says "extract the addon.node file"; that applies to the compressed standard packs, not to the files on this page.
- If your browser says the file is "uncommon" or "may be harmful", choose **Keep**.
- In the Assets list, `Source code (zip)` and `Source code (tar.gz)` are generated by GitHub automatically and are not needed. Do not download them.
- **Do not** download from the `latest` page that SmartSub's "Download Packs" link opens. Those are the standard packs, which need AVX2 and will crash on an old CPU.
- If GitHub is slow or unreachable, try another network or a GitHub accelerator you trust. There is no mirror for these files yet.

## 3. Step 2: Put the file in a permanent folder

When you import the file, SmartSub **does not copy it; it only remembers where the file is**. So do not leave it in your Downloads folder (it will stop working once that folder is cleaned up). Put it in a fixed location first:

- Windows: create the folder `C:\SmartSub-addon` and move the downloaded file into it.
- Linux: create the folder `~/smartsub-addon` and move the downloaded file into it.

Afterwards, do not move or delete the file, and keep its original file name. Otherwise you will need to import it again.

## 4. Step 3: Import it in SmartSub

1. Open SmartSub.
2. Click **Engines** in the left sidebar (in version 3.3 and earlier it is called **Engines & Models**).
3. In the engine list on the left, find the **Local engines** group and click **whisper.cpp (built-in)**.
4. On the right, find the **GPU Acceleration** section and click **GPU acceleration · Manage / Advanced** to expand it (it is collapsed by default).
5. Look at **Acceleration Mode** and choose **Auto (Recommended)**. Do not choose **CPU Only**: in that mode SmartSub ignores the custom addon, so the import would have no effect.
6. Scroll down to **Custom Addon** and click **Browse** on its right.
7. In the file dialog, find the `.node` file you saved (for example `C:\SmartSub-addon\addon-windows-x64-avx.node`), select it and click Open.
8. You should see the message **Custom addon set, restart the app to take effect**, and that row should now show **Custom addon enabled** together with the file path. That means the import worked.
9. **Quit SmartSub completely and start it again** so the setting takes effect.
10. Try transcribing a short audio or video clip of about a minute. If subtitles are generated and the app does not crash, you are done.

Cannot find these menus?

- This option only exists in the Windows and Linux versions, not in macOS.
- Names can differ slightly between versions. Upgrade SmartSub to the [latest version](https://github.com/buxuku/SmartSub/releases) first.

## 5. Cancel the import and go back to the built-in pack

Go back to the same place (Engines → whisper.cpp (built-in) → GPU acceleration · Manage / Advanced → Custom Addon) and click the red **×** on the right of that row. When you see "Custom addon cleared", SmartSub is using its built-in packs again. To use a different file, click **Browse** again.

## 6. FAQ

**1. It still crashes after importing, or the app quits?**

- Make sure the file matches your system (use the file with `windows` in its name on Windows and the one with `linux` on Linux) and that its name contains `-avx`.
- Make sure **Acceleration Mode** is **Auto (Recommended)**.
- If you imported the Vulkan one, switch to `addon-windows-x64-avx.node`.
- If it still crashes, your CPU may not even support AVX, or this experimental file may not suit your machine. Click the red **×** to clear the custom addon first, then use cloud speech recognition or another engine. You are welcome to report it on [SmartSub Issues](https://github.com/buxuku/SmartSub/issues); please include your CPU model and SmartSub version.

**2. Transcription is very slow?**

That is expected: these files have no AVX2, FMA or similar acceleration instructions, so they are much slower than the standard packs. Prefer smaller models.

**3. Windows says "The specified module could not be found", or reports a missing `VCRUNTIME140.dll` or `MSVCP140.dll`?**

Install Microsoft's "Microsoft Visual C++ Redistributable (x64)": [download](https://aka.ms/vs/17/release/vc_redist.x64.exe) ([official page](https://learn.microsoft.com/cpp/windows/latest-supported-vc-redist)), then restart SmartSub.

**4. Linux reports something like `GLIBC_2.34 not found`?**

Your system is too old. The Linux file on this page needs glibc 2.34 or newer, which means Ubuntu 22.04 or later, or an equally recent distribution.

**5. How can I check that the file was downloaded correctly? (optional)**

1. Download [`SHA256SUMS.txt`](https://github.com/buxuku/whisper.cpp/releases/download/legacy-cpu/SHA256SUMS.txt) from this page, open it in a text editor and find the line with your file name. The long string at the start of the line is its checksum.
2. Compute the checksum of your file in the folder where you saved it and compare (upper or lower case does not matter):
   - Windows: type `powershell` in the address bar at the top of the folder and press Enter, then in the window that opens run `Get-FileHash -Algorithm SHA256 .\addon-windows-x64-avx.node` and look at the `Hash` column (use your own file name).
   - Linux: open a terminal in that folder and run `sha256sum addon-linux-x64-avx.node` (use your own file name).

**6. Do I need to import it again after upgrading SmartSub?**

SmartSub only remembers the path of the file, so you usually do not need to import it again after upgrading. If transcription misbehaves after an upgrade, come back to this page, download the latest file and import it again, or click the red **×** to clear it.

## Technical details (optional)

<details>
<summary>Click to expand the technical details</summary>

- **Files**: `addon-windows-x64-avx.node` (Windows, CPU only), `addon-windows-vulkan-avx.node` (Windows, Vulkan GPU), `addon-linux-x64-avx.node` (Linux, CPU only), `SHA256SUMS.txt` (checksums) and `build-info.json` (build information).
- **Instruction-set baseline**: SSE4.2 + AVX. No AVX2 / FMA / F16C / BMI, so inference is noticeably slower than the standard builds.
- **Runtime requirements**: same as the standard builds (Windows: Microsoft Visual C++ Redistributable; Linux: glibc 2.34 or newer, i.e. Ubuntu 22.04+).
- **Checks done**: a static ISA scan of the ggml / whisper libraries in every file; a native smoke transcription plus the addon's own `system_info` for the two CPU-only files; and a full transcription under qemu-user (IvyBridge / SandyBridge) for the Linux file. **They have not been run on a real pre-AVX2 CPU yet, and the Windows Vulkan file has no runtime check.**
- **About "guarded" in the scan results**: the Windows libraries still contain a few MSVC runtime routines that pick AVX2 paths at run time behind CPU checks. The static scan lists them separately as guarded, and the build log shows their disassembly.
- **Source**: upstream `{{UPSTREAM_REPO}}` tag `{{UP_TAG}}` (commit `{{UP_COMMIT}}`) plus the patches from `.github/upstream/patches` (details in `build-info.json`), built {{BUILT_AT}}, [build run]({{RUN_URL}}).

</details>
