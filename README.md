# nhiicc-nix

在 **x86_64 NixOS** 按需執行台灣健保卡網路驗證元件。不必加入系統套件、不必
`nixos-rebuild switch`，使用完按 **Ctrl+C** 停止並移除本次執行資料。

封裝的是官方 `mLNHIICC 20240710.1`，不是自然人憑證 HiCOS，也不是健保署官方專案。
目前提供臨時啟動模式，沒有永久安裝用的 NixOS module。

## 使用

需要 Nix flakes、systemd、可使用 sudo 的一般桌面帳號，以及 CCID 相容 USB 讀卡機。
在互動終端中以**一般使用者**執行：

```sh
nix run github:iceice666/nhiicc-nix
```

不要對整個 `nix run` 加 sudo。啟動器會自行呼叫 NixOS 的 sudo wrapper，建立臨時
`nhiicc-ephemeral-session.service`。等待以下訊息才算本機 TLS 握手成功：

```text
NHI middleware TLS endpoint is ready: https://localhost:7777/
```

`gnu_get_libc_version()` 那行不是就緒訊息。TLS ready 也不等於已確認讀卡或網站驗證成功。

### 瀏覽器必做設定

1. 保持終端中的元件執行。
2. 將本次的**公開 CA 憑證**匯入瀏覽器的憑證授權單位／自訂信任設定：
   ```text
   /run/nhiicc-ephemeral-session/NHIRootCA.crt
   ```
   建議使用專用、用完可刪除的瀏覽器 profile。不要匯入私鑰，也不要關閉 TLS 驗證。
3. 在相同 profile 開啟 `https://localhost:7777/`，確認沒有憑證錯誤。
4. 開啟健保署網站，允許該官方網站的 **Apps on device／本機網路存取** 權限。
   **Helium 必須開啟這項權限**；否則網站即使遇到已執行的元件，仍會反覆要求
   開啟 `nhiicc://console`，並跳出「No Apps Available」。本專案不註冊這個 URL handler。
5. 重新整理網站。

已由使用者回報，在 Helium 開啟 Apps on device 後，以下入口可繼續驗證流程：

<https://med.nhi.gov.tw/ca2/nhi/icc/page/portal.html?url=https://cloudicweb.nhi.gov.tw/cloudic/system/mlogin.aspx>

這是單一使用環境回報，不代表所有讀卡機、瀏覽器與政府網站皆已測試。

### 關閉與清理

按 **Ctrl+C**。若終端已離線，可從另一個終端執行：

```sh
sudo systemctl stop nhiicc-ephemeral-session.service
```

systemd 會停止整個服務 cgroup，卸載私有掛載，並刪除
`/run/nhiicc-ephemeral-session`。另設兩小時 runtime 上限，避免遺留 session。

**每次啟動都產生新 CA**。手動匯入瀏覽器的信任不會自動刪除；使用完請移除該 CA
或刪除專用 profile。Nix store 快取與系統 journal 可能保留。`nix run` 不建立永久
profile；不再被其他 GC root 引用的 store 路徑可由正常 Nix GC 回收。本工具不自動
執行全局 GC、不移除其他程序或套件。

## 執行與安全邊界

- 臨時 pcscd 與 supervisor 以 root 執行，健保卡官方程式降權到呼叫者 UID，清除
  supplementary groups 與 capabilities。sudo 信任的是整份 flake 的執行內容，請先審閱。
- 自帶 pcscd 與 CCID 驅動；`/run/pcscd`、`/usr/local/share/NHIICC` 和 `/etc` 僅在
  該 systemd 服務的 mount namespace 內準備，不修改主機 `/etc/hosts`。
- 已有 pcscd/socket 或 port 7777 被占用時會拒絕啟動，不會自動停止其他服務。
  不要同時啟動另一個讀卡服務；USB 硬體並非由此工具獨占鎖定。
- 官方程式在接受本機 TLS 前，需向 `cloudicap.nhi.gov.tw:443` 取得允許網站清單。
  啟動前用主機 resolver 查詢公開 IPv4，拒絕非公開、空白或過多結果，查詢有十秒上限。
  服務保留 `IPAddressDeny=any`，只允許 loopback 與本次端點 IP。
