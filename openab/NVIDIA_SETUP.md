# NVIDIA_SETUP — NVIDIA 免費模型 bridge（qwen-code 殼）

> 現況文件，2026-06-13 更新。**已部署運行中**。總覽見 README.md。

## 現況

```
Discord（同一個 nvidia-bridge bot 應用、同一個 token，allowed_channels 互斥）
   ├── #nvidia-lab（1514819234448933117）→ openab-nvidia-lab → 工作區 LabSpace\
   └── #travel-planner（1514819240631206072）→ openab-travel-nvidia → TravelMemory\（查證副手）
         兩容器：image openab-nvidia:qwen（Dockerfile.nvidia）
         殼：qwen --acp（qwen-code 0.17.x，gemini-cli fork 原生 ACP）
         模型：moonshotai/kimi-k2.6 @ NVIDIA NIM（OPENAI_* env 注入，見 config）
         上網：tools/web.py（SearXNG search + Steel scrape）、tools/yt.py（uv run）
```

- **定位**：免費勞力層（摘要、逐字稿清理、抽取、實驗）。重要查證以
  Kiro 為主力（工具呼叫穩定度：Kiro > kimi）。
- pool `max_sessions = 2`（=1 時第二個討論串會靜默卡住，踩過）。
- 換模型：兩份 config 的 `OPENAI_MODEL` → `up -d --force-recreate` 兩容器。
  模型清單 `curl https://integrate.api.nvidia.com/v1/models`；候選：
  deepseek-ai/deepseek-v4-pro、z-ai/glm-5.1、minimaxai/minimax-m2.7。

## 重建步驟

```powershell
# image（改 Dockerfile.nvidia 後同樣跑這個；base 是 openab-codex:with-uv）
docker compose -f "D:\discord 個人助理\openab\docker-compose.yml" up -d --build openab-nvidia-lab openab-travel-nvidia
```

**qwen state volume 重建**（只有 volume 被清才需要，兩步都必做）：

```powershell
# 1) chown — compose 自建的 volume 是 root-owned，qwen（uid 1000）會 EACCES 即死
docker run --rm -v "aiquant_nvidialab_qwen_state:/v" alpine chown -R 1000:1000 /v
docker run --rm -v "aiquant_travelnvidia_qwen_state:/v" alpine chown -R 1000:1000 /v
# 2) 灌強制繁中檔 — qwen 首次啟動會自生「強制英文」規則，蓋過 AGENTS.md
docker cp "D:\discord 個人助理\openab\qwen-output-language.md" openab-nvidia-lab:/home/node/.qwen/output-language.md
docker cp "D:\discord 個人助理\openab\qwen-output-language.md" openab-travel-nvidia:/home/node/.qwen/output-language.md
docker exec -u root openab-nvidia-lab chown 1000:1000 /home/node/.qwen/output-language.md
docker exec -u root openab-travel-nvidia chown 1000:1000 /home/node/.qwen/output-language.md
```

## 踩坑紀錄（2026-06-12 部署日全集 — 重蹈前先讀）

1. **codex 殼不可用**：第一版用 codex-acp，但 codex CLI 2026-02 移除
   `wire_api="chat"`（openai/codex#7782），NIM 無 /v1/responses → 一啟動
   就 Connection Lost。**codex 對任何 chat-only OpenAI 相容端點都不可用**，
   qwen-code 是解法。
2. **qwen volume 權限**：見上方重建步驟 1（症狀＝Connection Lost，
   debug log 見 EACCES output-language.md）。
3. **context 爆量**：agent 連抓 9 頁完整網頁 → NIM `EngineCore` 錯誤 →
   qwen 重試 → 答案重複貼三次 + -32603。解法已內建：web.py scrape 預設
   截斷 8000 字元 + WebAccess.md「3–5 次 scrape 上限」規則。
4. **強制英文輸出**：見重建步驟 2。
5. **SERP 全滅**：Google/DuckDuckGo 對 Steel headless 丟 CAPTCHA（反偵測
   停用的代價）→ 搜尋一律走 SearXNG（web.py search）。
6. **NIM 429 限流**：免費層在密集 agentic 使用下會限流（qwen 自動退避，
   回應變極慢）。屬免費的代價；常態化就換冷門模型或改用 Kiro。
7. **幻覺數字**：查證失敗時開源模型會憑記憶編價格（釜山 pass 事件：
   編 ₩25,000，真實 ₩55,000）→ WebAccess.md 已設「禁止憑記憶報數字」鐵則。

## 排查工具

- qwen 的 agent 側 debug log：volume 內 `~/.qwen/debug/<session>.txt`
  （`docker exec openab-nvidia-lab sh -c 'ls -t /home/node/.qwen/debug/'`）
- NIM 連通性：`curl https://integrate.api.nvidia.com/v1/models`（不用 key）

| 症狀 | 原因 |
| --- | --- |
| Connection Lost | qwen 啟動即死 → 看 debug log；八成是 volume 權限或繁中檔遺失 |
| Internal Error -32603 | NIM 端錯誤（429 / context 爆）→ debug log 的 OPENAI_ERROR |
| 回英文 | output-language.md 被清 → 重建步驟 2 |
| 第二個討論串沒反應 | pool 滿（max_sessions）— 等 TTL 或調高 |
