# TRAVEL_SETUP — #travel-planner 旅遊規劃系統

> 現況文件，2026-06-13 更新。**已部署運行中**，釜山行程已完整跑通一輪。
> 總覽見 README.md。

## 現況

```
Discord #travel-planner（1514819240631206072）＋ 私訊（免 @）
   ├── nvidia-bridge        → openab-travel-nvidia → qwen → NIM（查證副手）
   ├── travel-claudebridge  → openab-travel-claude → claude-agent-acp（行程彙整）
   │       帳號：X011training@gmail.com（Pro，獨立）— OAuth 在
   │       volume assistant_travelclaude_state，與主 Max 帳號完全隔離
   └── pdf-publisher        → itinerary.md 變動 ≤20 秒自動轉 PDF 發到本頻道
            三者共用 D:\discord 個人助理\TravelMemory\ vault
            （Kiro 也掛載此 vault — 旅遊查證主力，見 KIRO_SETUP.md）
```

## 實際工作流（已驗證：busan-2026）

1. **查證**：DM kiro-bridge「查 XXX 的價格/營業時間」→ 它自動寫
   `Trips/<slug>/research_notes.md`（來源 URL、查證日期、快照價標註）
2. **彙整**：DM travel-claudebridge「讀 research_notes 排 N 天行程」→
   產出 `Trips/<slug>/itinerary.md`（摘要＋Pass 策略＋未解決事項
   checklist＋每日表格），並抽查關鍵事實、不一致標記待確認
3. **PDF**：pdf-publisher 自動把 itinerary 轉 PDF 存回 vault ＋ 發頻道
4. **餵資料**：攻略/訂位確認丟 `Sources/<目的地>\`；YouTube 連結直接
   丟給 Kiro（會轉逐字稿）；vault 規則＝Sources 裡的事實優先，不被
   網路搜尋覆蓋
5. thread 內後續對話免 @；行程修改會觸發 PDF 重發（hash 比對，改了才發）

角色與格式規範：`TravelMemory/AGENTS.md`（CLAUDE.md / QWEN.md 轉指過去）。

## Claude 帳號管理

- 換帳號 / volume 被清後重登：
  ```powershell
  docker exec -it openab-travel-claude claude
  # → 選 Claude account with subscription → 無痕視窗開 URL → 登入目標帳號 → 貼代碼 → /exit
  docker compose -f "D:\discord 個人助理\openab\docker-compose.yml" restart openab-travel-claude
  ```
- ⚠ **絕不設 ANTHROPIC_API_KEY**（Claude Code 會棄 OAuth 改走 API 計費）。
- token 自動 refresh，登一次即可。

## 雙 bot 接力（可選，未啟用）

兩份 config 各有註解掉的 `allow_bot_messages = "mentions"` +
`trusted_bot_ids` — 啟用後 Claude 可在回覆中直接 @nvidia-bridge 委託查證
（上游 max_bot_turns=5 防迴圈）。目前用檔案協作（research_notes）已夠順。

## 故障排查

| 症狀 | 看哪裡 |
| --- | --- |
| claude 回 auth 錯誤 | 重跑上方登入流程（volume assistant_travelclaude_state）|
| 「vault 是空的」 | 查證那步沒做（Kiro 還沒寫 research_notes）— 不是 bug |
| nvidia 查證錯誤 | NVIDIA_SETUP.md 排查表 |
| PDF 沒發 | `docker logs pdf-publisher`；Steel 健康度（STEEL_SETUP.md）|
| Bash 暫時無法使用（claude 工具列）| Claude Code 內部 shell 偶發抽風，會自動用 Find 替代；常態出現再排查 |
