# Discord / OpenAB integration contract

This parent file defines the Discord transport boundary. Codex must also load
the nearer `/workspace/CreditReportSpace/AGENTS.md`; its classification,
extraction, validation, rendering, and output rules govern report work. Running
the helper under `/opt/credit-report` is the one explicit exception to the inner
file's CreditReportSpace-only boundary.

## 案件模型：一討論串＝一份報告（逐次累積）

一個 Discord 討論串就是一份徵信報告案件。使用者會**分多則訊息、每則丟一種資料**
（聯徵憑證 / 財報損益 / 身分證…）。每收到一則，就辨識、抽取、**累積**進案件工作區，
重新產出**目前累積到的整份 DOCX** 回傳本串。**陸 金融借款一定從聯徵 PDF 產生**，
其他段落是在外面加上，不取代陸段。

案件工作區：`/workspace/CreditReportSpace/tmp/docs/cases/<thread_id>/`
- `intake/`  ——原始附件（每則訊息一個 `<message_id>/` 子夾）
- `sections/`——各段結構化 JSON（累積：`luduan.json`、`income.json`、
  `guarantor.json`…）
- `<thread_id>_徵信報告.docx`——最新整份成品

`<thread_id>` 為案號；同一討論串的後續補件都併入同一案件。

## Mandatory intake（收件路由）

OpenAB 每則請求附 `<sender_context>`（channel/thread/message ID）。視為路由
metadata，非報告內容。OpenAB 可能省略 `message_id`，解析順序：

1. 有 `message_id`：用之；來源頻道 ID 用 `thread_id`（有則），否則 `channel_id`。
2. 無 `message_id` 但有 `thread_id`：討論串 snowflake 等於其起始訊息 snowflake，
   用 `thread_id` 當 message ID、父 `channel_id` 當來源頻道。
3. 兩者皆無：請使用者在建立的討論串回覆確認，後續 sender context 會帶
   `thread_id`，再套步驟 2。

步驟 2 fallback 已對本頻道 live 驗證。不要臆測其他 message ID、不搜尋任意頻道歷史。

**補件抓取（latest 模式）**：使用者常在既有討論串補丟附件，而 sender_context 缺
`message_id`、步驟 2 又可能 404（起始訊息已刪）。此時（或使用者說「重抓」時）改用：

```sh
node /opt/credit-report/discord-files.mjs download \
  --channel-id "<thread_id>" --message-id latest \
  --dest /workspace/CreditReportSpace/tmp/docs/cases/<thread_id>/intake
```

helper 只在**該討論串最近 20 則**內取「最新一則由真人發、含附件」的訊息（跳過 bot
自己的 DOCX 回傳），下載後 manifest 的 `message_id` 即實際訊息。注意：**PDF 附件不會
內嵌進你的可視上下文（只有圖片會）**——訊息看似純文字但可能帶著 PDF，收到「密碼」
「聯徵」等文字卻沒看到附件時，先跑一次 latest 下載確認。

### 收件下載到案件 intake

```sh
node /opt/credit-report/discord-files.mjs download \
  --channel-id "<來源頻道或討論串 ID>" \
  --message-id "<message_id>" \
  --dest /workspace/CreditReportSpace/tmp/docs/cases/<thread_id>/intake
```

附件與 `manifest.json` 落在 `cases/<thread_id>/intake/<message_id>/`。允許 PDF／
圖片（含**加密聯徵 PDF**，開頭仍為 `%PDF-` 故通過 magic 檢查）。不要直接用附件
URL、不要尋找或印出 bot token、不處理被拒的可執行／壓縮格式。helper 只透過 root
所屬的窄本機 broker 連 Discord；Codex 程序刻意不持有 Discord token。

## Mandatory user-facing status notices（清楚、可行動）

OpenAB 會把一般 assistant text 編輯在同一則串流佔位訊息；那不是可靠的新訊息通知。
因此，使用者確認隱私提醒後，每次收到一批新附件並開始處理時，必須先用 helper 發一則
**真正的新 Discord 訊息**：

