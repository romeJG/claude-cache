# How it works

The app has two parts.

- **The scanner**, `Sources/claude_cache_watch.py`, reads the logs and works out every number.
- **The menu bar app**, `Sources/ClaudeCache/`, runs the scanner every 5 seconds and draws its JSON output.

The scanner works with the system Python and needs no packages.

## Where the data comes from

Claude Code writes one JSON-lines log per conversation:

| Logs | Written by |
|---|---|
| `~/.claude/projects/<project>/<session>.jsonl` | Claude Code (the terminal, IDE and desktop app) |
| `~/Library/Application Support/Claude/local-agent-mode-sessions/*/*/*/.claude/projects/<project>/<session>.jsonl` | Cowork sessions in the Claude desktop app |

The scanner reads these record types:

| Record | Used for |
|---|---|
| `assistant` entries with `message.usage` | One per reply. They give the time, the input tokens and output tokens, cache reads, and cache writes split into 1-hour and 5-minute writes. A reply is logged in several pieces that share a message id, so the scanner removes duplicates by that id. |
| `custom-title`, `last-prompt`, the first typed message | The conversation's title. |
| `system` with subtype `compact_boundary` | Compactions. The context restarts after each one. |
| `api-request-shape` | The system prompt and tool definitions Claude Code sent. |
| `api-request-blob` | Messages Claude Code sent. The scanner uses them only to find the memory-file and skill-list reminders the app injected. |
| `user` / `assistant` messages since the last compaction | The conversation itself: your messages, Claude's replies, tool calls and tool results. |

## The cache timer

Each reply writes to the cache with a lifetime: 1 hour if the reply's `ephemeral_1h_input_tokens` is above 0, otherwise 5 minutes. Every request that reads the cache restarts the clock. So:

```
time left = lifetime − (now − time of the last reply)
```

- **🔥 hot:** more than 20 minutes left.
- **⏳ low:** 20 minutes or less left.
- **🧊 cold:** expired.

A conversation logs nothing between replies, and nobody can ask the server what is cached. So this is a prediction from the log, not a reading from the server.

A **cold restart** is a reply sent after the previous reply's cache had expired that wrote more than 10k tokens to the cache: it had to rebuild the context.

## Today

The Today section adds up every reply since local midnight, across every conversation whose log changed today:

- **From cache** is `cache reads ÷ (cache reads + cache writes + uncached input)`.
- Cache reads are billed at a fraction of normal input, and cache writes above it, so a high share means you're mostly paying the cheap rate.

## The context breakdown

The latest reply's input total is the size of the context:

```
uncached input + cache reads + cache writes
```

The window is taken to be 1M tokens in three cases: the model is a Claude 5 model, its name ends in `[1m]`, or any reply in the log went past 200k. Otherwise it's 200k. The log doesn't record the window, so this is a guess.

Each part is estimated:

| Part | Source | Estimate |
|---|---|---|
| System prompt | the latest `api-request-shape` | ~3.6 characters a token |
| System tools / MCP tools | its tool definitions (names starting `mcp__` are MCP; `defer_loading` tools are left out, because only their names are sent) | ~4.5 characters a token of JSON |
| Memory files | the newest injected reminder containing `Contents of …CLAUDE.md` / `MEMORY.md` | ~3.6 characters a token |
| Skills | the newest skill list (`The following skills are available…`), from the list to the end of its reminder | ~3.6 characters a token |
| Your messages, Claude's replies, tool calls and results | the transcript since the last compaction | ~3.6 characters a token |
| Images & screenshots | image blocks in the transcript | width × height ÷ 750, after shrinking to 1568 px on the long edge and ~1.15 megapixels (Claude's billing rule) |
| Thinking | the `thinking_tokens` each reply reports since the last compaction (the log keeps no thinking text) | exact |

The estimates are then fitted to the real total:

- **If they come to more than the total,** every part is scaled down to fit.
- **If they come to less,** the rest is shown as **Reminders & other**. Claude Code adds reminders (environment, date, deferred-tool lists, hook output) that the transcript doesn't record, and they're most of that remainder.

**Cowork logs** have no request records, so their system prompt and tools can't be told apart from that remainder. For those conversations, the remainder is shown as one part, **System, tools & reminders**.

**Measured against Claude Code's own Context panel** on the same conversation:

- The system prompt, system tools and skills came within about 1k each.
- MCP tools came out lower: 10.7k against the panel's 16.6k.

**Biggest items** are the largest single blocks in the context. Each is labelled from the tool call that produced it: `Read · file.ts`, `Bash · <its description>`, `Skill loaded · <name>`, and so on.

## Tips

`tips_for()` in the scanner makes up to three suggestions per conversation, biggest win first:

| When | Suggests |
|---|---|
| Context over 60% of the window | `/compact`, or a new conversation for the next task |
| Context over 150k | Start fresh for unrelated work |
| Images over 15k | Read pages as text instead of taking screenshots |
| One kind of tool output over 20k | A specific fix (`head`/`grep` for shell output, offset/limit for file reads, short summaries from subagents…) |
| MCP tools over 10k | Turn off servers the project doesn't use |
| Memory files over 10k | Trim `CLAUDE.md` |
| Skill list over 8k | Disable unused plugins |
| A 5-minute cache | Pauses longer than 5 minutes rewrite everything |

`day_tips()` adds the cold-restart warning to Today.

## Speed

Reading a large log in full takes about 0.4 s. The scanner remembers each log's results by its size and modified time, in `~/Library/Caches/local.claude-cache-bar/scan-state.json`, so a scan only reads logs that changed. A scan where nothing changed takes about 0.1 s.

## The app

- **`AppDelegate.swift`**
  - Owns the status item.
  - Runs `/usr/bin/python3 -I claude_cache_watch.py --json` every 5 seconds on a background queue.
  - Updates the title every second.
  - Hosts the SwiftUI menu inside an `NSMenuItem`, resizing it when the content changes.
  - **Open at Login** uses `SMAppService.mainApp`.
- **`MenuView.swift`**
  - All the views.
  - The menu is see-through glass, so it paints its own solid panel, and every colour is explicit (see `Ink` in `Model.swift`). SwiftUI's `.secondary` colours blend with the desktop behind the menu and become hard to read.
  - Section open/closed state is kept with `@AppStorage`.
  - When the content is taller than the screen, it scrolls.
- **`build.sh`**
  - Compiles for `arm64` and `x86_64`, joins the two with `lipo`, and copies the scanner into `Contents/Resources`.
  - Signs the app ad hoc (not notarized), and with `--dmg` packs it with `hdiutil`.
