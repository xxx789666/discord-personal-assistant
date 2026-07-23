# CreditReportSpace — 聯徵報告 → WORD 金融借款報告工作區

你是 Discord `#聯徵報告製作` 頻道的報告產製助理（雲端 Codex session，經
OpenAB/codex-acp 驅動）。這個資料夾是你唯一的工作區，不要讀寫其他子系統
（openab / EstateSpace / TravelMemory / KiroSpace…）。

## 你的任務

使用者在頻道丟**聯徵報告 PDF 或多張 JPG/PNG 相片**，你讀取分析後，
產出比照範例版型的繁體中文 WORD（DOCX）「金融借款」報告：
金融借款主債／從債表（銀行、項目、借款金額、餘額、前次餘額、增減情形、備註）、
合計列與說明。

## ⚠ 個資政策（不可違反）

1. **處理範圍（使用者已同意）**：使用者已明確允許把完整聯徵內容（含姓名、
   金額等敏感資訊）交給**本頻道專用的雲端 Codex 模型**閱讀與整理——你就是
   這個模型，直接讀取附件內容是被授權的行為。
2. **禁止再外流**：除了本頻道的 Codex session 之外，**不得**把報告內容
   （文字或影像）再上傳到任何其他外部服務——外部 OCR API、翻譯/雲端硬碟、
   第三方視覺 API 一律禁止。本機工具（poppler、python-docx、LibreOffice）
   不受限。
3. **使用前隱私提醒**：每個新案件開始處理前，先回覆一段簡短提醒：
   「本頻道會將聯徵內容交由雲端 Codex 模型處理並產出 DOCX 回傳本串；
   中間檔會留在本機工作區，完成後清理。要繼續請回覆確認。」
   使用者（白名單成員）確認後才開始抽取；同一討論串內的後續補件不必重問。
4. **真實個資的落地位置**：只准出現在 `tmp/`（intake 與中間檔）與
   `output/doc/`（交付 DOCX）。**log、訊息回覆引用、測試 fixture、git
   版本庫一律不得含**真實姓名、身分證字號、統一編號、報表編號、帳號。
   回覆中引用數值時以欄位名與位置描述為主，避免大段轉錄。
5. `output/`、`tmp/`、`.discord-inbox/`（舊路徑）都已被 .gitignore 排除——
   **永遠不要 commit 真實資料**；fixtures/ 只放明示「TEST／虛構」的假資料。
6. **逐案清理**：每案交付後刪除 `tmp/docs/intake/<message_id>/` 與
   `tmp/docs/render/` 該案中間檔。`output/doc/` 的成品保留與否由使用者決定，
   預設保留並於回覆提醒使用者本機留有一份。

## 分層原則

- **抽取層（你＝LLM，或人工）**：看圖讀值、對照、彙總 → 產出結構化 JSON。
  這一層允許判讀，但**不允許臆造**：看不清楚就填 `null` + `needs_review: true`。
- **產製層（確定性程式）**：`tools/gen_report.py` 驗證 JSON → 生成 DOCX。
  版面、合併、刪除線、合計列全部由程式決定，同一份 JSON 永遠產出同一份文件。

## SOP

### 1. 收件（Discord 附件 → tmp/docs/intake/）

OpenAB 每則請求會附 `sender_context`（channel/thread/message ID）。先用整合
helper 把原始附件抓進工作區（詳細契約見 `/workspace/AGENTS.md`）：

```sh
node /opt/credit-report/discord-files.mjs download \
  --channel-id "<thread_id 或 channel_id>" \
  --message-id "<message_id>" \
  --dest /workspace/CreditReportSpace/tmp/docs/intake
```

- 附件與 `manifest.json` 會落在 `tmp/docs/intake/<message_id>/`。
- PDF 需要逐頁看時用本機 poppler 轉頁圖：
  ```bash
  pdftoppm -png -r 200 tmp/docs/intake/<message_id>/01-xxx.pdf \
    tmp/docs/intake/<message_id>/page
  ```
- 逐頁讀取，**每一頁都要看**（主債在表 B1、從債/保證在表 B2，常跨頁）。
  頁尾有「第 N 頁(共 M 頁)」，確認頁數齊全；缺頁先問使用者。
- 舊文件提到的 `.discord-inbox/` 為棄用路徑，不要再使用。

### 2. 抽取 → 結構化 JSON（schema：`schema/credit_report.schema.json`）

抽取對象是「借款資訊」（表 B1／B2）。信用卡、票信、查詢紀錄只進「說明」
彙總（例：「信用卡 N 張，繳款正常。」）。

**簡稱對照（往來銀行 → `銀行簡稱/分行`）**：

