# CreditReportSpace — 金融借款 WORD 報告產製工具

把聯徵報告（LLM／人工抽取後的結構化 JSON）轉成比照範例版型的繁中 DOCX
「金融借款」報告。抽取層與產製層分離：本工具**只做確定性產製**，不做 OCR。
頻道 agent 的完整工作流程見 [AGENTS.md](AGENTS.md)。

## 隱私模型（重要）

- **使用者已同意**：完整聯徵內容（含姓名與金額）由 `#聯徵報告製作` 頻道
  專用的**雲端 Codex 模型**讀取與整理；模型推論**不是**全程本機。
- **禁止的行為**是把內容再上傳到任何**其他**外部服務（外部 OCR/視覺 API、
  雲端硬碟、第三方工具）。本機工具（poppler、python-docx、LibreOffice）
  不受限。
- 每案開始前 agent 會發**隱私提醒**並取得使用者確認（見 AGENTS.md §個資政策）。
- 真實個資只落在 `tmp/`（intake/中間檔，逐案清理）與 `output/doc/`（交付
  成品）；兩者連同舊版 `.discord-inbox/` 都被 .gitignore 排除，永不進 git。
  fixtures/ 僅存明示「TEST／虛構」的假資料，並有 PII lint 測試把關。

## 目錄結構

```
CreditReportSpace/
├── AGENTS.md                  # 頻道 agent 工作流（SOP、個資政策、對照表）
├── schema/
│   └── credit_report.schema.json   # 結構化輸入 JSON Schema（含期間/增減語意）
├── tools/
│   ├── gen_report.py          # CLI：JSON 驗證 + 產 DOCX（原子寫入）
│   ├── render_docx.py         # CLI：DOCX → PDF → 每頁 PNG（目視檢查）
│   └── credit_report/         # 套件：model.py（驗證）、docx_builder.py（版型）
├── fixtures/
│   └── sample_report.json     # 去識別化虛構測試輸入（明示 TEST 標記）
├── tests/                     # pytest：驗證/合計/DOCX 結構/CLI/schema parity/PII lint/長表
├── requirements.txt           # 鎖定執行依賴（python-docx==1.2.0）
├── requirements-dev.txt       # 鎖定測試依賴（pytest、jsonschema）
├── output/doc/                # 正式產出（gitignored）
└── tmp/docs/                  # 中間檔：intake/<message_id>/、render/（gitignored）
```

## 依賴（鎖定版本）

- Python 3.10+：
  ```bash
  pip install -r requirements.txt        # 執行：python-docx==1.2.0
  pip install -r requirements-dev.txt    # 測試：pytest==9.0.2、jsonschema==4.26.0
  ```
- 目視檢查另需本機 **LibreOffice**（`soffice`）與 **Poppler**（`pdftoppm`）：
  ```powershell
  winget install TheDocumentFoundation.LibreOffice
  ```
- 字型：報告用「標楷體」（Windows 內建 DFKai-SB）。

## 使用

```bash
# 只驗證（結構錯誤 exit 1；合計不符、待確認列印出警告）
python tools/gen_report.py fixtures/sample_report.json --check-only

# 產檔（預設 output/doc/<輸入檔名>.docx；暫存檔+原子替換，不留半成品）
python tools/gen_report.py fixtures/sample_report.json -o output/doc/示範報告.docx

# 渲染每頁 PNG 到 tmp/docs/render/<檔名>/，供目視檢查
python tools/render_docx.py output/doc/示範報告.docx
```

exit code：`0` 成功（可能帶警告）、`1` 驗證錯誤、`2` 輸入／參數錯誤、
`3` 產檔失敗（檔案系統或 DOCX 生成內部錯誤，均為可控訊息、無 traceback）。

## 輸入格式重點（詳見 schema）

