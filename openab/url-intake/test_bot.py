import importlib.util
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

os.environ.setdefault("DISCORD_TOKEN_NVIDIA", "test")
os.environ.setdefault("CHANNEL_ID", "1")
os.environ.setdefault("NVIDIA_API_KEY", "test")

SPEC = importlib.util.spec_from_file_location("url_intake_bot", Path(__file__).with_name("bot.py"))
BOT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BOT)


class UrlIntakeTests(unittest.TestCase):
    def test_extract_urls_deduplicates_and_strips_cjk_punctuation(self):
        text = "看 https://example.com/a。再看 https://x.com/u/status/1，還有 https://example.com/a"
        self.assertEqual(
            BOT.extract_urls(text),
            ["https://example.com/a", "https://x.com/u/status/1"],
        )

    def test_x_status_id_parses_status_urls(self):
        self.assertEqual(
            BOT.x_status_id(
                "https://x.com/jiamigou/status/2088954770136739931?s=46&t=abc"
            ),
            "2088954770136739931",
        )
        self.assertEqual(
            BOT.x_status_id("https://twitter.com/user/statuses/123"),
            "123",
        )
        self.assertIsNone(BOT.x_status_id("https://x.com/i/article/2088949838025281536"))

    def test_draftjs_to_markdown_keeps_article_body(self):
        content = {
            "blocks": [
                {"text": "開頭段落", "type": "unstyled"},
                {"text": "重點一", "type": "unordered-list-item"},
                {"text": " ", "type": "atomic"},
                {"text": "小標", "type": "header-two"},
            ]
        }
        markdown = BOT.draftjs_to_markdown(content)
        self.assertIn("開頭段落", markdown)
        self.assertIn("- 重點一", markdown)
        self.assertIn("## 小標", markdown)

    def test_fxtwitter_scrape_includes_article_blocks(self):
        payload = {
            "code": 200,
            "tweet": {
                "text": "https://x.com/i/article/1",
                "author": {"name": "作者", "screen_name": "demo"},
                "article": {
                    "title": "文章標題",
                    "preview_text": "預覽太短",
                    "content": {
                        "blocks": [
                            {"text": "這是足夠長的正文內容，用來確認會被抽出。", "type": "unstyled"},
                            {"text": "第二段也要保留。", "type": "unstyled"},
                        ]
                    },
                },
            },
        }
        response = Mock()
        response.raise_for_status.return_value = None
        response.json.return_value = payload
        with patch.object(BOT.requests, "get", return_value=response) as get:
            text = BOT.fxtwitter_scrape(
                "https://x.com/demo/status/2088954770136739931?s=46"
            )
        self.assertIn("/status/2088954770136739931", get.call_args.args[0])
        self.assertIn("文章標題", text)
        self.assertIn("這是足夠長的正文內容", text)
        self.assertIn("@demo", text)

    def test_source_text_prefers_fxtwitter_for_x_hosts(self):
        with (
            patch.object(BOT, "ensure_public_url"),
            patch.object(BOT, "fxtwitter_scrape", return_value="X" * 200) as fx,
            patch.object(BOT, "kitesurf_scrape") as kite,
            patch.object(BOT, "jina_scrape") as jina,
        ):
            kind, text = BOT.source_text("https://x.com/demo/status/1")
        self.assertEqual(kind, "x")
        self.assertEqual(text, "X" * 200)
        fx.assert_called_once()
        kite.assert_not_called()
        jina.assert_not_called()

    def test_looks_blocked_detects_cloudflare_wall(self):
        # Verbatim shape of what Kitesurf returned for techorange.com on
        # 2026-08-28: HTTP 200, success=true, 851 characters, no article.
        wall = (
            "---\ntitle: \"Attention Required! | Cloudflare\"\n---\n\nPlease "
            "enable cookies.\n\n# Sorry, you have been blocked\n\n## You are "
            "unable to access techorange.com\n\n## Why have I been "
            "blocked?\n\nThis website is using a security service to protect "
            "itself from online attacks. The action you just performed triggered "
            "the security solution. There are several actions that could trigger "
            "this block including submitting a certain word or phrase, a SQL "
            "command or malformed data.\n\n## What can I do to resolve "
            "this?\n\nYou can email the site owner to let them know you were "
            "blocked. Please include what you were doing when this page came up "
            "and the Cloudflare Ray ID found at the bottom of this "
            "page.\n\nCloudflare Ray ID: **a321e773ccae4a63** \u2022 Your IP: "
            "Click to reveal 2a06:98c0:3600::103 \u2022 Performance & security by"
            " [Cloudflare](https://www.cloudflare.com/5xx-error-landing)"
        )
        self.assertTrue(BOT.looks_blocked(wall))
        self.assertGreater(len(wall), 300)

    def test_looks_blocked_ignores_long_article_mentioning_cloudflare(self):
        article = "本文說明 Cloudflare Ray ID 的用途。" + "內容" * 3000
        self.assertFalse(BOT.looks_blocked(article))
        self.assertFalse(BOT.looks_blocked(""))

    def test_source_text_falls_through_when_kitesurf_returns_block_page(self):
        wall = (
            "# Sorry, you have been blocked\n\n"
            "## You are unable to access techorange.com\n" + "x" * 400
        )
        article = "真正的文章內容。" * 200
        with (
            patch.object(BOT, "ensure_public_url"),
            patch.object(BOT, "kitesurf_scrape", return_value=wall) as kite,
            patch.object(BOT, "jina_scrape", return_value=article) as jina,
        ):
            kind, text = BOT.source_text("https://techorange.com/2026/08/28/post/")
        kite.assert_called_once()
        jina.assert_called_once()
        self.assertEqual(kind, "webpage")
        self.assertEqual(text, article)
        self.assertNotIn("blocked", text)

    def test_parse_json_response_accepts_fence(self):
        data = BOT.parse_json_response(
            '```json\n{"title":"T","summary":"S","key_points":["K"]}\n```'
        )
        self.assertEqual(data["title"], "T")

    def test_to_zh_tw_uses_taiwan_wording(self):
        converted = BOT.to_zh_tw(
            {"summary": "软件和人工智能", "key_points": ["默认网络设置"]}
        )
        self.assertEqual(converted["summary"], "軟體和人工智慧")
        self.assertEqual(converted["key_points"], ["預設網路設定"])

    def test_kitesurf_uses_browser_run_markdown_endpoint(self):
        original_account = BOT.CLOUDFLARE_ACCOUNT_ID
        original_token = BOT.CLOUDFLARE_API_TOKEN
        BOT.CLOUDFLARE_ACCOUNT_ID = "account"
        BOT.CLOUDFLARE_API_TOKEN = "token"
        response = Mock()
        response.json.return_value = {"success": True, "result": "# Rendered"}
        response.raise_for_status.return_value = None
        try:
            with patch.object(BOT.requests, "post", return_value=response) as post:
                self.assertEqual(BOT.kitesurf_scrape("https://example.com"), "# Rendered")
        finally:
            BOT.CLOUDFLARE_ACCOUNT_ID = original_account
            BOT.CLOUDFLARE_API_TOKEN = original_token
        self.assertIn("/browser-rendering/markdown?browser=kitesurf", post.call_args.args[0])
        self.assertEqual(post.call_args.kwargs["json"]["url"], "https://example.com")

    def test_summarize_falls_back_after_gateway_timeout(self):
        original_model = BOT.NVIDIA_MODEL
        original_fallback = BOT.NVIDIA_FALLBACK_MODEL
        original_final_fallback = BOT.NVIDIA_FINAL_FALLBACK_MODEL
        BOT.NVIDIA_MODEL = "primary/model"
        BOT.NVIDIA_FALLBACK_MODEL = "nvidia/nemotron-3-nano-30b-a3b"
        BOT.NVIDIA_FINAL_FALLBACK_MODEL = "nvidia/nemotron-3-super-120b-a12b"
        gateway_timeout = Mock(status_code=504)
        gateway_timeout.raise_for_status.side_effect = BOT.requests.exceptions.HTTPError(
            "gateway timeout", response=gateway_timeout
        )
        fallback_response = Mock(status_code=200)
        fallback_response.raise_for_status.return_value = None
        fallback_response.json.return_value = {
            "choices": [
                {
                    "message": {
                        "content": '{"title":"T","summary":"S","key_points":["K"]}'
                    }
                }
            ]
        }
        try:
            with patch.object(
                BOT.requests, "post", side_effect=[gateway_timeout, fallback_response]
            ) as post:
                result = BOT.summarize("https://example.com", "webpage", "source", False)
        finally:
            BOT.NVIDIA_MODEL = original_model
            BOT.NVIDIA_FALLBACK_MODEL = original_fallback
            BOT.NVIDIA_FINAL_FALLBACK_MODEL = original_final_fallback
        self.assertEqual(result["title"], "T")
        self.assertEqual(post.call_count, 2)
        self.assertEqual(post.call_args_list[0].kwargs["json"]["model"], "primary/model")
        self.assertEqual(
            post.call_args_list[1].kwargs["json"]["model"],
            "nvidia/nemotron-3-nano-30b-a3b",
        )

    def test_summarize_uses_source_only_fallback_when_all_models_fail(self):
        original_model = BOT.NVIDIA_MODEL
        original_fallback = BOT.NVIDIA_FALLBACK_MODEL
        original_final_fallback = BOT.NVIDIA_FINAL_FALLBACK_MODEL
        BOT.NVIDIA_MODEL = "primary/model"
        BOT.NVIDIA_FALLBACK_MODEL = "fallback/model"
        BOT.NVIDIA_FINAL_FALLBACK_MODEL = "final/model"
        failures = []
        for _ in range(3):
            response = Mock(status_code=504)
            response.raise_for_status.side_effect = BOT.requests.exceptions.HTTPError(
                "gateway timeout", response=response
            )
            failures.append(response)
        try:
            with patch.object(BOT.requests, "post", side_effect=failures) as post:
                result = BOT.summarize(
                    "https://example.com",
                    "webpage",
                    "# 測試文章標題\n這是一段足夠長的來源內容，用來確認模型全數失敗時仍能建立安全節錄。",
                    False,
                )
        finally:
            BOT.NVIDIA_MODEL = original_model
            BOT.NVIDIA_FALLBACK_MODEL = original_fallback
            BOT.NVIDIA_FINAL_FALLBACK_MODEL = original_final_fallback
        self.assertTrue(result["_source_only"])
        self.assertEqual(post.call_count, 3)
        self.assertIn("所有摘要模型暫時不可用", result["caveats"][0])

    def test_write_note_never_overwrites(self):
        meta = {"title": "測試", "summary": "摘要", "key_points": ["一"]}
        with tempfile.TemporaryDirectory() as temp:
            original = BOT.VAULT
            BOT.VAULT = Path(temp)
            try:
                first = BOT.write_note("https://example.com", "webpage", meta, "tester", False)
                second = BOT.write_note("https://example.com", "webpage", meta, "tester", False)
            finally:
                BOT.VAULT = original
        self.assertNotEqual(first.name, second.name)


if __name__ == "__main__":
    unittest.main()