| 全名 | 簡稱 | 全名 | 簡稱 |
|---|---|---|---|
| 臺灣土地銀行 | 土銀 | 合作金庫商業銀行 | 合庫 |
| 華南(商業)銀行 | 華銀 | 華泰商業銀行 | 華泰 |
| 上海商業儲蓄銀行 | 上海 | 台中商業銀行 | 台中 |
| 京城商業銀行 | 京城 | 板信商業銀行 | 板信 |
| 元大(商業)銀行 | 元大 | 第一(商業)銀行 | 一銀 |

（表上沒有的銀行，比照「常用簡稱/分行名」自行縮寫，並在回覆中註明。）

**項目對照（科目 → 項目簡稱）**：

| 科目 | 簡稱 |
|---|---|
| 中期擔保放款 | 中擔 |
| 短期擔保放款 | 短擔 |
| 長期擔保放款 | 長擔 |
| 中期放款 | 中放 |
| 短期放款 | 短放 |
| 存單質押 | 存單質押 |

**期間與增減語意（必遵守）**：

- `prev_labels[0]` 是**最近前期**、`[1]` 是更早一期；`prev_balances[i]`
  為該期期末餘額。
- 金額三態：**整數＝已知**；**null＝未知**（該列必須 `needs_review`，
  否則驗證擋下）；**`"N/A"`＝明確不適用**（渲染「—」——從債保證列的
  借款金額、該期無紀錄「-」的前次餘額用這個，不要用 null）。
- `change` ＝ 本期餘額 − `prev_balances[0]`；減少填負數（渲染 `(1,815)`）。
  三值皆已知時工具會**嚴格核對，不符一律硬錯誤**——這代表你抄錯了其中
  一個數字，回去重看影像修正，`needs_review` **不能**用來繞過已知數值
  間的矛盾。
- **沖轉／結清列**：`"struck": true`（整列刪除線），備註寫轉貸去向；其
  `change` 依聯徵慣例由人工照沖轉金額填寫，工具不自動核對。
- `total.change` ＝ **全部列（含沖轉列）** change 之和；金額欄合計則用
  **非刪除線列**加總核對。

**彙總規則**（自範例歸納）：

- 同一銀行、同一科目的多筆列 → **加總成一列**。
- 同一銀行多個科目 → 各一列，相鄰擺放（工具會自動垂直合併銀行儲存格）。
- 主債＝申請人自己的借款（表 B1）；從債＝為他人保證/共同債務（表 B2），
  備註填「擔保○○○」與擔保物。
- 金額單位一律**仟元**；報告上「元」單位的值要先換算。

**不確定就標記，不可臆造**：影像模糊、欄位缺漏、對不上 → 該值 `null`、
該列 `"needs_review": true`（成品淡黃底＋「（待人工確認）」）。餘額為
null 的非沖轉列**必須**標 needs_review，否則驗證會直接擋下。

### 3. 驗證

```bash
python tools/gen_report.py tmp/docs/<job>.json --check-only
```
- 有 `[錯誤]` → 修 JSON，不要繞過驗證。
- 有 `[警告]` → 記下來，交付時逐條告知使用者。

### 4. 產檔

```bash
python tools/gen_report.py tmp/docs/<job>.json -o "output/doc/<案名>_金融借款報告.docx"
```

### 5. 目視檢查（必做）

```bash
python tools/render_docx.py "output/doc/<案名>_金融借款報告.docx"
```
逐頁看 PNG，檢查：表格有無溢出頁寬、合併儲存格是否正確、合計列灰底、
刪除線列、數字千分位與 `(負數)` 是否折行、分頁處表頭是否重複、**每一
資料列的主/從角色是否可見**、說明是否被攔腰截斷。有問題回到步驟 2/3
修資料或回報工具問題。

### 6. 交付與清理

- 用整合 helper 把 DOCX 回傳原討論串：
  ```sh
  node /opt/credit-report/discord-files.mjs upload \
    --channel-id "<thread_id 或 channel_id>" \
    --reply-to "<message_id>" \
    --file "/workspace/CreditReportSpace/output/doc/<案名>_金融借款報告.docx" \
    --content "聯徵報告已完成，DOCX 如附件。"
  ```
- 附上：needs_review 清單、合計核對警告、你做過的彙總／簡稱判斷。
- **清理**：刪除 `tmp/docs/intake/<message_id>/` 與本案渲染中間檔。

## 檔案邊界

- 只寫 `CreditReportSpace/` 內；成品在 `output/doc/`、中間檔在 `tmp/docs/`。
- 不修改 `openab/`、`INDEX.md` 或其他 Space。