- 金額一律**仟元、整數**；三態語意：**整數＝已知**、**null＝未知**（該列
  必須 `"needs_review": true`，適用 balance/loan_amount/change/prev_balances
  元素，否則驗證直接擋下）、**`"N/A"`＝明確不適用**（渲染「—」，如從債
  保證列的借款金額、該期無紀錄的前次餘額；balance 不接受 N/A）。可省略的
  結構欄位（total/notes/prev_balances 整欄）**用省略表達，不要填 null**。
  **嚴禁臆造數值。**
- `balance` 一律是聯徵表 B1／B2 的**表列原值**，不得先扣掉資料日期當月
  （印表時點）的異動；異動只寫進 `note`，合計列與說明段落引用的餘額必須
  與表列原值一致。詳見 AGENTS.md〈期間與增減語意〉。
- `notes` 走固定句型（主債餘額 → 從債餘額 → 信用卡 → 資料來源），只寫結論
  不寫推導過程；信用卡張數只計有效卡，無負面紀錄就不列該條。
  詳見 AGENTS.md〈說明段落撰寫規範〉。
- `layout: "simple"`＝6 欄（公司表）；`"extended"`＝9 欄（含兩期前次餘額
  與增減情形，`prev_labels[0]` 為最近前期）。schema 以條件式強制：extended
  必有 `prev_labels`；simple 禁止 `prev_labels`/`prev_balances`/`change`。
- **增減語意**：`change` ＝ 本期餘額 − `prev_balances[0]`。三值皆為已知
  整數→嚴格核對，**不符一律硬錯誤，needs_review 不得繞過**；無法推導
  （有 null/N/A）而 change 有值→該列須 needs_review，否則警告。
  `"struck": true` 沖轉列不自動核對（人工照聯徵慣例填），渲染整列刪除線。
- 合計核對：金額欄＝**非刪除線列**加總；`total.change`＝**全列（含沖轉）**
  加總；不符出警告不擋產檔，由人工裁決。
- 個資防呆：輸入 JSON 出現 `身分證號`、`統一編號`、`報表編號`、`帳號`
  等欄位名會被直接擋下。

## 測試

```bash
python -m pytest tests -q
```

涵蓋：驗證層錯誤輸入、合計/增減核對、DOCX 結構（合併、刪除線、合計列）、
CLI 錯誤路徑與原子輸出、**schema-vs-model parity**（jsonschema 與 Python
驗證器對同一批案例的接受/拒絕必須一致）、**PII lint**（掃描 fixtures/tests/
文件，禁止台灣身分證樣式、9 位以上連續數字、報表編號樣式與真實樣本之
雜湊比對命中；fixture 必須帶 TEST/虛構標記）、**42+ 列長表**結構與
（本機有 LibreOffice 時）真渲染回歸。

## 版型規則（自範例歸納，docx_builder.py 實作)

- A4 直式、窄邊界；頁首左「伍、金融借款：(仟元)」粗體 16pt、
  右「資料日期-<民國年>年M月D日」（照聯徵報表印表日，如「資料日期-115年5月29日」）。
- 每個 entity「◎名稱」＋一張格線表；主債／從債群組堆疊同一張表；相鄰同
  銀行列垂直合併銀行儲存格。
- 「主/從」欄**逐資料列重複**、不做垂直合併——合併儲存格跨頁時續頁會
  整段空白，逐列標示保證任何分頁位置每一列的角色都可見（有逐頁 PDF
  文字斷言的渲染回歸測試把關）。
- 合計列前三欄水平合併「合計」、整列灰底粗體。
- 數字欄設 `w:noWrap`，「(10,700)」等括號金額不會折行。
- 表頭列跨頁重複（tblHeader）、資料列不跨頁截斷（cantSplit）、
  說明區塊 keep-with-next 不被分頁攔腰截斷。
- 字級：simple 12pt、extended 10pt（9 欄塞得下 A4 的實測值）。

## 已知限制

- 目視檢查靠 LibreOffice 渲染，與 MS Word 的分頁點可能有 1-2 行誤差；
  交付前建議用 Word 開一次確認分頁。
- 沖轉（刪除線）列的 change 依聯徵慣例由人工填寫，工具僅核對
  `total.change` 的全列加總，無法驗證單列沖轉金額本身。