```sh
node /opt/credit-report/discord-files.mjs notify \
  --channel-id "<thread_id 或 channel_id>" \
  --reply-to "<message_id>" \
  --content "⏳ 已開始處理｜已收到你的附件，正在辨識並整理到正確段落。你目前不需操作；完成後會在本串附上新版 DOCX。"
```

通知必須讓非技術使用者立刻看懂三件事：**收到什麼、正在更新哪一段、現在是否需要
使用者操作**。已辨識來源時，把「附件」與「正確段落」換成具體但不含個資的描述，
例如：「已收到 1 份聯徵 PDF，正在更新『陸、金融借款』」。

- 正常處理：`⏳ 已開始處理｜…你目前不需操作；完成後會…`
- 處理超過 2 分鐘：至多再發一則 `🔄 處理中｜已完成…，正在…；你目前不需操作。`
- 缺件／看不清／解密失敗而無法繼續：立即發
  `⚠️ 需要你補資料｜<缺什麼與影響>。請<明確動作>；收到後我會繼續。`
- 完成：不要另發 notify；用 DOCX upload 的交付訊息一次說清楚結果與待辦。

不要把路徑、命令、工具名稱、JSON/schema、權限修復或逐頁判讀過程寫給使用者；不要只說
「我會處理」「正在確認」而沒有對象、階段與是否需要操作。相同階段只通知一次，避免洗版。
若 notify 失敗，繼續安全的本機處理，但最終回覆必須註明「進度通知送出失敗」。

## 產製（詳規則見內層 AGENTS）

讀內層 `/workspace/CreditReportSpace/AGENTS.md`，依其規則：**分類每個新檔 → 聯徵
用身分證後 6 碼解密 → 各段判讀抽取 → 寫／更新 `sections/*.json` → 產出整份**。
一次性產出整份骨架＋已填段落：

```sh
python tools/gen_full_report.py --case tmp/docs/cases/<thread_id>
```

工具會清點 intake、印 v1 段落覆蓋與 needs_review／缺件清單，並把整份 DOCX 寫到
`cases/<thread_id>/<thread_id>_徵信報告.docx`。`sections/` 尚空（首次只收到部分料）
時工具只清點、不產檔——照實回覆「已收到 X，尚缺 Y」，不要硬產空檔。

依內層規則做必要的目視檢查（`tools/render_docx.py`）。驗證失敗或該檢查的頁面未看，
不得上傳。

## Mandatory DOCX delivery（每次累積後回傳最新整份）

產出並（該檢查時）檢查後，把**最新整份 DOCX** 上傳原討論串
（`thread_id`，退回 `channel_id`）：

```sh
node /opt/credit-report/discord-files.mjs upload \
  --channel-id "<目標頻道或討論串 ID>" \
  --reply-to "<message_id>" \
  --file "/workspace/CreditReportSpace/tmp/docs/cases/<thread_id>/<thread_id>_徵信報告.docx" \
  --content "已更新徵信報告（目前累積），DOCX 如附件；尚缺項見說明。"
```

只接受 workspace 下、`.docx` 副檔的檔。回覆務必附上：本次新填哪段、needs_review
與缺件清單、你做過的判讀（分類歸屬、彙總、負責人排序等）。若收件、抽取、產出或
上傳失敗，於文字回覆說明失敗，不得宣稱完成。

## 清理

案件**交付完成**（使用者確認整份齊全）或終止不再重試時，刪除該案件工作區：

```sh
node /opt/credit-report/discord-files.mjs clean \
  --message-id "<message_id>" \
  --dest /workspace/CreditReportSpace/tmp/docs/cases/<thread_id>/intake
```

逐次累積期間**不要**在每則訊息後清掉 intake（會刪掉前面累積的料）。解密後的明文
聯徵、身分證影像、真值 JSON 只落 `tmp/`，永不進 git、不外傳。整案清理時一併移除
`cases/<thread_id>/` 全樹。切勿用 `rm -rf`；helper 會驗 snowflake、workspace 邊界、
目錄型別與 symlink-free 樹。
