# Discord 個人助理 — 知識庫首頁

獨立的個人助理系統（2026-06-12 自 AIQuant 完全分離）。
用 Obsidian 開啟本資料夾即為 vault；bot 產出的所有筆記都在這裡面。

## 📂 內容地圖

### 旅遊（#travel-planner 頻道的資料）
- [TravelMemory/Trips/](TravelMemory/Trips/README.md) — **行程與查證筆記**（bot 產出）
  - 每個行程一個資料夾：`itinerary.md`（行程主檔）、`research_notes.md`（查證紀錄）、`budget.md`
- [TravelMemory/Sources/](TravelMemory/Sources/README.md) — 你餵給 bot 的旅遊資料（攻略、訂位確認、逐字稿）
- [TravelMemory/AGENTS.md](TravelMemory/AGENTS.md) — 旅遊 bot 的角色與規則

### 助理筆記
- [KiroSpace/Notes/](KiroSpace/AGENTS.md) — Kiro（#kiro-assistant）的研究筆記
- [LabSpace/Notes/](LabSpace/AGENTS.md) — NVIDIA 實驗頻道（#nvidia-lab）的產出

### 聯徵報告（#聯徵報告製作）
- `CreditReportSpace/` — PDF/圖片 intake、報告 agent 流程與 DOCX 成果
- [CREDIT_REPORT_SETUP.md](openab/CREDIT_REPORT_SETUP.md) — Discord/Codex 整合、bootstrap、附件與 DOCX 回傳

### 系統文件（openab/）
- [README.md](openab/README.md) — **stack 總覽**（服務表、頻道map、白名單、volumes、維運指令）
- [KIRO_SETUP.md](openab/KIRO_SETUP.md) — Kiro 助理（含直驅模式、AWS 重登）
- [NVIDIA_SETUP.md](openab/NVIDIA_SETUP.md) — NVIDIA bridge（含七條踩坑紀錄）
- [TRAVEL_SETUP.md](openab/TRAVEL_SETUP.md) — 旅遊系統（工作流、Claude 帳號管理）
- [STEEL_SETUP.md](openab/STEEL_SETUP.md) — Steel + SearXNG（上網基礎設施）
- [CREDIT_REPORT_SETUP.md](openab/CREDIT_REPORT_SETUP.md) — 聯徵報告 Codex/OpenAB 服務

## 🤖 頻道速查

| 頻道              | Bot                 | 用途              | 成果落地                                                    |
| --------------- | ------------------- | --------------- | ------------------------------------------------------- |
| #kiro-assistant | kiro-bridge         | 通用問答＋**旅遊查證主力** | KiroSpace/Notes/、TravelMemory/Trips/*/research_notes.md |
| #travel-planner | travel-claudebridge | 行程彙整            | TravelMemory/Trips/*/itinerary.md                       |
| #travel-planner | Nvidia-bridge       | 查證副手（免費額度）      | research_notes.md                                       |
| #nvidia-lab     | Nvidia-bridge       | 實驗、YouTube 逐字稿  | LabSpace/Notes/、Output/                                 |
| #聯徵報告製作   | 專用 Codex bot（待 bootstrap） | PDF/圖片製作聯徵報告 | CreditReportSpace/、DOCX 回傳原 thread                  |

## ⚙️ 維運

```powershell
# 啟動 / 停止整個 stack（不影響 AIQuant）
docker compose -f "D:\discord 個人助理\openab\docker-compose.yml" up -d
docker compose -f "D:\discord 個人助理\openab\docker-compose.yml" stop

# 看某隻 bot 的 log
docker logs openab-kiro --tail 30

# 聯徵服務是 opt-in profile；完成 token/channel/auth bootstrap 後才啟動
docker compose -f "D:\discord 個人助理\openab\docker-compose.yml" `
  --profile credit-report up -d openab-credit-report
```

- 機密在 `.local/`（bot tokens、channel bootstrap、NVIDIA key、Groq key）— 不要進 git
- Steel live viewer（登入態任務人工介入）：http://localhost:5173
- SearXNG 搜尋介面（人工除錯）：http://localhost:8081
- **行程自動 PDF**：`pdf-publisher` 服務監看 `Trips/*/itinerary.md`，
  變動 ≤20 秒內自動轉 PDF 存回 trip 資料夾並發到 #travel-planner
- 與 AIQuant 僅剩的依賴：base image `openab-codex:with-uv`
- 既有助理可依各 config 使用私訊；聯徵 bot 基於敏感資料政策關閉 DM，只服務明確頻道
