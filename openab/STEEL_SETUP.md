# STEEL_SETUP — Steel Browser + SearXNG（上網基礎設施）

> 現況文件，2026-06-13 更新。**已部署運行中**。總覽見 README.md。

## 現況

```
compose 網路（discord-assistant_default）
   ├── steel-api   讀網頁：所有 agent 的 scrape/截圖/PDF/登入態 session
   │     127.0.0.1:3000（REST）、127.0.0.1:9223（CDP）
   │     容器內呼叫：http://steel-api:3000
   ├── steel-ui    live viewer（人工介入登入/驗證碼）→ http://localhost:5173
   └── searxng     搜尋 JSON API → 容器內 http://searxng:8080；
         人工除錯 http://localhost:8081；設定 searxng-settings.yml（formats+json）
```

**分工原則：SearXNG 管「找連結」，Steel 管「讀內容」。**
搜尋引擎結果頁（Google/DuckDuckGo）會對 headless 丟 CAPTCHA — 禁止用
Steel 抓 SERP（agent 規則已寫進各工作區 WebAccess.md / SKILL.md）。

**SECURITY**：三個 host port 全部僅綁 127.0.0.1 — 禁止改 0.0.0.0、禁止
ngrok/frp 轉發（同全域 9222/3456 政策）。`/v1/sessions` 背後是可任意
瀏覽的真 Chrome，外露＝開放代理。

## Agent 怎麼用

- nvidia 容器：`uv run tools/web.py search|scrape|screenshot|pdf|session ...`
- kiro 容器：curl 直打（`.kiro/skills/steel-browser/SKILL.md` 有 cookbook）
- pdf-publisher：內部 HTTP 餵 HTML 給 `/v1/pdf`（Steel 不收 data: URL）
- API 文件：服務本身 `http://localhost:3000/documentation`

## 登入態任務（人工介入流程）

1. agent 建 session（`POST /v1/sessions`，self-host 一次一個）
2. 你開 **http://localhost:5173** → live viewer 直接操作畫面完成登入/驗證碼
3. 回 Discord 告訴 agent 繼續；結束 `POST /v1/sessions/release`
4. cookies 存 `aiquant_steel_cache` volume — 登一次後續通用

## ⚠ 進行中的 workaround：SKIP_FINGERPRINT_INJECTION

上游 bug（steel-dev/steel-browser #294/#295/#302：fingerprint-generator
缺 Chrome 146@1920x1080 樣本）讓 Chrome 啟動全滅，compose 已設
`SKIP_FINGERPRINT_INJECTION=true` 繞過。代價：反偵測層停用 →
SERP 被擋（已用 SearXNG 補）、Cloudflare 嚴格站可能擋。
**上游修復後**：移除該環境變數 → pull 新 image → 換 digest →
`up -d steel-api` → log 無 FINGERPRINT 錯誤即成功，屆時可評估拿掉
SearXNG（不建議 — 它本來就比抓 SERP 乾淨）。

## 重建步驟

```powershell
docker compose -f "D:\discord 個人助理\openab\docker-compose.yml" up -d steel-api steel-ui searxng
Invoke-RestMethod http://localhost:3000/v1/health    # {"status":"ok"}
Invoke-WebRequest "http://localhost:8081/search?q=test&format=json" -UseBasicParsing  # 200
```

CJK 字型已驗證內建（中/韓文 PDF 渲染正常），無需額外安裝。

## 故障排查

| 症狀 | 看哪裡 |
| --- | --- |
| API 500「Browser instance not initialized」| `docker logs steel-api`：FINGERPRINT 錯誤 → workaround 環境變數被拿掉了 |
| scrape 卡住/被擋 | 目標站擋無反偵測的 headless（見 workaround 段）|
| 「Navigating frame was detached」| 該站重導向把 frame 弄掉了 — 換 URL（如 duckduckgo→html.duckduckgo）或本來就不該抓 |
| searxng 無結果/錯誤 | `docker logs searxng`；上游引擎偶發限流，重試或換關鍵字 |
| 開新 session 報錯 | 一次一個：先 `POST /v1/sessions/release` |
| 登入態消失 | aiquant_steel_cache 被清 → 重新人工登入 |
