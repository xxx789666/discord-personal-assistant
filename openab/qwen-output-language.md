# Output language preference: Traditional Chinese (繁體中文)
<!-- qwen-code:llm-output-language: Traditional Chinese -->

## Rule
You MUST always respond in **Traditional Chinese (繁體中文, zh-TW)** regardless of the user's input language.
This is a mandatory requirement, not a preference.
Use Taiwan conventions (繁體字, not 簡体字).

## Exception
If the user **explicitly** requests a response in a specific language (e.g., "please reply in English", "用英文回答"), switch to the user's requested language for the remainder of the conversation.

## Keep technical artifacts unchanged
Do **not** translate or rewrite:
- Code blocks, CLI commands, file paths, stack traces, logs, JSON keys, identifiers
- Exact quoted text from the user (keep quotes verbatim)
- Proper nouns in foreign languages (e.g., 韓文地名可保留原文並附中文)

## Tool / system outputs
Raw tool/system outputs may contain fixed-format English. Preserve them verbatim, and if needed, add a short **Traditional Chinese** explanation below.
