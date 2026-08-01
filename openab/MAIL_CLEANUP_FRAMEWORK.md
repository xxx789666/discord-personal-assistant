# 信箱清理框架（規劃中）

> 建立日期：2026-08-01
> 狀態：**Layer 1／2 可立即執行；Layer 3 被 OpenAB 版本阻塞**
> 相關：[README.md](README.md)、[cronjob 排程](#layer-3agent-監控唯讀)

---

## 1. 核心原則

**「不重要的信」有兩種判斷方式，用錯工具是這件事最常見的失敗點。**

| 判斷型態 | 定義 | 該用什麼 | 要不要 AI |
|---|---|---|---|
| **規則型** | 看寄件者、類別、標頭就能判斷（電子報、促銷、noreply） | Gmail Filter / Apps Script | **不要** |
| **語意型** | 要讀懂內文才知道重不重要（同一寄件者，這封催款、那封廣告） | Agent 出建議，人按刪除 | 要，但**不給寫入權** |

規則型佔實際垃圾信九成以上，而它**不該經過 LLM** —— 更快、更可靠、且無法被郵件內容注入操縱。

> **鐵則：會讀取外部來信的 agent，永遠不持有刪除權。**
> 任何人寄一封信給你，就是在對你的 agent 送出一段未經審查的輸入。

---

## 2. 三層架構

```
Layer 1  Gmail Filter          觸發式（信件寄達當下）   刪除權：有   不經 LLM
Layer 2  Apps Script           排程式（每日）           刪除權：有   不經 LLM
Layer 3  OpenAB Agent          排程式（cron）           刪除權：無   唯讀＋草稿
```

三層**不是替代關係，是分工**。刪除動作全部落在不經 LLM 的 Layer 1／2；
Layer 3 只做兩件 AI 才做得到的事：**語意分類簡報** 與 **誤刪監控**。

---

## 3. Layer 1：Gmail Filter（即時，無需排程）

### 特性

Filter 在**每封信寄達的瞬間**評估並執行 —— 不是每日批次。垃圾信不會在收件匣停留。

**限制：只在信件抵達那一刻評估一次，因此無法表達任何時間條件。**
`older_than:30d` 在信剛到時永遠為 false，所以「放 30 天沒讀就刪」必須交給 Layer 2。

### 建立步驟

1. Gmail 搜尋框輸入條件
2. 右側 **Show search options** → **Create filter**
3. 勾選 **Delete it**
4. ⚠️ 最後一步勾 **Also apply filter to N matching conversations** —— **不勾就不會處理存量信件**，很容易漏

### 條件範本

```
category:promotions
category:social
list:*                              所有郵件論壇／電子報（List-Unsubscribe 標頭）
from:(noreply@* OR no-reply@*)
from:(@example-spam.com)
subject:(電子報 OR 週報 OR newsletter)
```

> `Delete it` = 移到垃圾桶，**30 天後才自動永久清空** → 有反悔期，這是 Layer 3 監控能發揮作用的視窗。

### 待填：我的實際規則

| # | 條件 | 說明 | 已建立 |
|---|---|---|---|
| 1 | | | ☐ |
| 2 | | | ☐ |
| 3 | | | ☐ |

---

## 4. Layer 2：Apps Script（每日排程，處理時間條件）

僅在需要**跨時間條件**時才用。跑在自己的 Google 帳號，不需要容器、OAuth client 或 MCP。

### 腳本骨架

到 [script.google.com](https://script.google.com) 新增專案：

```javascript
function purgeJunk() {
  const queries = [
    'category:promotions older_than:30d',
    'category:social older_than:30d',
    'list:* is:unread older_than:60d',
    // 'from:(noreply@example.com) older_than:7d',
  ];
  for (const q of queries) {
    let threads;
    do {
      threads = GmailApp.search(q, 0, 100);
      threads.forEach(t => t.moveToTrash());   // 進垃圾桶，非永久刪除
    } while (threads.length === 100);
  }
}
```

### 排程設定

左側 **觸發條件** → 新增觸發條件 → 選 `purgeJunk` → 時間驅動 → 日計時器 → 選時段。

### 注意

- 用 `moveToTrash()` 而非永久刪除，保留 30 天反悔期
- `do...while` 分頁是必要的：`GmailApp.search` 單次上限 500，逐批處理避免逾時
- 首次執行會要求授權，選自己的帳號 → 進階 → 允許

---

## 5. Layer 3：Agent 監控（唯讀）

### 現況：被阻塞

OpenAB 的 Gmail 原生轉接器（`openab mcp gmail-native`）於 2026-07-25 合併進 main，
但**尚未包含在任何已發布版本**。最新 release 仍是 `openab-0.10.0-beta.2`（2026-07-23）。

- 下一版預期 `0.10.0-beta.3`；release 為純人工觸發（`workflow_dispatch`），**無可預測時程**
- 機制上確定：release PR 從 main 切，**下一版必然含 Gmail**
- 追蹤方式：GitHub repo → Watch → Custom → Releases

### 能力上限（六個工具，唯讀＋草稿）

| 工具 | 用途 |
|---|---|
| `search_threads` | Gmail 查詢語法搜尋 |
| `get_thread` / `get_message` | 讀取內容（metadata／full／minimal） |
| `list_labels` / `list_drafts` | 讀取標籤／草稿清單 |
| `create_draft` | 建立草稿，**絕不寄出**；支援 `replyToMessageId` 串接原討論串 |

Scope 僅 `gmail.readonly` + `gmail.compose`。**沒有刪除、封存、標籤寫入、寄送。**

### 兩個用途

**A. 誤刪監控（本框架的關鍵補強）**

Layer 1／2 自動刪除的最大風險是誤刪。Agent 用唯讀權限每週掃垃圾桶，在 30 天反悔期內攔截：

```toml
[[cron.jobs]]
schedule = "0 9 * * 0"              # 每週日 09:00
channel  = "<頻道ID>"
message  = "掃描 in:trash newer_than:7d，找出可能被誤刪的重要信件（非電子報、非促銷、有實際收件人對話），列出寄件者與主旨"
timezone = "Asia/Taipei"
sender_name = "MailAudit"
```

**B. 每日語意分類簡報**

```toml
[[cron.jobs]]
schedule = "0 8 * * *"
channel  = "<頻道ID>"
message  = "整理過去 24 小時收件匣，依「需回覆／帳單通知／訂閱電子報／可忽略」四類分組，每封一行摘要；對「可忽略」那組輸出一條可直接貼進 Gmail 的查詢語句"
timezone = "Asia/Taipei"
sender_name = "MailDigest"
```

> 語意型刪除走這條：agent 出查詢語句 → 你在 Gmail 貼上、全選、刪除。
> 決策權在人手上，agent 讀到的惡意內容影響不了結果。

### cron 可用性

`[[cron.jobs]]` 在 **beta.2 就已存在**（`docs/cronjob.md`），與 Gmail 無關 —— **排程骨架現在就能先跑起來**，等 adapter 到位只要換 prompt 並註冊 MCP。

欄位：`enabled` / `schedule`(5-field POSIX cron) / `channel` / `message` / `platform` / `sender_name` / `timezone`(預設 UTC，**務必設 Asia/Taipei**) / `thread_id`

### 部署坑（動手前先讀）

- `gmail-native serve` **只綁 loopback，非 loopback 綁定啟動即拒**
  → agent 在容器內，serve 必須跑在**同一個容器內**才連得到 `127.0.0.1:8850`
- serve 進程需要 `GMAIL_OAUTH_CLIENT_ID` / `GMAIL_OAUTH_CLIENT_SECRET` 做 token refresh
  → 目前所有 `config-*.toml` 的 `inherit_env` 都是空的，要一併調整
- 端點**無認證層**，host／pod 邊界即信任邊界
- `~/.openab/agent/auth.json` 內的 refresh token 等同長期憑證，家目錄備份會一起帶走

---

## 6. 安全邊界

| 層 | 觸發者 | 讀取外部內容 | 刪除權 | 可被 prompt injection |
|---|---|---|---|---|
| Layer 1 Filter | Gmail | — | ✅ | ❌ 不可能 |
| Layer 2 Apps Script | Google 排程 | — | ✅ | ❌ 不可能 |
| Layer 3 Agent | OpenAB cron | ✅ | ❌ | 有風險，但**無寫入權可被利用** |

**唯一會讀取不可信內容的一層，恰好是唯一沒有刪除權的一層。** 這是本框架的設計重點。

### 不採用的路線

第三方 `gmail.modify` MCP（[ArtyMcLabin](https://github.com/ArtyMcLabin/Gmail-MCP-Server)、
[theposch](https://github.com/theposch/gmail-mcp)、[jasonsum](https://github.com/jasonsum/gmail-mcp-server)、
[navbuildz](https://github.com/navbuildz/gmail-mcp-server)）可讓 agent 直接刪信，
但會讓「讀外部來信」與「刪信權」落在同一個 agent 上 —— OpenAB 刻意不做這件事就是這個原因。

若日後仍要走：用 MCP facade 的 `tool_filter` 白名單最小化工具，且只接**專用次要信箱**，不接主信箱。

---

## 7. 導入順序

- [ ] **Step 1** — 盤點：列出實際想清掉的信件類型與典型寄件者
- [ ] **Step 2** — Layer 1：建立 filter（記得勾「套用到現有郵件」處理存量）
- [ ] **Step 3** — 觀察一週，確認沒有誤刪；調整條件
- [ ] **Step 4** — Layer 2：若有時間條件需求才建 Apps Script
- [ ] **Step 5** — Layer 3-cron 骨架：用 beta.2 現有 cron 先跑一個測試排程
- [ ] **Step 6** — 等 `0.10.0-beta.3` → 升級 image → 設定 gmail-native → 接上監控與簡報

**Step 2 做完就已經解決九成問題。** 後續步驟是補強，不是前提。

---

## 附錄：Gmail 搜尋運算子速查

| 運算子 | 說明 |
|---|---|
| `category:promotions` / `social` / `updates` / `forums` | 分頁類別 |
| `list:*` | 郵件論壇／電子報（依 List-Unsubscribe 標頭） |
| `from:` / `to:` / `subject:` | 支援 `OR`、括號、萬用字元 |
| `older_than:30d` / `newer_than:7d` | `d`／`m`／`y`；**filter 不可用**，僅搜尋與 Apps Script |
| `after:2026/07/25` / `before:2026/08/01` | 絕對日期 |
| `is:unread` / `is:read` / `has:attachment` | 狀態 |
| `in:trash` / `in:spam` / `in:anywhere` | 位置 |
| `-` 前綴 | 排除，如 `-from:boss@company.com` |
