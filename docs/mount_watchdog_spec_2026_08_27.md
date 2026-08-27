# 掛載守護系統（mount-watchdog）規格

**建立日期：** 2026-08-27
**規格作者：** Coordinator（Claude Opus 5）
**狀態：** 待實作

---

## 1. 背景（事故事實，全部經過驗證，不是推測）

2026-08-27 約 01:25，Docker Desktop 的 WSL2 utility VM 崩潰，導致**所有從 Windows 磁碟掛進容器的 bind mount 同時失效**，容器內看到：

```
OSError: [Errno 5] Input/output error: '/vault'
```

### 1.1 已驗證的根因鏈

1. 機器上**沒有** `C:\Users\xx\.wslconfig`（已於本次事故後建立）。
2. 沒有該檔時，WSL2 允許 utility VM 預留**一半的實體記憶體**：本機 63.4 GB → 31.7 GB。
3. 實測所有容器加總只用 **2.7 GB**（最大的 `steel-api` 356 MB）。預留額度與實際用量差了一個數量級。
4. VM 在記憶體壓力下崩潰，**C:／D:／E: 三個磁碟的 9p 通道同時斷掉**。在 VM 內查看：
   ```
   ls -la /run/desktop/mnt/host/
   d????????? ? ? ? ? c      ← stat 失敗
   d????????? ? ? ? ? d
   d????????? ? ? ? ? e
   ```
5. Docker 嘗試以 `wsl --import-in-place docker-desktop` 重建 VM，需要再預留 31.7 GB，撞上 commit limit，失敗於：
   ```
   Wsl/0x8007000e  （E_OUTOFMEMORY，「記憶體資源不足，無法完成此作業」）
   ```
   **當下實際 free RAM 有 25 GB**——不是真的沒記憶體，是預留額度打架。

### 1.2 事故的真正代價：無人知曉

| 容器 | `docker ps` 顯示 | 實際狀態 |
|---|---|---|
| `openab-estate` | **healthy** | 檔案系統全死 |
| `openab-travel-claude` | **healthy** | 檔案系統全死 |
| `openab-url-intake` | Up | 每則 URL 擷取都失敗 |

現有 healthcheck 是 `pgrep -x openab || exit 1`——**只驗程序活著，完全不碰檔案系統**。
`openab-url-intake` 則根本沒有 healthcheck（`Config.Healthcheck` 為 `null`）。

結果：**故障持續約 9 小時，最後是靠使用者在手機上看到 Discord 錯誤訊息才發現的。**
這是本規格要解決的核心問題。

### 1.3 已完成的預防措施（不在本次工作範圍，僅供理解背景）

已建立 `C:\Users\xx\.wslconfig`（ASCII、無 BOM）：

```ini
[wsl2]
memory=16GB
swap=8GB
autoMemoryReclaim=gradual
```

下次 `wsl --shutdown` 後生效。這降低了 OOM 觸發路徑的機率，**但不能保證不再發生**，所以仍需偵測與自癒。

---

## 2. 目標

建立三層防線。第一層讓故障**可見**，第二層讓故障**主動通知**，第三層讓故障**自動修復**。

---

## 3. 交付物清單

| 路徑 | 動作 | 說明 |
|---|---|---|
| `openab/docker-compose.yml` | 修改 | 12 個 bind mount 的 healthcheck 覆寫 |
| `openab/healthcheck/mount-watchdog.ps1` | 新增 | 偵測 + 告警 + 自癒主程式 |
| `openab/healthcheck/register-mount-watchdog.ps1` | 新增 | 註冊 Windows 排程工作 |
| `openab/healthcheck/README.md` | 修改 | 增補 mount-watchdog 章節 |
| `.local/infra_alert.env.example` | 新增 | 告警頻道設定範本（**範本進版控，實檔不進**） |
| `docs/mount_watchdog_spec_2026_08_27.md` | 已存在 | 本文件 |

---

## 4. 第一層：讓 healthcheck 不再說謊

### 4.1 完整掛載清單（`docker inspect` 實測，2026-08-27）

