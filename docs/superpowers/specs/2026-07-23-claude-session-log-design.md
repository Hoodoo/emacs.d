# claude-session-log — Claude Code session log parser

## Problem

Claude Code writes one append-only JSONL file per session
(`~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`), plus a sibling
`subagents/` directory holding one JSONL + one `.meta.json` per
Task-spawned subagent. This data — token usage, cost, models used, files
touched, git branch/worktree changes, live task-list state — is not
accessible from within Emacs today.

Goal: a pure-parsing library that turns a session's JSONL file into
structured data, so other Emacs code (a future sidebar, a stats command,
whatever) can query it without re-deriving the JSONL shape each time.

## Non-goals

- No presentation layer. This package renders nothing — the agent-shell
  buffer already shows the live transcript; this is for numbers you can't
  eyeball (cost, token totals, task-list state, files touched, branch
  history).
- No live file-watching / polling. Every call does one full synchronous
  parse of the (small) JSONL file. Callers decide when to re-parse.
- No dependency on `hoodoo-session-context` or any tab/session-management
  concept. This module only knows "a JSONL file path in, a struct out." If
  and when a sidebar is built on top of this, it resolves "which session"
  itself (mirroring vulpea-ui's "note at point" pattern), independently of
  how session/tab management evolves.
- No "activity timeline" heuristics (fork/retry/debug spans) and no
  Active/Background/Idle wall-time bucketing. Both are real logic with
  real maintenance cost, and neither is needed yet. Per-line timestamps
  and type/role/promptSource are retained on each parsed event precisely
  so this bucketing *can* be added later without re-parsing raw JSONL —
  but the bucketing logic itself is out of scope for this pass.
- No incremental/tailing parser. Sessions are small enough that a full
  re-parse is cheap; incremental parsing is a legitimate future
  enhancement, not a v1 requirement.

## Real-data grounding

The original hand-off notes describing this format were corrupted
mid-transmission. Rather than guess around the gaps, the shape below was
verified against this machine's actual `~/.claude/projects/*/*.jsonl`
files:

- Every line (all types) carries `cwd` and `gitBranch` — branch/worktree
  tracking needs no git shell-out, it's already stamped per-event.
- `assistant` lines carry `message.model` and `message.usage`
  (`input_tokens`, `output_tokens`, `cache_creation_input_tokens`,
  `cache_read_input_tokens`, and a `cache_creation` sub-object with
  `ephemeral_5m_input_tokens` / `ephemeral_1h_input_tokens`). A synthetic
  placeholder model (`"<synthetic>"`, confirmed present in local logs)
  marks local interrupts/caveats and must be excluded from model/cost
  attribution.
- `attachment`-type lines carry `attachment.type`; one subtype is
  `task_reminder`, shaped `{type, content: [{id, subject, description,
  status, blocks, blockedBy}, ...], itemCount}` — a full snapshot each
  time, not a delta.
- Tool-use blocks (`Edit`/`Write`/`Read`/`NotebookEdit`) carry
  `input.file_path` directly.
- Each subagent's `subagents/<id>.meta.json` carries `agentType`,
  `description`, `toolUseId` (the parent's `Task` tool_use id that spawned
  it), `spawnDepth`, `model`. Checked for nesting (a subagent's own
  `subagents/` directory) — none found locally despite `spawnDepth`
  existing as a field, so subagent discovery is a single flat directory
  listing, not recursive.

## Data model

```elisp
(cl-defstruct claude-session-log-session
  session-id
  source-path
  start-time end-time duration-seconds
  models                 ; list of distinct real model names (main + subagents,
                          ; "<synthetic>" excluded)
  usage-by-model          ; alist: model -> plist (:input :output
                          ;   :cache-write-5m :cache-write-1h :cache-read)
  cost-by-model           ; alist: model -> dollars (float), MAIN SESSION ONLY
                          ; (subagent costs are not folded in here -- see
                          ; total-cost below)
  total-cost              ; sum of cost-by-model, PLUS every subagent's own
                          ; cost folded in -- this is "real cost", per user
                          ; decision to count subagent spend as spend
                          ; incurred on the session's behalf
  unpriced-models         ; models seen with no price-table entry; their
                          ; usage is counted but costs $0, flagged here so a
                          ; caller can surface "some costs may be incomplete"
  files-touched           ; flat, deduped list of file_path strings from
                          ; Edit/Write/Read/NotebookEdit tool_use inputs.
                          ; DECISION: main session + subagents are merged
                          ; into one flat list for v1. Subagent-attributed
                          ; file touches are not broken out separately --
                          ; revisit if that distinction turns out to matter.
  cwds branches           ; distinct sets of `cwd` / `gitBranch` values seen
                          ; across the session's own lines (not subagents')
  task-list               ; latest task_reminder snapshot: the raw parsed
                          ; `attachment' plist verbatim (:type :itemCount
                          ; :content, where :content is a list of plists
                          ; using the raw JSON keys :id :subject
                          ; :description :status :blocks :blockedBy), or
                          ; nil if none. Not normalized to kebab-case --
                          ; a deliberate simplification, consistent with
                          ; this parser's "less presentation" scope.
  subagents               ; list of claude-session-log-subagent
  events)                 ; ordered list of lightweight per-line skeletons,
                          ; see "Retained per-event data" below

