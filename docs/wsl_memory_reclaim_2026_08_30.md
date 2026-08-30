# 2026-08-30：關閉 autoMemoryReclaim，解決 9p 週期性停滯

**變更檔案：** `C:\Users\xx\.wslconfig`（機器層級，不在 repo 內；本文為其紀錄）
**備份：** `C:\Users\xx\.wslconfig.bak-20260830`
**相關 commit：** `2207950`（watchdog 誤判修正，同日）

## 症狀

`#infra-alerts` 連續出現掛載探測 `exit 124`：

| 日期 | FAIL 次數 | 當日最慢 |
|---|---|---|
| 08-28 | 0 | 18.4s（未失敗） |
| 08-29 | 1 | 15.8s |
| 08-30（到 13:00） | 7 | 23.0s |

最慢耗時 15.7 → 17.4 → 18.3 → 19.2 → 20.9 → 23.0，單調上升。

## 這不是 8/27 那種掛載死亡

兩項證據：

1. Tier-2 進 VM 看 `/run/desktop/mnt/host/` 是乾淨的 `c d wsl wslg`，
   沒有 `d?????????`。
2. 同一輪內只有前幾條慢，約 80 秒後全部回到基線。12:58 那輪：

```
url-intake       20.94s FAIL
intake-publisher 22.98s FAIL
pdf-publisher     8.99s OK
estate            1.41s OK
travel-claude    17.05s FAIL
travel-nvidia     8.87s OK
credit-report     0.20s OK   ← 之後全部 0.17～0.20s
```

是快取冷掉，不是通道斷掉。

## 根因：沒有壓力卻在 thrash

```
VM 內   total 15991  used 1324  free 13699     ← 只用 1.3 GB
        swap  8192   used 1547                 ← 卻換出 1.5 GB
        pswpin 3,702,311  pswpout 2,714,394
        pgmajfault 8,452,153                   ← load 0.17 時仍每分鐘增加約 1700
宿主    commit 83.0 / 105.4 GB   實體可用 16.2 GB
        Memory Compression 3.41 GB
        chrome 77 個行程 合計 22 GB
```

有 13.7 GB 空閒還在 swap，代表是主動回收而非記憶體不足。
`autoMemoryReclaim=gradual`（2026-08-28 為了防 8/27 事故所加）每次回收把
page cache 清掉，其中包含 9p/drvfs 的 metadata cache，下一次 `ls` 就要
重新跨 9p 讀 → 8～23 秒 → 超過 Tier-1 的 15 秒上限。

宿主本身吃緊（Chrome 22 GB）是讓回收頻繁觸發的背景原因。

## 變更

`[experimental] autoMemoryReclaim` 由 `gradual` 改為 `disabled`。
`memory=16GB` / `swap=8GB` **維持不變**——16 GB 上限才是防 8/27
（VM 預設可吃 31.7 GB）的關鍵，而且 guest 只用 1.3 GB，上限不是問題。

**代價：** vmmemWSL 不再把快取還給宿主，working set 會往 16 GB 上限長。
宿主目前 commit 83/105 GB，若要再降壓力，Chrome 是最大的單一來源。

## 驗證（VM 汰換後即時可測）

```
boot_id      097e966b-296f-4b34-a9c6-2389198d3a47 -> 70e3592f-083b-4f6e-b93f-f888ac4d6337
uptime       2 天 3:50 -> 重新計時
pswpin       3,706,101 -> 0
pswpout      2,718,907 -> 0
buff/cache   832 MB -> 2,801 MB          快取留得住了
major fault  ~1700/min -> ~40/min        兩次取樣相隔 106 秒的實測差值
容器         27 個全部自行回復
掛載         url-intake /vault、estate、travel-claude 實測 OK
watchdog     probed=12/12 vmDegraded=False，LastTaskResult=0
```

## 兩個操作上的坑

**`wsl --list --running` 永遠不會歸零，不可當作關機完成的訊號。**
實測 6 分鐘內在 1↔2 之間震盪——Docker Desktop 偵測到 distro 消失就立刻
拉回來。要用 **boot_id 變更 + uptime 歸零** 判斷。

**`/mnt/host/wsl/docker-desktop/docker-desktop-user-distro` 又變回 0 bytes
佔位檔。** VM 汰換後幾乎必然復發，會讓 Ubuntu 整合反覆跳對話框。
修法不需重啟任何東西：

```sh
wsl -d docker-desktop -e sh -c \
  'mount --bind /docker-desktop-user-distro /mnt/host/wsl/docker-desktop/docker-desktop-user-distro'
```

**每次 `wsl --shutdown` 之後都要主動檢查這一項。**

## 待觀察

接下來 24 小時若 `#infra-alerts` 不再出現 `exit 124`，即證實診斷。
若仍出現，代表原因是宿主記憶體壓力本身而非 reclaim，屆時降低 Chrome
用量就從「建議」變成「必要」。

## 附：變更後的 .wslconfig（去除註解）

```ini
[wsl2]
memory=16GB
swap=8GB

[experimental]
autoMemoryReclaim=disabled
```