| # | 容器 | Host 來源 | 容器內路徑 |
|---|---|---|---|
| 1 | `openab-url-intake` | `D:\discord 個人助理\URLIntake` | `/vault` |
| 2 | `intake-publisher` | `D:\discord 個人助理\URLIntake` | `/vault` |
| 3 | `pdf-publisher` | `D:\discord 個人助理\TravelMemory` | `/vault` |
| 4 | `openab-estate` | `D:\discord 個人助理\EstateSpace` | `/workspace/EstateSpace` |
| 5 | `openab-travel-claude` | `D:\discord 個人助理\TravelMemory` | `/workspace/TravelMemory` |
| 6 | `openab-travel-nvidia` | `D:\discord 個人助理\TravelMemory` | `/workspace/TravelMemory` |
| 7 | `openab-credit-report` | `D:\discord 個人助理\CreditReportSpace` | `/workspace/CreditReportSpace` |
| 8 | `openab-kiro` | `D:\discord 個人助理\KiroSpace` | `/workspace/KiroSpace` |
| 9 | `openab-kiro` | `D:\discord 個人助理\TravelMemory` | `/workspace/TravelMemory` |
| 10 | `openab-nvidia-lab` | `D:\discord 個人助理\LabSpace` | `/workspace/LabSpace` |
| 11 | `openab-astruct` | `D:\discord 個人助理\AStructSpace` | `/workspace/AStructSpace` |
| 12 | `openab-astruct` | `C:\Users\xx\Desktop\tmf-strategy-lab-main\tmf-strategy-lab-main\data\forward` | `/workspace/AStructSpace/forward` |

⚠️ **第 12 條是 C: 磁碟**。9p 崩潰是全磁碟性的，C: 也會死，所以這條必須納入。

### 4.2 覆寫方式

healthcheck 烘在 image 裡（`pgrep -x openab || exit 1`），但 **compose 層可覆寫，不需要 rebuild image**。在 `docker-compose.yml` 對應服務加：

```yaml
openab-estate:
  healthcheck:
    test: ["CMD-SHELL", "pgrep -x openab >/dev/null && ls /workspace/EstateSpace >/dev/null 2>&1 || exit 1"]
    interval: 30s
    timeout: 10s
    retries: 3
```

### 4.3 硬性要求

- **保留原有的程序檢查**，不要只換成 `ls`。原本驗 `pgrep -x openab` 的服務要變成「程序活著 **且** 掛載可讀」。
- 有多個掛載的容器（`openab-kiro`、`openab-astruct`）**每個掛載都要檢查**，用 `&&` 串接。
- `timeout` 必須 ≥ 10s。**理由：9p 垂死時 `ls` 的行為是「卡住」而不是立刻報錯**，要靠 timeout 才抓得到。這點是本次事故實際觀察到的。
- `openab-url-intake`、`intake-publisher`、`pdf-publisher` 目前**沒有** healthcheck，要新增。它們不是 openab Rust 程序，程序名不同——請先用 `docker inspect <容器> --format '{{json .Config}}'` 或 `docker exec <容器> ps ax` 查出實際主程序再寫，**不要假設程序名**。
- 不要改動任何 `volumes:`、`environment:`、`env_file:`、`image:` 設定。本層只加 `healthcheck:` 區塊。

---

## 5. 第二層：偵測與告警（`mount-watchdog.ps1`）

### 5.1 兩段式探測

**Tier 1（每次都跑，便宜）**
對第 4.1 節清單中的每一條掛載，在容器內執行**真正進入掛載點**的檢查：

```
docker exec <容器> sh -c "ls <容器內路徑> >/dev/null 2>&1 && echo OK || echo FAIL"
```

⚠️ **絕對不可以只 `ls` 父目錄。** 掛載點的目錄項在容器本地檔案系統一定存在，`ls /workspace` 即使掛載已死也會成功，會給出假的 OK。本次事故中 Coordinator 第一次診斷就被這點騙過。必須 `ls` 掛載點本身。

Tier 1 全過 → 記錄 OK，結束。

**Tier 2（只在 Tier 1 有任何一條失敗時才跑，用來判斷故障層級）**

```
docker run --rm --privileged --pid=host alpine nsenter -t 1 -m -u -n -i sh -c 'ls -la /run/desktop/mnt/host/'
```

判讀：
- 輸出含 `d?????????` → **VM 層級 9p 崩潰**，`Scope = "vm"`
- 否則 → 單一容器問題，`Scope = "container"`

如果這個指令本身失敗或 daemon 無回應 → `Scope = "daemon"`。

### 5.2 告警

Discord webhook 或 bot REST 皆可，**但必須帶 `User-Agent` 標頭**：

