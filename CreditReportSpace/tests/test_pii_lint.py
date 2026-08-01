"""PII lint：掃描會進 git 的檔案，確保沒有任何真實個資或真實樣本值。

規則：
1. 台灣身分證樣式（[A-Z][12]\\d{8}）不得出現。
2. 9 位以上連續數字（帳號/報表編號/snowflake 級長號碼）不得出現。
3. 報表編號樣式（如 XXX9-9999999）不得出現。
4. 真實樣本的姓名/公司/地段/關鍵金額以 SHA256 雜湊比對——本測試檔只存
   雜湊，不存明文；任何被掃描內容的 CJK 子字串或數字串命中即失敗。
5. fixture 必須明示 TEST／虛構標記。
"""

import hashlib
import re
from pathlib import Path

SPACE_ROOT = Path(__file__).resolve().parent.parent

SCAN_PATTERNS = [
    "*.md",
    "*.txt",
    "docs/**/*.md",
    "docs/**/*.txt",
    "fixtures/**/*.json",
    "schema/**/*.json",
    "tests/**/*.py",
    "tools/**/*.py",
]

TW_ID = re.compile(r"[A-Z][12]\d{8}")
LONG_DIGITS = re.compile(r"\d{9,}")
REPORT_NO = re.compile(r"[A-Z]{3}\d?-\d{6,}")
CJK_RUN = re.compile(r"[一-鿿]+")

# 真實樣本 token 的 SHA256（明文絕不進 repo）
FORBIDDEN_HASHES = {
    "51642792ab517f8f2933b25888fd11c6515b958069c9df68c6b7e4edf0330696",
    "a8a706aa4334870c79c29c0a207ef20929887a515fa196e016b25adf2a80fafa",
    "272c7acec10a90483cd034a5800ff5524e9c156cf3f176456488a7083e9883a1",
    "a9792b5dd13baf031fe0b57074b5ce4335b19189d146285f982c96abd62bed79",
    "b9a991e0264ce02be6b976abb00ba7126364a44a00c4291438d518224cca9b0e",
    "fb1b69fd4b28e3f37a006c996bb6c3dafe7f43ab880a2afeb64082d94162c384",
    "cd277c25eca2dc26de7b9b46bf2d2b0bad67464608a45c887a2b4932700c36fa",
    "aaed2bfa01003de13906c88873586eb21611d7fea26ddb3dad6b9371ac3a4c1c",
    "cd91ade49a98dc56e46b799697d76422b04d7b40ffa5fcc74919f38888e96c9e",
    "b99345274ca6daef23763079cd3ece6fcd457ac80d90b5ff670b46445849dd85",
    "ba2d8ad350c4450eee0499c1fe5f2c995e204da7663c99a8514c2890b302db61",
    "27b8600b4db5915dc174740b14679c517e207c7697b3de459b510595c6548d31",
    "f46ff3ea58721a923a21d8ccb792e0f18c50afa46317a8b6b6da67758d34ae97",
    "5f465d2833afa0352c78e3038e61ec4d339c643b8d91c33ae0086dbc2b2d6a2d",
    "8c950960d9d401ba3638e7faa15b7127cdee5d9701c8ed4739df82655f1d1416",
    "1fd7d792a2aaff4b07999789e8d199b9144ec60686de5f7fe21611008a9fee0c",
    "7d9a9ac350aa813e44d02db7d5ec314c3478900493adb2e5bacf576ee6502b3c",
    "186d1c9424c1fa0c6eb594e0c49b17459d5f96cf73b0f33d8a17877ef96eb597",
    "6b38ef5e1aa9aac9a9d93998591c3c7f685c46d75aa121a02e7c22ffc22ff61d",
    "fc2479decbb7b72e6a0f45984ce916c9f1bcb9b2df3b39ea78ac352fb1f47f1d",
    "687a00f94642737211973c0c70584e1a1ff65cf8addbca4187769d4e059dc235",
    "78d79d23e5d4e28f6238a3d60b4188041e86610aa6c986c2e24fee1c9087764f",
    "00c984b234b48cb891befc3d50e5f1affb2a9d6bf35fbd435cb8efad5f1a0a5a",
    "2e3761e12acd49b88f334cd3825bfd983a05a25e7b3963aae8eb515db74d1f3f",
    "b0e9f199c29c578378dd1a13fc780f7628f46198fd462c57373c28c793d612fc",
    # 徵信報告產製器黃金案的真實 token（公司/保證人/統編/身分證後6碼）
    "19f3097d731f82d8541bfe10118db113520e34b1aaedf5e8c1d238056c469e1e",
    "8a4b23c877cb97caab95922570e2b88381790b564097d93647d89d98fcd09975",
    "1f8fbd7668ff1017985cebe98be9dbbdcef34d69a37137e4f2e23ff2dc9e32e3",
    "cd47a6a9882d61191f5f918ccdb6b86cb37ed8718fabf36ab0516e1966986c59",
    "f87c7059f8c2bb34e8eb6395940e417d0d7722bced516adb7c2c305d357e96c3",
    "b1b716e3d388bc80ed74e7b73b06209af3e33379b9361f97994d1987aec3746c",
    "3061129a936519d7c400aa5ae856e83f4294c01bcf286c801a1648245fe20759",
    "73505c77ec40a35a956a78f801224fdf948a62f8fd0ae1ccecf3adfb829d76cb",
    "106e7704dc25b339e32922e1e2e87108549ec85371577094bfbfa118aadebf60",
    "098d3784bf0ec098d4ec61d5a745cf328732870e11af1e90d160bc50fe1eff17",
}


def _scan_files():
    files = []
    for pattern in SCAN_PATTERNS:
        files.extend(SPACE_ROOT.glob(pattern))
    # 本檔只含雜湊與範例樣式字串，排除自身避免自我誤報
    self_path = Path(__file__).resolve()
    return sorted({f for f in files if f.is_file() and f.resolve() != self_path})


def _sha(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def _hash_hits(text: str):
    hits = []
    for run in CJK_RUN.findall(text):
        for length in range(2, 7):
            for start in range(0, len(run) - length + 1):
                token = run[start:start + length]
                if _sha(token) in FORBIDDEN_HASHES:
                    hits.append(token)
    stripped = text.replace(",", "")
    for digits in re.findall(r"\d{4,}", stripped):
        if _sha(digits) in FORBIDDEN_HASHES:
            hits.append(digits)
    return hits


def test_no_pii_patterns_in_tracked_files():
    problems = []
    for file in _scan_files():
        text = file.read_text(encoding="utf-8")
        rel = file.relative_to(SPACE_ROOT)
        for name, pattern in (("身分證樣式", TW_ID), ("9+位連續數字", LONG_DIGITS),
                              ("報表編號樣式", REPORT_NO)):
            for m in pattern.findall(text):
                problems.append(f"{rel}: {name}: {m}")
        for token in _hash_hits(text):
            problems.append(f"{rel}: 命中真實樣本雜湊（token 長度 {len(token)}）")
    assert not problems, "\n".join(problems)


def test_fixture_is_marked_as_test_data():
    text = (SPACE_ROOT / "fixtures" / "sample_report.json").read_text(encoding="utf-8")
    assert "TEST" in text and "虛構" in text