(cl-defstruct claude-session-log-subagent
  agent-type description model spawn-depth tool-use-id
  usage-by-model total-cost  ; same shape as the session's own fields
  models files-touched)      ; merged into the session's own `models'/
                          ; `files-touched' by the top-level entry point,
                          ; per the "main + subagents" decision above
```

### Retained per-event data

Each entry in `events` is a plist: `(:timestamp :type :role :model
:is-meta :prompt-source)`. This is deliberately thin — not the full
parsed line, not tool inputs/outputs — just enough to reconstruct a
gap-attribution wall-time heuristic later (distinguishing a typed human
prompt from a system-injected one) without re-parsing the raw file. If a
future pass needs more per-event detail than this, that's a sign the
retained shape needs revisiting then, not a gap to over-fill now.

## Parsing algorithm

1. Read the JSONL file at `source-path` line by line, decoding each as
   JSON.
2. Track `start-time` (first line's timestamp) and `end-time` (last
   line's timestamp); `duration-seconds` is their difference.
3. For every line, regardless of type: add `cwd` to `cwds` and
   `gitBranch` to `branches` (as sets — dedupe on insert).
4. For `assistant`-type lines:
   - If `message.model` is not `"<synthetic>"`, add it to `models` and
     accumulate its `message.usage` fields into `usage-by-model`,
     preferring the split `cache_creation.ephemeral_5m_input_tokens` /
     `ephemeral_1h_input_tokens` when present, falling back to
     `cache_creation_input_tokens` (attributed to the 5m rate) when the
     split object is absent.
   - Walk `message.content` for `tool_use` blocks named `Edit`, `Write`,
     `Read`, or `NotebookEdit`; collect `input.file_path` into
     `files-touched`.
   - Append an event skeleton to `events`.
5. For `attachment`-type lines where `attachment.type` is
   `"task_reminder"`: overwrite `task-list` with this line's content
   (last occurrence wins, matching the established custom-title/recap
   rule already used elsewhere in Claude Code's log format).
6. For `user`-type lines: append an event skeleton to `events` (role
   `user`, capturing `promptSource`/`isMeta` for later bucketing use).
7. After the main file is parsed, list `<dir-of-source-path>/subagents/
   *.meta.json` (flat, one level, no recursion). For each, parse its
   sibling `.jsonl` the same way (steps 1-6, minus the subagent-discovery
   step itself) to get that subagent's own usage; build a
   `claude-session-log-subagent` struct.
8. Compute `cost-by-model` from `usage-by-model` via the price table (see
   below), then fold every subagent's own cost into `total-cost` (not
   into `cost-by-model`, which stays main-session-only per model, to keep
   "cost per model Claude itself used" legible; `total-cost` is the
   number for "real cost of this session including everything it spawned").

## Cost table

A static alist, `claude-session-log-model-prices`, mapping model ID to
(dollars per 1M input tokens . dollars per 1M output tokens). Sourced from
the `claude-api` skill's cached pricing table (current as of 2026-06-24):

| Model | Input $/1M | Output $/1M |
|---|---|---|
| `claude-fable-5` | 10.00 | 50.00 |
| `claude-mythos-5` | 10.00 | 50.00 |
| `claude-opus-4-8` | 5.00 | 25.00 |
| `claude-opus-4-7` | 5.00 | 25.00 |
| `claude-opus-4-6` | 5.00 | 25.00 |
| `claude-sonnet-5` | 2.00 | 10.00 |
| `claude-sonnet-4-6` | 3.00 | 15.00 |
| `claude-haiku-4-5` | 1.00 | 5.00 |

`claude-sonnet-5` uses the introductory rate ($2/$10, in effect through
2026-08-31) since that is what is actually billing today; this row will
need a manual update once the introductory window ends, and the whole
table will need manual upkeep as Anthropic's pricing changes generally —
an accepted, known maintenance cost (mirrored in the original design
notes' own admission that this logic needs a static, hand-maintained
price table).

Cache-token cost multipliers, applied per model's input price:

- Cache write, 5-minute TTL: 1.25x
- Cache write, 1-hour TTL: 2x
- Cache read: 0.1x

A model with no entry in the table contributes $0 to `cost-by-model` /
`total-cost` and is added to `unpriced-models` — matching the original
notes' "unknown models cost 0 rather than erroring" rule.

## Testing approach

Pure-function parser over static JSONL fixture files (small, hand-written
or trimmed from real local session files with any sensitive content
scrubbed), run under `emacs -Q --batch` — no agent-shell, no network, no
live Claude Code process required. Matches the existing test approach used
elsewhere in this repo (`hoodoo-session-context-test.el` and the
`auto-side-windows` fix before it).

Cases to cover: basic usage/cost rollup across models; `<synthetic>`
exclusion; cache 5m/1h split vs. combined-field fallback; `task_reminder`
last-occurrence-wins with multiple snapshots; file-touch extraction and
dedup; subagent discovery and cost folding into `total-cost`; an unpriced
model appearing in `unpriced-models` with $0 cost; a session with no
`subagents/` directory at all (most sessions).

## Open items deferred, not blocking

- Whether `unpriced-models` should also surface *why* (missing from
  table vs. a genuinely new/unknown model) — not needed until it's hit
  in practice.
- Whether `events` needs more fields once the wall-time bucketing pass
  actually gets built — deliberately deferred to that pass.
- Package/file split-out into a standalone repo, mentioned as a future
  intent — not needed for this pass; this spec's file stays in this
  repo (`claude-session-log.el`) until there's a second consumer.