```powershell
$ua = "DiscordBot (https://github.com/openabdev/openab, 1.0) openab-mount-watchdog"
Invoke-RestMethod -Headers @{ Authorization = "Bot $Token"; "User-Agent" = $ua } ...
```

⚠️ **少了這個標頭，Cloudflare 會回傳一個沒有 body 的 403**，看起來像權限問題但其實不是。這是先前 `claude-oauth-check.ps1` 已經踩過的坑，請直接沿用該檔既有的通知函式，不要重寫一套。

**設定來源：** `.local/infra_alert.env`（gitignored）
```
INFRA_ALERT_CHANNEL_ID=<使用者稍後提供>
INFRA_ALERT_TOKEN_VAR=DISCORD_TOKEN_NVIDIA
```
同時提供 `.local/infra_alert.env.example` 進版控。
**若 `INFRA_ALERT_CHANNEL_ID` 未設定或仍是 placeholder，腳本要正常跑完偵測、把結果寫進 log，只是跳過 Discord 發送並在 log 記一行 `[SKIP] no alert channel configured`。不可因此崩潰。**

### 5.3 告警去重

- 狀態由 OK → FAIL 時發一次
- 持續 FAIL 期間，每 60 分鐘再發一次
- FAIL → OK 時發一次「已恢復」
- **不可每次執行都發**（排程 3 分鐘一次，會洗版）

狀態存 `openab/healthcheck/.state/mount-watchdog.json`（該目錄已被 `.gitignore` 排除）。

### 5.4 排程

`register-mount-watchdog.ps1` 註冊 Windows 排程工作，名稱 `OpenAB-MountWatchdog`，每 3 分鐘一次。

⚠️ **已知坑（先前註冊 OAuth 排程時踩過）：**
- `Register-ScheduledTask` 會拒絕 `[TimeSpan]::MaxValue`（錯誤訊息 `Duration:P99999999DT23H59M59S`）→ **直接省略 `-RepetitionDuration` 參數**
- `schtasks /TR` 對含空白與中文的路徑會失敗 → 用 `Register-ScheduledTask` 搭配 `New-ScheduledTaskAction -Execute powershell.exe -Argument '-File "<路徑>"'`

---

## 6. 第三層：自癒

### 6.1 觸發條件

**只有 `Scope = "vm"` 才啟動自癒。**
- `Scope = "container"` → 只 `docker restart` 那一隻容器，然後重驗
- `Scope = "daemon"` → 只告警，不自癒（daemon 沒回應時無法安全判斷狀態）

### 6.2 自癒階梯

```
1. Discord 告警：「偵測到 VM 層級掛載故障，開始自癒」
2. wsl --shutdown
3. 輪詢 vmmemWSL 行程直到消失，上限 300 秒
   └─ 超時 → 停手，發「需要人工處理／重開機」告警，寫入狀態，結束（不再重試）
4. 殺掉殘留的 Docker Desktop 相關行程：
   "Docker Desktop", "com.docker.backend", "com.docker.build"
5. 啟動 "C:\Program Files\Docker\Docker\Docker Desktop.exe"
6. 輪詢直到新建容器能讀到掛載，上限 300 秒：
   docker run --rm -v "D:/discord 個人助理/URLIntake:/vault" alpine ls /vault
7. 重跑 Tier 1 全清單驗證，結果發 Discord
```

### 6.3 第 4 步的理由（重要，不要簡化掉）

事故當下 Coordinator 嘗試 `docker desktop restart` **失敗**：Docker Desktop 已進入失敗狀態並**彈出 modal 錯誤對話框等待人工點擊**，此時 `docker desktop start` 只會回傳 `"Docker Desktop is already running"`，CLI 完全無法操作它。

因此自癒**不可以**用 `docker desktop restart`／`docker desktop start`，必須先把行程殺乾淨再啟動全新的 exe。

⚠️ **誠實聲明：這個規避手法未經實地驗證。** 無法隨意重現一個卡死的 WSL，所以「先殺行程再重開就不會跳對話框」是根據事故當下觀察所做的推論。若對話框仍然出現，自癒會卡在第 6 步超時，此時**必須乾淨地退回告警**，不可無限重試。實作時請確保這條退路存在。

### 6.4 熔斷器

- 24 小時內最多自癒 **2 次**
- 超過 → 只告警，訊息明確寫「已達自癒上限，需要人工介入」
- 計數存在 `.state/mount-watchdog.json`

