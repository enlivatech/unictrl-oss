# Unictrl

[English](README.md) · [简体中文](README.zh-Hans.md) · **繁體中文**

**一組鍵盤，一個滑鼠，所有電腦。**

把指標推出 Mac 螢幕的邊緣，它就出現在 Windows 電腦上，鍵盤也跟著過去；推回來，就又回到 Mac。不用切換，不用等待。

鍵盤和滑鼠一直連在 Mac 上，Unictrl 透過區域網路把輸入加密轉送給 PC。用起來就像 Apple 的「通用控制」，只是這次連接的是 Mac 和 Windows。兩邊都是原生 App：macOS 上是 SwiftUI 選單列 App，Windows 上是 WinUI 3 App。

Unictrl 只做一件事：讓你的指標和鍵盤在多台電腦之間自由來去。它不做剪貼簿共享、檔案傳輸或拖放。

- 原始碼：https://github.com/enlivatech/unictrl-oss
- 官方網站：[enliva.org](https://www.enliva.org)（Unictrl 開發者 Enliva）
- 授權條款：[GPL-3.0](LICENSE)，免費開源

> **正式使用前，請先讀 [ADAPTING.md](ADAPTING.md)（英文）。** Unictrl 最初是為一張桌子寫的工具：一台 Mac、一台 Windows 筆電、羅技 MX Keys 鍵盤和 MX Anywhere 3S 滑鼠。核心功能任何鍵盤滑鼠都能用，但少數按鍵動作和羅技相關功能是依照這套設備調整的。ADAPTING.md 列出了每一處，以及該怎麼修改。

## 功能

### 在電腦之間移動

- **推到螢幕邊緣就過去。** 把指標推出 Mac 的左邊緣或右邊緣，就到了那一側的 PC；推出 PC 的邊緣就回來。切換只需要幾毫秒。
- **依實際尺寸排列螢幕。** 在設定 › Screens 裡，把 PC 拖到 Mac 的左邊或右邊，也可以上下調整。螢幕依實體尺寸（讀取每台顯示器的公釐數）顯示，即使兩台螢幕的解析度不同，指標也會在你預期的高度跨過去。
- **Windows 原生手感。** 在 PC 上，指標使用 Windows 自己的速度和加速度，就像滑鼠直接接在 PC 上。另有「PC 指標速度」滑桿可以微調。
- **捲動一致。** 平滑捲動和反轉滾輪方向（只針對滑鼠滾輪，不影響觸控式軌跡板）在 Mac 上生效，也會帶到 PC 上；PC 的捲動速度可以另外設定。
- **同一時間只有一個指標。** 指標在 PC 上時 Mac 游標會隱藏，在 Mac 上時 Windows 游標會隱藏，一眼就知道指標在哪台電腦。
- **多台 PC**（實驗性）。多台 PC 和 Mac 排成一列，指標可以從一台 PC 移到下一台。

### 鍵盤

- **整個鍵盤跟著指標走**，包括修飾鍵和長按重複輸入。
- **Windows 上有兩種鍵位。** 「Windows layout」依照鍵盤上的 Windows 標示（Option/⊞ 為 Win，Cmd/Alt 為 Alt）；「Mac layout」依照位置對應（Option 為 Alt，Command 為 Win）。
- **媒體鍵和系統鍵**（音量、播放/暫停、下一首、靜音）作用在指標所在的電腦上；亮度鍵可調整 PC 筆電內建螢幕的亮度。
- **大寫鎖定保持一致。** 跨過去時，PC 會同步 Mac 的大寫鎖定狀態。
- **鎖定 PC**：按 Ctrl+Cmd+Q，和鎖定 Mac 的快速鍵一樣。
- **聽寫鍵跟著指標走。** 用來啟動聽寫的按鍵（滑鼠中鍵、右側 Command 鍵）會送到指標所在的電腦，不會被 Mac 攔走。

### 配對與安全

- **用 6 位數配對碼配對。** 在 Mac 上選擇 *Pair a Windows PC…*，在 PC 上的 Unictrl 裡輸入 Mac 顯示的配對碼。配對碼本身從來不會經過網路。
- **自動找到 Mac。** PC 會在區域網路裡自動找到 Mac，不用輸入 IP 位址，Windows 上也不用新增輸入方向的防火牆規則。
- **一律加密。** 金鑰透過 P-256 ECDH 交換產生，並以配對碼確認；每則訊息都以 AES-256-GCM 加密並防止重送攻擊。沒有不加密的模式。
- **不需要帳號，不經過雲端。** 所有資料都留在你的網路裡，也從不記錄按鍵內容。

### 設定與狀態

- **即時連線品質。** 兩台電腦的設定裡都會顯示評等（Smooth、Some hitches、Choppy）、來回延遲和即時曲線、卡頓來自哪裡（滑鼠無線訊號、Mac、網路還是 PC），以及不夠流暢時可以嘗試的改善清單。
- **自訂名稱。** 可以替 Mac 和每台 PC 重新命名，名稱會顯示在所有畫面上。
- **開機自動啟動。** 兩邊預設在登入時啟動。Mac App 可以顯示在選單列和/或 Dock；Windows App 可以顯示在通知區域和/或工作列。

### 可靠性

- **指標一定會回來。** PC 沒有回應、連線中斷或 Unictrl 結束時，指標都會回到 Mac。
- **不會卡鍵。** 指標離開或連線結束時，PC 會放開所有仍按著的按鍵和滑鼠按鈕。
- **短暫斷線會自動接上。** 連線很快恢復時，會接著剛才的狀態繼續。

### 羅技設備附加功能（選用）

適用於有 Easy-Switch 的羅技設備，例如 MX Keys：

- **只在一個 Easy-Switch 頻道上共享。** 留一個頻道給 Unictrl，其他頻道照常直接連單台電腦；鍵盤切到其他頻道時，Unictrl 會自動暫停。
- **Mac 睡眠時把鍵盤滑鼠交給 PC**，喚醒後再接回來。
- **準備就緒提示音。** 鍵盤和滑鼠都回到共享頻道時，可以播放一聲提示音。

## 系統需求

- macOS 15 或更新版本（Apple 晶片或 Intel）。
- Windows 10 2004 或更新版本，或 Windows 11，x64。
- 兩台電腦在同一個可信任的區域網路裡（TCP 24860；UDP 24861 用於自動尋找）。
- 建置需要：Mac 上的 Xcode 命令列工具（Swift 6）；Windows 上的 [.NET 10 SDK](https://dotnet.microsoft.com/download)。

## 安裝

目前還沒有簽署過的安裝檔，兩邊都需要從原始碼建置。

**macOS**

```sh
# 需要一個程式碼簽署身分（Apple Development 憑證即可）：
#   security find-identity -v -p codesigning
UNICTRL_SIGNING_IDENTITY=<憑證雜湊值> macos/build-app.sh   # 安裝到 ~/Applications/Unictrl.app
open ~/Applications/Unictrl.app
```

macOS 的輔助使用權限綁定在 bundle ID、安裝路徑和簽署身分上，三者保持不變，重新建置後就不用重新授權。衍生版本（fork）建議把 `macos/Info.plist` 裡的 bundle ID `com.enlivatech.unictrl` 改掉，避免和本 App 共用權限和設定。

**Windows**（在 PC 上）

```powershell
dotnet publish windows\Unictrl\Unictrl.csproj -c Release -p:Platform=x64 -o out
# 把 out 複製到 %LOCALAPPDATA%\Programs\Unictrl，然後執行 Unictrl.exe
```

在 Mac 上開發、透過 SSH 在 PC 上建置：設定 `UNICTRL_WINDOWS_HOST=user@pc`，然後執行 `tools/deploy-windows.sh`（建置、安裝並啟動）或 `tools/test-windows.sh`（單元測試）。

**測試：** Mac 上 `cd macos && swift test`；Windows 上 `dotnet test windows\Unictrl.Tests`。

## 第一次使用

1. **Mac：** 在「系統設定 › 隱私權與安全性」裡，允許 Unictrl 使用「輔助使用」和「輸入監控」。
2. **Mac：** 按一下選單列裡的 Unictrl，選擇 **Pair a Windows PC…**，畫面上會顯示 6 位數配對碼。
3. **PC：** 打開 Unictrl，輸入配對碼。
4. **Mac：** 在設定 › **Screens** 裡，把 PC 拖到它在桌上所在的那一側。
5. 把指標推出那一邊。

Windows App 以系統管理員權限執行，這樣在系統管理員視窗裡也能打字。

## 運作原理

Mac 透過事件監聽（event tap）讀取輸入。指標在 Mac 上時，Unictrl 只留意指標有沒有到達外側邊緣；一旦跨過去，Mac 會凍結並隱藏自己的游標，把每一次移動、點按、捲動和按鍵轉送給 PC，由 PC 以 `SendInput` 重現。指標到達 PC 另一側的邊緣時，PC 會通知 Mac，指標就回來了。

由 PC 主動連線到 Mac（TCP 24860），所以 Windows 不需要輸入方向的防火牆規則。完整的通訊協定請見 [docs/PROTOCOL.md](docs/PROTOCOL.md)，按鍵對應請見 [docs/KEYMAP.md](docs/KEYMAP.md)（英文）。

## 常見問題

**和「通用控制」有什麼不同？** 通用控制只能在 Apple 裝置之間使用。Unictrl 把同樣的體驗帶到 Mac 和 Windows 之間；Mac 同時連著 iPad 時，兩者可以一起使用。

**和 Synergy、Barrier、Deskflow 有什麼不同？** Unictrl 更精簡，兩邊都是原生 App：只有一個功能，一個 SwiftUI App 加一個 WinUI 3 App，一律加密，用配對碼配對，內建 Windows 原生指標速度和螢幕實體尺寸。它是獨立撰寫的程式碼，不是這些專案的衍生版本。

**為什麼不做剪貼簿和檔案傳輸？** 為了把一件事做好。剪貼簿同步是另一個獨立的產品。

**可以讓 Windows 當連接鍵盤滑鼠的那台嗎？** 目前不行，鍵盤滑鼠一律連在 Mac 上。

**可以透過網際網路使用嗎？** 它是為區域網路設計的。Wi-Fi 延遲會讓指標出現卡頓；任何一台電腦接上網路線都會有幫助，連線品質的改善清單也會告訴你還能怎麼做。

**會把資料傳到伺服器嗎？** 不會。Unictrl 只和你自己的電腦通訊。

## 修改與參與貢獻

[ADAPTING.md](ADAPTING.md)（英文）列出了哪些地方是依照最初那套設備客製的（羅技設備、少數按鍵動作、實際測試過的設備組合、用到的 macOS 私有 API），以及該怎麼修改。歡迎到 <https://github.com/enlivatech/unictrl-oss/issues> 提出 issue 和 pull request；這是一個小型專案，不保證提供支援。安全性問題請依照 [SECURITY.md](SECURITY.md) 私下回報。

## 授權條款

程式碼和圖示都以 [GNU GPL v3.0](LICENSE) 授權：可以自由使用、修改和散布；散布修改後的版本時，也必須以 GPL-3.0 公開原始碼。衍生版本可以繼續使用 Unictrl 這個名稱和圖示。

© 2026 Enliva LLC · [enliva.org](https://www.enliva.org)
