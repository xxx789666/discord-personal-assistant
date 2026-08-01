# Discord 個人助理 — 知識庫首頁

獨立的個人助理系統（2026-06-12 自 AIQuant 完全分離）。
用 Obsidian 開啟本資料夾即為 vault；bot 產出的所有筆記都在這裡面。

> **系統、服務、頻道、維運指令 → [openab/README.md](openab/README.md)**
> 那份是 stack 的唯一真相來源（11 個 services、頻道對照、機密位置、volumes）。
> 本頁只回答一件事：**筆記在哪。**

## 📂 內容地圖

### 旅遊 — `TravelMemory/`　#travel-planner
- [Trips/](TravelMemory/Trips/README.md) — 行程與查證筆記（bot 產出）
  每個行程一資料夾：`itinerary.md`（主檔，變動自動轉 PDF）、`research_notes.md`、`budget.md`
- [Sources/](TravelMemory/Sources/README.md) — 你餵給 bot 的資料（攻略、訂位確認、逐字稿）
- [AGENTS.md](TravelMemory/AGENTS.md) — 旅遊 bot 的角色與規則

### Kiro 助理 — `KiroSpace/`　#kiro-assistant
- [AGENTS.md](KiroSpace/AGENTS.md) — 角色與可寫路徑規則
- `Notes/`、`Output/` — 長篇成果落地處（**bot 首次寫入時才建立**）
- 旅遊查證成果不寫這裡，一律寫進 `TravelMemory/Trips/<slug>/research_notes.md`

### NVIDIA 實驗 — `LabSpace/`　#nvidia-lab
- [AGENTS.md](LabSpace/AGENTS.md) — 角色規則
- [WebAccess.md](LabSpace/WebAccess.md) — 上網 + YouTube 逐字稿 cookbook
- `Notes/`、`Output/` — 同上，首次寫入時建立

### 不動產估價 — `EstateSpace/`　#不動產估價
- [AGENTS.md](EstateSpace/AGENTS.md) — 角色規則（標示部禁自動化，由使用者人工貼）
- [Output/](EstateSpace/Output/README.md) — 估價報告與成交比價產出

### 夜盤閘門法 — `AStructSpace/`　#a-struct
- [AGENTS.md](AStructSpace/AGENTS.md) — 審核規則
- `forward/` — 轉發區

### 聯徵報告 — `CreditReportSpace/`　#聯徵報告製作
- [README.md](CreditReportSpace/README.md) — PDF/圖片 intake、報告流程、DOCX 產出
- `聯徵報告範例/` — 人工整理的範例與流程說明（WORD 報告、製作流程）

---

機密在 `.local/`（bot tokens、channel bootstrap、API keys）— 不進 git。