### 6.5 `wsl --shutdown` 的已知行為（實測，不要當成故障）

`wsl --shutdown` 會**長時間沒有任何輸出**，看起來像卡死，但其實在作用：
1. distro 會先終止（`wsl --list --running` 回「沒有正在執行中的發行版」）
2. `vmmemWSL` 行程還要更久才會消失（事故當下超過 10 分鐘）

所以第 3 步必須用**輪詢行程是否存在**來判斷，不可用「指令是否返回」來判斷。

---

## 7. 硬性約束

### 7.1 PowerShell 5.1 專屬（本機是 5.1，全部實測踩過）

- `Start-Process -PassThru` 不加 `-Wait` 時 `ExitCode` 會是 `$null`（`HasExited=True`）
  → 需要 exit code 時用 `System.Diagnostics.Process` + `RedirectStandardOutput/Error` + `ReadToEndAsync()` + `WaitForExit($ms)`
- `Get-Content -Raw` 讀**空檔案**回傳 `$null` 而非 `''` → `.Trim()` 會炸，要顯式 null 檢查
- 沒有 `&&`／`||`／三元運算子／`??` → 用 `; if ($?) { }`
- `Set-Content`／`Add-Content` 預設 ANSI codepage → 寫給其他工具讀的檔案要顯式 `-Encoding utf8`

### 7.2 檔案編碼

- `.ps1` 檔含中文 → 必須存成 **UTF-8 with BOM**，否則 PS 5.1 會讀成 mojibake（既有 `claude-oauth-check.ps1` 就是 BOM 版，請比照）
- `.wslconfig`、`.env` 之類給非 PowerShell 讀的 → **UTF-8 無 BOM**

### 7.3 安全與專案規則

- **絕不設定 `ANTHROPIC_API_KEY`**（會讓 Claude Code 放棄 OAuth 改走 API 計費）
- 不得把任何 token、頻道 ID 寫進版控。實際值一律放 `.local/`（已 gitignored），版控只放 `.example`
- 自癒會殺掉 Ubuntu distro 與所有容器，**這是已知且已被使用者接受的代價**，但 README 必須寫明

### 7.4 不要做的事

- 不要改 `.wslconfig`（Coordinator 已建立，內容已定案）
- 不要改任何 `config-*.toml` 的 `[agent] env` 或 token 設定
- 不要動 `openab/credit-report/`、`EstateSpace/`、`TravelMemory/` 等業務資料
- 不要為了「順手」重構 `claude-oauth-check.ps1`，只允許**複用**其中的 Discord 通知函式（可抽成共用檔）
- 不要引入新的執行期相依（不要求裝 Pester、不要求裝 Python 套件）

---

## 8. 驗收條件

實作完成後必須全部通過，並在完成報告中附上**實際輸出**（不是「應該會通過」）：

1. `docker compose config` 對修改後的 `docker-compose.yml` 解析成功，無語法錯誤
2. 套用後 `docker ps` 中 12 條掛載對應的容器在**正常狀態下**顯示 `healthy`
   （執行 `docker compose up -d` 讓 healthcheck 生效，並等待至少一個 interval）
3. `mount-watchdog.ps1 -SelfTest` 通過：以注入的假資料驗證純函式邏輯
   （狀態機、去重規則、熔斷器計數、Tier 2 判讀），**不需要真的弄壞掛載**
4. `mount-watchdog.ps1 -DryRun` 能完整跑完偵測並印出「若為真會執行的自癒步驟」，但不實際執行
5. `mount-watchdog.ps1` 正常執行一次，Tier 1 全綠，且**不發送 Discord**（因為狀態未翻轉）
6. `register-mount-watchdog.ps1 -WhatIf`（或等效的乾跑）不報錯
7. `git status` 乾淨度檢查：`.local/infra_alert.env` **不可**出現在待提交清單中

### 8.1 不可偽造驗收

若某項驗收無法在此環境完成（例如無法安全測試真正的自癒），**明確寫出哪一項沒測、為什麼、以及你用什麼替代方式取得信心**。不要用推測填充。本規格第 6.3 節已經示範了這種誠實聲明的寫法。

---

## 9. 交付格式

- 所有變更留在 worktree 內，**不要自行 commit 到 main、不要 push**
- 完成後在 `worker_done` 的 body 中列出：改了哪些檔、每項驗收的實際結果、以及任何你認為 Coordinator 應該知道的偏離或風險