- systemd IP 規則是**位址層級、雙向、所有埠**的例外，不是 HTTPS 網址／443 專用規則。
  DNS 結果檢查不是端點身分驗證。本機官方 listener 仍綁定 `127.0.0.1`。
  IP filtering 依賴 kernel cgroup-BPF 支援。
- 私有 hosts 檔固定本次解析結果，`hosts: files` 不開放元件 DNS egress，也不自動
  放行其他端點。如果網站流程需要其他端點，應先檢查原因，而非直接解除限制。
- 不自動修改系統／瀏覽器信任、不略過官方網站清單、不關閉瀏覽器 sandbox。
- **舊元件警告：**官方 ELF 內嵌 `OpenSSL 1.1.1f 31 Mar 2020`；Nix 的新版 OpenSSL
  只能更新憑證產生工具，不能替換 binary 內的靜態程式碼。可重現打包不等於修復上游漏洞。
- 官方 ZIP 含公開散布的共用私鑰。本專案不安裝或使用那些金鑰；ZIP 作為固定雜湊
  source 仍會出現在 Nix store。真正執行金鑰只在 runtime 產生，不進 Git／Nix derivation。

## 封裝細節

`package/default.nix` 固定官方 ZIP SHA-256，修正 ELF interpreter／library paths，移除
上游建置機 RUNPATH。官方 URL 可能被覆寫；內容改變時下載會失敗，不會偷偷升級。

`package/patch-binary.py` 對完整 ELF SHA-256 與原始指令 bytes 進行校驗，再修補兩處：

- 略過自行 `daemonize()`，讓 systemd/supervisor 管理前景程序、signal、cwd、umask 與生命週期。
- 略過舊 `/etc/hosts` 檢查／寫入邏輯，使用 localhost 流程。

取消 daemonize 也取消原本 `/tmp/exampled.lock`；固定 transient unit 名稱與 port preflight
負責防止本工具重複執行。升級元件時必須重新審查 binary patch，不能只換下載雜湊。

`bin/mLNHIICC` 是底層 ELF，不應單獨執行。`bin/nhiicc` 才會準備完整臨時環境。

## 開發與驗證

```sh
git clone https://github.com/iceice666/nhiicc-nix.git
cd nhiicc-nix
nix build .
nix flake check
nix fmt -- flake.nix package/default.nix package/tests.nix
nix run .
```

`flake.lock` 固定 nixpkgs；flake 只對 `nhiicc` 允許 unfree。輸出限 `x86_64-linux`：
`packages.default`、`packages.nhiicc`、`apps.default`、`checks.*`、`formatter`。

自動測試包括：

- 憑證 SAN、信任鏈、權限、重複執行與異常狀態。
- 模擬 pcscd／元件的 SIGINT、SIGTERM、SIGHUP、子程序退出、TLS／元件啟動失敗清理。
- 真實 loopback TLS server：握手成功即回傳，不等 application EOF；拒絕錯誤 CA。
- 實際已修補 ELF 的啟動回歸測試：攔截 fork 與 hosts-file open，抵達第一個
  `pthread_create` 即退出，尚未啟動服務執行緒、socket 或 USB 操作。
- 固定端點的公開 IPv4 驗證、systemd mixed-prefix 參數與網路範圍檢查。
- ShellCheck（於 shell helper 建置時執行）。

這些測試不能替代 sudo、systemd namespace、USB 與完整網站驗證的真機測試。

## 來源與授權範圍

- [官方 Linux ZIP](https://cloudicweb.nhi.gov.tw/cloudic/system/SMC/CMS_mNHIICC_Setup.Linux.zip)
- [官方元件安裝頁](https://cloudicweb.nhi.gov.tw/cloudic/system/SMC/mEventesting.htm)
- [AUR 打包參考](https://aur.archlinux.org/cgit/aur.git/tree/?h=nhiicc)

本 repo 僅發布 Nix 封裝、啟動腳本、測試和文件，不包含官方 binary；官方元件為
proprietary/unfree，其授權不因本封裝而變更。
