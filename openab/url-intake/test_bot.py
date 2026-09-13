import importlib.util
import os
import re
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
            patch.object(BOT, "direct_scrape") as direct,
        ):
            kind, text = BOT.source_text("https://techorange.com/2026/08/28/post/")
        kite.assert_called_once()
        jina.assert_called_once()
        direct.assert_not_called()
        self.assertEqual(kind, "webpage")
        self.assertEqual(text, article)
        self.assertNotIn("blocked", text)

    def test_source_text_falls_through_to_direct_when_jina_fails(self):
        wall = (
            "# Sorry, you have been blocked\n\n"
            "## You are unable to access techorange.com\n" + "x" * 400
        )
        article = "真正的文章內容。" * 200
        with (
            patch.object(BOT, "ensure_public_url"),
            patch.object(BOT, "kitesurf_scrape", return_value=wall),
            patch.object(BOT, "jina_scrape", side_effect=RuntimeError("429")),
            patch.object(BOT, "direct_scrape", return_value=article) as direct,
            patch.object(BOT, "steel_scrape") as steel,
        ):
            kind, text = BOT.source_text("https://techorange.com/2026/08/28/post/")
        direct.assert_called_once()
        steel.assert_not_called()
        self.assertEqual(kind, "webpage")
        self.assertEqual(text, article)

    def _mock_http_response(
        self,
        status_code=200,
        headers=None,
        body=b"",
        encoding="utf-8",
    ):
        response = Mock()
        response.status_code = status_code
        response.is_redirect = status_code in {301, 302, 303, 307, 308}
        response.headers = headers or {"Content-Type": "text/html; charset=utf-8"}
        response.encoding = encoding
        response.apparent_encoding = encoding
        response.raise_for_status.return_value = None
        response.close = Mock()
        response.__enter__ = Mock(return_value=response)
        response.__exit__ = Mock(return_value=False)
        chunks = [body] if body else []
        response.iter_content = Mock(return_value=iter(chunks))
        return response

    def test_direct_scrape_rejects_redirect_to_private_address(self):
        public = "https://example.com/article"
        private = "http://127.0.0.1/internal"
        redirect = self._mock_http_response(
            status_code=302,
            headers={"Location": private},
        )
        get = Mock(return_value=redirect)

        def fake_addrinfo(host, *args, **kwargs):
            if host == "127.0.0.1":
                return [(2, 1, 6, "", ("127.0.0.1", 0))]
            return [(2, 1, 6, "", ("93.184.216.34", 0))]

        with (
            patch.object(BOT.requests, "get", get),
            patch.object(BOT.socket, "getaddrinfo", side_effect=fake_addrinfo),
        ):
            with self.assertRaises(ValueError) as ctx:
                BOT.direct_scrape(public)

        self.assertIn("內網", str(ctx.exception))
        get.assert_called_once()
        self.assertEqual(get.call_args.args[0], public)
        self.assertFalse(get.call_args.kwargs.get("allow_redirects", True))
        for call in get.call_args_list:
            self.assertNotIn("127.0.0.1", call.args[0])

    def test_direct_scrape_rejects_non_html_content_type(self):
        response = self._mock_http_response(
            headers={"Content-Type": "application/pdf"},
            body=b"%PDF-1.4",
        )
        with (
            patch.object(BOT, "ensure_public_url"),
            patch.object(BOT.requests, "get", return_value=response),
        ):
            with self.assertRaises(RuntimeError) as ctx:
                BOT.direct_scrape("https://example.com/file.pdf")
        self.assertIn("HTML", str(ctx.exception))
        response.iter_content.assert_not_called()

    def test_looks_like_nav_page_rejects_link_dump(self):
        nav = "\n".join(f"[分類{i}](/cat/{i})" for i in range(40))
        self.assertTrue(BOT.looks_like_nav_page(nav))
        dense_links = " ".join(
            f"[這是一段用來墊高連結文字佔比的導覽標籤{i:02d}](/p/{i})"
            for i in range(30)
        )
        self.assertTrue(BOT.looks_like_nav_page(dense_links))
        article = "真正的文章內容，這裡有足夠長的段落說明技術細節與產品能力。" * 20
        self.assertFalse(BOT.looks_like_nav_page(article))

    def test_looks_like_nav_page_allows_zero_link_short_paragraphs(self):
        # 30 x 26 CJK chars, no markdown links — the shape that used to
        # trip the short-line branch even though it cannot be a nav dump.
        line = "這是一段沒有任何超連結的中文短段落測試文章的內容啊。"
        self.assertEqual(len(line), 26)
        prose = "\n".join([line] * 30)
        self.assertNotIn("](", prose)
        self.assertFalse(BOT.looks_like_nav_page(prose))

    def test_direct_scrape_rejects_nav_like_extraction(self):
        html = self._mock_http_response(body=b"<html><body>nav</body></html>")
        nav = "\n".join(f"[分類{i}](/cat/{i})" for i in range(40))
        with (
            patch.object(BOT, "ensure_public_url"),
            patch.object(BOT.requests, "get", return_value=html),
            patch.object(BOT.trafilatura, "extract", return_value=nav),
        ):
            with self.assertRaises(RuntimeError) as ctx:
                BOT.direct_scrape("https://example.com/")
        self.assertRegex(str(ctx.exception), "導覽|內文")

    def test_direct_scrape_accepts_zero_link_short_paragraph_article(self):
        line = "這是一段沒有任何超連結的中文短段落測試文章的內容啊。"
        prose = "\n".join([line] * 30)
        html = self._mock_http_response(body=b"<html><body>article</body></html>")
        with (
            patch.object(BOT, "ensure_public_url"),
            patch.object(BOT.requests, "get", return_value=html),
            patch.object(BOT.trafilatura, "extract", return_value=prose),
        ):
            text = BOT.direct_scrape("https://example.com/essay")
        self.assertEqual(text, prose)
        self.assertIn("沒有任何超連結", text)
        self.assertNotIn("](", text)

    def _stream_response(self, body: bytes, content_type: str):
        """A real requests.Response so header encoding matches production."""
        from io import BytesIO

        from requests import Response
        from requests.utils import get_encoding_from_headers
        from urllib3.response import HTTPResponse

        raw = HTTPResponse(
            body=BytesIO(body),
            headers={"Content-Type": content_type},
            status=200,
            preload_content=False,
            decode_content=False,
        )
        response = Response()
        response.status_code = 200
        response.headers["Content-Type"] = content_type
        response.encoding = get_encoding_from_headers(response.headers)
        response.raw = raw
        response.url = "https://example.com/zh"
        response.reason = "OK"
        return response

    def test_direct_scrape_extracts_utf8_html_without_charset(self):
        chinese = (
            "中文內容測試，這是一段夠長的正文用來確認沒有 charset 的 "
            "text/html 仍能正確抽出漢字，而不是被當成 ISO-8859-1。"
        )
        html = (
            "<!DOCTYPE html><html lang='zh-Hant'><head>"
            "<meta charset='utf-8'><title>編碼測試文章</title></head>"
            f"<body><article><h1>編碼測試文章</h1><p>{chinese}</p>"
            "<p>第二段同樣是中文，避免抽取器因為內容太短而放棄。</p>"
            "</article></body></html>"
        ).encode("utf-8")
        response = self._stream_response(html, "text/html")
        self.assertEqual(response.encoding, "ISO-8859-1")
        with (
            patch.object(BOT, "ensure_public_url"),
            patch.object(BOT.requests, "get", return_value=response),
        ):
            text = BOT.direct_scrape("https://example.com/zh")
        self.assertIn("中文內容測試", text)
        self.assertIn("編碼測試", text)
        self.assertNotIn("ä¸", text)

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
        BOT.NVIDIA_FALLBACK_MODEL = "nvidia/nemotron-3.5-lightning-30b-a3b"
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
            "nvidia/nemotron-3.5-lightning-30b-a3b",
        )
        # The 3.5 series id reads "nemotron-3.5-", so a "nvidia/nemotron-3-"
        # prefix test misses it and leaves reasoning output switched on.
        self.assertEqual(
            post.call_args_list[1].kwargs["json"]["chat_template_kwargs"],
            {"enable_thinking": False},
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

    def test_source_only_salvages_single_line_transcript(self):
        # 2026-09-07: youtube_captions() joins every cue with a space, so a
        # whole video is ONE line. The old 12..500 filter dropped all 4808
        # characters and the note read as if nothing had been extracted.
        caption = "這集要講的一個關鍵觀念 我們先從第一個部分說起 " * 200
        self.assertNotIn("\n", caption)
        self.assertGreater(len(caption), 4000)
        result = BOT.source_only_summary("youtube", caption, ["m: ReadTimeout"])
        self.assertNotEqual(result["title"], "youtube 來源暫存")
        self.assertTrue(result["key_points"])
        self.assertIn("原文節錄", result["details_md"])
        self.assertIn("這集要講的一個關鍵觀念", result["details_md"])

    def test_split_long_line_hard_wraps_unpunctuated_text(self):
        # Auto-generated captions can run for thousands of characters without
        # a single sentence ender, so the sentence split alone is not enough.
        pieces = BOT._split_long_line("a" * 4808)
        self.assertEqual(len(pieces), 10)
        self.assertLessEqual(max(len(piece) for piece in pieces), 500)
        self.assertEqual("".join(pieces), "a" * 4808)
        self.assertEqual(BOT._split_long_line("短句子。"), ["短句子。"])

    def test_raw_excerpt_quotes_structure_breaking_source(self):
        # A stray "---", heading or unclosed fence in the source must not be
        # able to break the note that wraps it.
        excerpt = BOT.raw_excerpt("---\n# 假標題\n```\n未關閉的圍籬\n正常內文。")
        self.assertNotIn("```", excerpt)
        body = excerpt.splitlines()[4:]
        self.assertTrue(all(line.startswith(">") for line in body if line), body)

    def test_raw_excerpt_reports_truncation(self):
        excerpt = BOT.raw_excerpt("字" * (BOT.SOURCE_ONLY_EXCERPT_CHARS + 500))
        self.assertIn("此處保留前", excerpt)
        self.assertEqual(BOT.raw_excerpt("   "), "")

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

    def test_compose_env_parser_scopes_to_named_service(self):
        # compose 裡多個 service 都可能有 NVIDIA_*；全檔搜第一個會鎖錯鏈。
        yaml_text = """
services:
  other-bot:
    environment:
      NVIDIA_MODEL: "wrong/first-hit"
      NVIDIA_FALLBACK_MODEL: "wrong/first-fallback"
      NVIDIA_FINAL_FALLBACK_MODEL: "wrong/first-final"
  openab-url-intake:
    image: assistant-url-intake:dev
    environment:
      CHANNEL_ID: "1"
      NVIDIA_MODEL: "openai/gpt-oss-20b"
      NVIDIA_FALLBACK_MODEL: "google/gemma-4-31b-it"
      NVIDIA_FINAL_FALLBACK_MODEL: "nvidia/nemotron-3-super-120b-a12b"
    volumes:
      - /vault
  later-bot:
    environment:
      NVIDIA_MODEL: "wrong/later-hit"
"""
        env = _compose_service_environment(yaml_text, "openab-url-intake")
        self.assertEqual(env["NVIDIA_MODEL"], "openai/gpt-oss-20b")
        self.assertEqual(env["NVIDIA_FALLBACK_MODEL"], "google/gemma-4-31b-it")
        self.assertEqual(
            env["NVIDIA_FINAL_FALLBACK_MODEL"],
            "nvidia/nemotron-3-super-120b-a12b",
        )

    def test_url_intake_compose_nvidia_models_match_bot_defaults(self):
        # 2026-09-07 / 09-13 都踩過：compose environment 會蓋掉 bot.py 預設值，
        # 只改一邊等於沒改。讀 bot.py 原始碼而不是 BOT.NVIDIA_MODEL，這樣就算
        # 開發機 / CI 設了 NVIDIA_MODEL 也不會鎖到環境變數。
        names = (
            "NVIDIA_MODEL",
            "NVIDIA_FALLBACK_MODEL",
            "NVIDIA_FINAL_FALLBACK_MODEL",
        )
        bot_src = Path(__file__).with_name("bot.py").read_text(encoding="utf-8")
        compose_src = (
            Path(__file__).resolve().parents[1] / "docker-compose.yml"
        ).read_text(encoding="utf-8")
        bot_defaults = _bot_environ_defaults(bot_src, names)
        compose_env = _compose_service_environment(compose_src, "openab-url-intake")
        for name in names:
            self.assertIn(name, compose_env)
            self.assertEqual(
                compose_env[name],
                bot_defaults[name],
                f"{name} differs between docker-compose.yml url-intake and bot.py default",
            )
        self.assertEqual(bot_defaults["NVIDIA_MODEL"], "openai/gpt-oss-20b")
        self.assertEqual(bot_defaults["NVIDIA_FALLBACK_MODEL"], "google/gemma-4-31b-it")
        self.assertEqual(
            bot_defaults["NVIDIA_FINAL_FALLBACK_MODEL"],
            "nvidia/nemotron-3-super-120b-a12b",
        )


def _bot_environ_defaults(source, names):
    defaults = {}
    for name in names:
        pattern = (
            rf'{re.escape(name)}\s*=\s*os\.environ\.get\(\s*'
            rf'["\']{re.escape(name)}["\']\s*,\s*["\']([^"\']+)["\']'
        )
        match = re.search(pattern, source, flags=re.DOTALL)
        if match is None:
            raise AssertionError(f"could not find os.environ.get default for {name}")
        defaults[name] = match.group(1)
    return defaults


def _compose_service_environment(compose_text, service_name):
    env = {}
    in_service = False
    in_env = False
    service_indent = None
    env_indent = None
    for raw in compose_text.splitlines():
        stripped = raw.lstrip(" ")
        indent = len(raw) - len(stripped)
        if not in_service:
            if stripped.startswith("#") or stripped == "":
                continue
            if stripped.rstrip() == f"{service_name}:":
                in_service = True
                service_indent = indent
            continue
        if stripped and not stripped.startswith("#") and indent <= service_indent:
            break
        if not in_env:
            if stripped.startswith("#") or stripped == "":
                continue
            if stripped.rstrip() == "environment:":
                in_env = True
                env_indent = indent
            continue
        if stripped and not stripped.startswith("#") and indent <= env_indent:
            in_env = False
            if indent <= service_indent:
                break
            continue
        match = re.match(
            r'^([A-Z][A-Z0-9_]*):\s*(?:"([^"]*)"|([^#\s]+))\s*(?:#.*)?$',
            stripped,
        )
        if match:
            env[match.group(1)] = match.group(2) if match.group(2) is not None else match.group(3)
    if not in_service and not env:
        raise AssertionError(f"service {service_name} not found in compose text")
    return env


if __name__ == "__main__":
    unittest.main()
