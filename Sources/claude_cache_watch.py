#!/usr/bin/env python3
"""Live view of Claude's prompt cache for your most recent conversations.

The prompt cache lives on Anthropic's servers and can't be queried, but every
reply in a conversation log records when it was made and which cache lifetime
it wrote (5 minutes or 1 hour). Each request that hits the cache resets that
clock, so a conversation's cache is hot while (time since its last reply) is
under that lifetime.

Scans the logs on this Mac:
  ~/.claude/projects/*/*.jsonl                                  Claude Code
  ~/Library/Application Support/Claude/local-agent-mode-sessions/**/.claude/projects/*/*.jsonl
                                                                Cowork sessions

Usage:
  python3 claude_cache_watch.py              5 conversations, re-scan every 5 s
  python3 claude_cache_watch.py -n 8 -e 60   8 conversations, re-scan every 60 s
Keys: r re-scan now, q quit.
"""
import argparse
import curses
import glob
import json
import os
import subprocess
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone

HOME = os.path.expanduser('~')
LOG_GLOBS = [
    os.path.join(HOME, '.claude/projects/*/*.jsonl'),
    os.path.join(HOME, 'Library/Application Support/Claude/local-agent-mode-sessions',
                 '*/*/*/.claude/projects/*/*.jsonl'),
]
TAIL_BYTES = 2_000_000  # the last reply and latest title are near the end of a log
HEAD_BYTES = 500_000    # the first message (title fallback) is near the start
WARN_SECONDS = 20 * 60  # yellow (LOW) from here down; matches the menu bar app


def read_lines(path, start, size):
    with open(path, 'rb') as f:
        f.seek(start)
        chunk = f.read(size)
    lines = chunk.split(b'\n')
    if start > 0:
        lines = lines[1:]  # first line was cut in half by the seek
    for raw in lines:
        try:
            yield json.loads(raw)
        except ValueError:
            continue


def first_text(message):
    content = message.get('content')
    if isinstance(content, str):
        return content
    for part in content or []:
        if isinstance(part, dict) and part.get('type') == 'text':
            return part.get('text', '')
    return ''


def read_conversation(path):
    """The newest reply's timing and cache details, plus a title and project."""
    size = os.path.getsize(path)
    reply = title = cwd = last_prompt = None
    reply_times = {}  # message id -> unix time; one reply is logged in several pieces
    for d in read_lines(path, max(0, size - TAIL_BYTES), TAIL_BYTES):
        if d.get('type') == 'custom-title':
            title = d.get('customTitle') or title
        if d.get('type') == 'last-prompt':
            last_prompt = d.get('lastPrompt') or last_prompt
        if d.get('cwd'):
            cwd = d['cwd']
        if d.get('timestamp') and d.get('message', {}).get('usage'):
            reply = d
            when = datetime.fromisoformat(d['timestamp'].replace('Z', '+00:00')).timestamp()
            reply_times.setdefault(d['message'].get('id') or d['timestamp'], when)
    if not reply:
        return None
    if not title:
        for d in read_lines(path, 0, HEAD_BYTES):
            # isMeta: text the app injected (skill instructions), not typed by you.
            if d.get('type') == 'user' and not d.get('isSidechain') and not d.get('isMeta'):
                text = first_text(d.get('message', {})).strip()
                # Skip command wrappers and throwaway openers like "." or "hi".
                if len(text) >= 3 and not text.startswith('<'):
                    title = text
                    break
    title = title or last_prompt
    usage = reply['message']['usage']
    created = usage.get('cache_creation') or {}
    return {
        'path': path,
        'title': ' '.join((title or os.path.basename(path)).split()),
        'project': os.path.basename(cwd) if cwd else '?',
        'when': datetime.fromisoformat(reply['timestamp'].replace('Z', '+00:00')),
        # A 1-hour write means this conversation caches for an hour; else the 5-minute default.
        'ttl': 3600 if created.get('ephemeral_1h_input_tokens') else 300,
        'cached': usage.get('cache_read_input_tokens', 0) or 0,
        # Replies in the hour up to the last one: the activity ticks on the menu's timeline.
        'replies': sorted(t for t in reply_times.values()
                          if t >= reply_times[reply['message'].get('id') or reply['timestamp']] - 3600),
    }


# ---------------------------------------------------------------------------
# Context breakdown (for the menu bar app's --json)
#
# The system prompt and tool definitions come from the latest `api-request-shape`
# record Claude Code logs; memory files and the skill list from the newest
# `api-request-blob` that carries them; the conversation itself from the
# transcript since the last compaction (the request blobs are de-duplicated
# across sessions, so they can't rebuild it). Each part is estimated (about 3.6
# characters a token for text, 4.5 for tool schemas, images by size), then
# fitted to the real total the latest reply reported: what is left over is
# mostly reminders the app injects without logging them.

STATE_FILE = os.path.join(HOME, 'Library/Caches/local.claude-cache-bar/scan-state.json')
STATE_VERSION = 8
AUTOCOMPACT_BUFFER = 33_000

PARTS = [  # key, label: the same rows as Claude Code's Context panel
    ('system', 'System prompt'),
    ('tools', 'System tools'),
    ('mcp', 'MCP tools'),
    ('memory', 'Memory files'),
    ('skills', 'Skills'),
    ('messages', 'Messages'),
]
MESSAGE_PARTS = [
    ('you', 'Your messages'),
    ('replies', "Claude's replies"),
    ('thinking', 'Thinking'),
    ('calls', 'Tool calls'),
    ('results', 'Tool results'),
    ('images', 'Images & screenshots'),
    ('notices', 'Reminders & other'),
]


def est(text):
    return len(text) / 3.6


def image_tokens(block):
    """Claude bills an image at about width × height / 750, after shrinking it
    to fit 1568 px on the long edge and about 1.15 megapixels."""
    import base64
    data = (block.get('source') or {}).get('data') or ''
    w = h = 0
    try:
        head = base64.b64decode(data[:64] + '=' * (-len(data[:64]) % 4))
        if head[:8] == b'\x89PNG\r\n\x1a\n':
            w, h = int.from_bytes(head[16:20], 'big'), int.from_bytes(head[20:24], 'big')
        elif head[:4] == b'RIFF' and head[12:16] == b'VP8X':
            w = int.from_bytes(head[24:27], 'little') + 1
            h = int.from_bytes(head[27:30], 'little') + 1
    except ValueError:
        pass
    if not (w and h):
        return 1600
    scale = min(1, 1568 / max(w, h), (1_150_000 / (w * h)) ** 0.5)
    return (w * scale) * (h * scale) / 750


def tool_group(name):
    if name in ('Read', 'Grep', 'Glob', 'NotebookRead'):
        return 'File reads'
    if name in ('Bash', 'BashOutput', 'Monitor'):
        return 'Shell output'
    if name in ('Edit', 'Write', 'MultiEdit', 'NotebookEdit'):
        return 'Edits'
    if 'Browser' in name or 'chrome' in name:
        return 'Browser'
    if name in ('Agent', 'Task'):
        return 'Subagents'
    if name == 'Skill':
        return 'Skills loaded'
    if name in ('WebFetch', 'WebSearch'):
        return 'Web'
    if name.startswith('mcp__'):
        return name.split('__')[1] if name.count('__') >= 2 else 'MCP'
    return name


def tool_label(name, args):
    args = args or {}
    if args.get('file_path'):
        return f"{name} · {os.path.basename(args['file_path'])}"
    if name == 'Bash':
        return f"Bash · {args.get('description') or (args.get('command') or '')[:40]}"
    if name == 'Skill':
        return f"Skill · {args.get('skill', '')}"
    if name in ('Agent', 'Task'):
        return f"Agent · {args.get('description', '')}"
    if name.startswith('mcp__'):
        return name.split('__')[-1].replace('_', ' ')
    return name


def text_of(content):
    if isinstance(content, str):
        return content
    out = []
    for b in content or []:
        if isinstance(b, dict):
            out.append(b.get('text') or '')
    return '\n'.join(out)


class Tally:
    def __init__(self):
        self.parts = {k: 0.0 for k, _ in PARTS}
        self.msgs = {k: 0.0 for k, _ in MESSAGE_PARTS}
        self.groups = {}   # tool group -> result tokens
        self.items = []    # (tokens, label) for the biggest single things

    def msg(self, key, n, label=None):
        self.msgs[key] += n
        self.parts['messages'] += n
        if label and n:
            self.items.append([n, label])

    def tools(self, tools):
        for t in tools or []:
            if t.get('defer_loading'):
                continue  # only names are sent; the schemas load on demand
            key = 'mcp' if t.get('name', '').startswith('mcp__') else 'tools'
            self.parts[key] += len(json.dumps(t)) / 4.5

    def messages(self, messages):
        names = {}
        for m in messages:
            role = m.get('role')
            content = m.get('content')
            if isinstance(content, str):
                content = [{'type': 'text', 'text': content}]
            for b in content or []:
                if not isinstance(b, dict):
                    continue
                kind = b.get('type')
                if kind == 'text':
                    text = b.get('text') or ''
                    lead = text.lstrip()
                    if role == 'assistant':
                        self.msg('replies', est(text))
                    elif lead.startswith('Base directory for this skill'):
                        name = os.path.basename(lead.split('\n', 1)[0].rstrip())
                        n = est(text)
                        self.msg('results', n, f'Skill loaded · {name}')
                        self.groups['Skills loaded'] = self.groups.get('Skills loaded', 0) + n
                    elif lead.startswith('This session is being continued'):
                        self.msg('you', est(text), 'Summary of earlier conversation')
                    elif role == 'assistant':
                        self.msg('replies', est(text))
                    elif role == 'system':
                        self.msg('notices', est(text))
                    elif '<system-reminder>' in text and 'Contents of ' in text and ('CLAUDE.md' in text or 'MEMORY.md' in text):
                        self.parts['memory'] += est(text)
                    elif '<system-reminder>' in text and 'skills are available' in text:
                        self.parts['skills'] += est(text)
                    elif text.lstrip().startswith('<system-reminder>') or text.lstrip().startswith('<'):
                        self.msg('notices', est(text))
                    else:
                        self.msg('you', est(text), 'Your message · ' + ' '.join(text.split())[:40])
                elif kind == 'image':
                    self.msg('images', image_tokens(b), 'Image you attached')
                elif kind == 'tool_use':
                    names[b.get('id')] = (b.get('name', '?'), b.get('input'))
                    self.msg('calls', est(json.dumps(b.get('input') or {})))
                elif kind == 'tool_result':
                    name, args = names.get(b.get('tool_use_id'), ('?', None))
                    inner = b.get('content')
                    if isinstance(inner, str):
                        inner = [{'type': 'text', 'text': inner}]
                    text_n = img_n = 0
                    for x in inner or []:
                        if isinstance(x, dict) and x.get('type') == 'image':
                            img_n += image_tokens(x)
                        elif isinstance(x, dict):
                            text_n += est(x.get('text') or '')
                    label = tool_label(name, args)
                    if img_n:
                        self.msg('images', img_n, label + ' (image)')
                    self.msg('results', text_n, label)
                    group = tool_group(name)
                    self.groups[group] = self.groups.get(group, 0) + text_n + img_n
                elif kind in ('tool_addition', 'tool_removal'):
                    self.msg('notices', est(json.dumps(b)))
                # thinking: its text isn't logged; counted from the replies' usage instead

    def result(self, actual, thinking):
        """Fit the estimates to the reply's real total: an overshoot scales every
        part down; a shortfall goes to reminders, which the log doesn't record."""
        self.msgs['thinking'] = 0
        thinking = min(thinking, actual * 0.5)
        known = sum(self.parts.values()) + thinking
        if known > actual:
            f = actual / known
            thinking *= f
            for d in (self.parts, self.msgs, self.groups):
                for k in d:
                    d[k] *= f
            for item in self.items:
                item[0] *= f
        else:
            self.msgs['notices'] += actual - known
            self.parts['messages'] += actual - known
        self.msgs['thinking'] = thinking
        self.parts['messages'] += thinking
        merged = {}
        for n, label in self.items:
            merged[label] = merged.get(label, 0) + n
        return {
            'parts': [{'key': k, 'label': l, 'tokens': round(self.parts[k])} for k, l in PARTS],
            'messages': [{'key': k, 'label': l, 'tokens': round(self.msgs[k])} for k, l in MESSAGE_PARTS],
            'groups': sorted(({'label': k, 'tokens': round(v)} for k, v in self.groups.items() if v >= 500),
                             key=lambda g: -g['tokens'])[:5],
            'top': sorted(({'label': k, 'tokens': round(v)} for k, v in merged.items() if v >= 1000),
                          key=lambda g: -g['tokens'])[:4],
        }


def analyze(path):
    """Everything the menu shows about one conversation, from one pass over its log."""
    shapes, blobs, reqs = {}, {}, {}  # blobs: just the newest memory and skills reminders
    last_req = None
    replies = {}            # message id -> (time, usage, model); a reply is logged in pieces
    transcript = []         # user/assistant messages since the last compaction (fallback)
    title = cwd = last_prompt = first_typed = None
    compactions = []        # times of compactions
    for raw in open(path, 'rb'):
        try:
            d = json.loads(raw)
        except ValueError:
            continue
        kind = d.get('type')
        if kind == 'api-request-shape':
            shapes[d.get('shapeHash')] = d.get('shape') or {}
            continue
        if kind == 'api-request-blob':
            # Only text the app injected (a reminder, or a system message), never a
            # tool result or message that merely quotes it.
            m = d.get('message') or {}
            content = m.get('content')
            texts = [content] if isinstance(content, str) else \
                [x.get('text') or '' for x in content or [] if isinstance(x, dict) and x.get('type') == 'text']
            for text in texts:
                if not (m.get('role') == 'system' or text.lstrip().startswith('<system-reminder>')):
                    continue
                if 'Contents of ' in text and ('CLAUDE.md' in text or 'MEMORY.md' in text):
                    blobs['memory'] = m
                if 'skills are available for use with the Skill tool' in text:
                    blobs['skills'] = m
            continue
        if kind == 'api-request':
            reqs[d.get('id')] = d
            last_req = d
            continue
        if kind == 'custom-title':
            title = d.get('customTitle') or title
        elif kind == 'last-prompt':
            last_prompt = d.get('lastPrompt') or last_prompt
        elif kind == 'system' and d.get('subtype') == 'compact_boundary':
            transcript = []
            compactions.append(d.get('timestamp'))
        if d.get('cwd'):
            cwd = d['cwd']
        msg = d.get('message') if isinstance(d.get('message'), dict) else None
        if not msg or d.get('isSidechain'):
            continue
        if kind == 'user' and not first_typed and not d.get('isMeta'):
            text = first_text(msg).strip()
            if len(text) >= 3 and not text.startswith('<'):
                first_typed = text
        if kind in ('user', 'assistant'):
            transcript.append(msg)
        if msg.get('usage') and d.get('timestamp'):
            when = datetime.fromisoformat(d['timestamp'].replace('Z', '+00:00')).timestamp()
            key = msg.get('id') or d['timestamp']
            first_when = replies.get(key, (when,))[0]
            replies[key] = (first_when, msg['usage'], msg.get('model') or '')
    if not replies:
        return None

    order = sorted(replies.values(), key=lambda r: r[0])
    when, usage, model = order[-1]
    created = usage.get('cache_creation') or {}
    ttl = 3600 if created.get('ephemeral_1h_input_tokens') else 300
    total = lambda u: (u.get('input_tokens') or 0) + (u.get('cache_read_input_tokens') or 0) + \
        (u.get('cache_creation_input_tokens') or 0)
    used = total(usage)
    peak = max(total(u) for _, u, _ in order)
    window = 1_000_000 if ('[1m]' in model or '-5-' in model or model.endswith('-5') or peak > 200_000) else 200_000

    # Thinking stays in context until compaction: the replies since then.
    last_compact = 0
    if compactions and compactions[-1]:
        last_compact = datetime.fromisoformat(compactions[-1].replace('Z', '+00:00')).timestamp()
    thinking = sum(((u.get('output_tokens_details') or {}).get('thinking_tokens') or 0)
                   for t, u, _ in order if t >= last_compact)

    tally = Tally()
    # Without request records (Cowork logs) the system prompt and tools aren't
    # known, and end up with the reminders as the unexplained remainder.
    exact = bool(last_req and shapes.get(last_req.get('shapeHash')))
    if exact:
        shape = shapes[last_req.get('shapeHash')]
        tally.parts['system'] += est(text_of(shape.get('system')))
        tally.tools(shape.get('tools'))
    for key, marker in (('memory', 'Contents of '), ('skills', 'The following skills are available')):
        content = (blobs.get(key) or {}).get('content') or []
        texts = [content] if isinstance(content, str) else [b.get('text') or '' for b in content if isinstance(b, dict)]
        for text in texts:
            if marker not in text or (key == 'memory' and not text.lstrip().startswith('<system-reminder>')):
                continue
            if key == 'skills':
                # The skill list shares its reminder with other text: count from the list on.
                text = text[text.index(marker):]
                end = text.find('</system-reminder>')
                text = text[:end] if end > 0 else text
            tally.parts[key] += est(text)
    tally.messages(transcript)
    breakdown = tally.result(used, thinking)
    if not exact:
        # The remainder here is mostly the unlogged system prompt and tools.
        rest = next(m for m in breakdown['messages'] if m['key'] == 'notices')
        part = {p['key']: p for p in breakdown['parts']}
        part['system'].update(label='System, tools & reminders', tokens=rest['tokens'])
        part['messages']['tokens'] -= rest['tokens']
        rest['tokens'] = 0

    # Cold restarts: a reply that came after the cache expired had to write it all again.
    restarts = []
    for (t0, u0, _), (t1, u1, _) in zip(order, order[1:]):
        ttl0 = 3600 if (u0.get('cache_creation') or {}).get('ephemeral_1h_input_tokens') else 300
        if t1 - t0 > ttl0 and (u1.get('cache_creation_input_tokens') or 0) > 10_000:
            restarts.append((t1, u1.get('cache_creation_input_tokens') or 0))

    title = ' '.join((title or first_typed or last_prompt or os.path.basename(path)).split())
    return {
        'id': os.path.basename(path),
        'title': title,
        'project': os.path.basename(cwd) if cwd else '?',
        'cwd': cwd,
        # Only Claude Code's own logs can be reopened with `claude --resume`.
        'resumable': path.startswith(os.path.join(HOME, '.claude/projects') + os.sep),
        'when': when,
        'ttl': ttl,
        'cached': usage.get('cache_read_input_tokens', 0) or 0,
        'replies': [t for t, _, _ in order if t >= when - 3600],
        'context': {
            'used': used,
            'window': window,
            'autocompact': AUTOCOMPACT_BUFFER,
            'exact': exact,
            **breakdown,
        },
        # Per reply, for today's totals: time, input, cache write, cache read, output.
        'usage': [[t, u.get('input_tokens') or 0, u.get('cache_creation_input_tokens') or 0,
                   u.get('cache_read_input_tokens') or 0, u.get('output_tokens') or 0] for t, u, _ in order],
        'restarts': restarts,
        'compactions': [datetime.fromisoformat(c.replace('Z', '+00:00')).timestamp() for c in compactions if c],
    }


# ---------------------------------------------------------------------------
# Plan limits: the 5-hour session and weekly usage, as Claude Code's /usage shows.
#
# The logs only mention a limit once you hit it, so this asks Anthropic, the way
# Claude Code does: with the sign-in Claude Code keeps in the login Keychain
# (item "Claude Code-credentials"). When that sign-in has expired (it does if you
# mostly use the desktop app), it is renewed with its refresh token and the new
# one saved back to the same item, so Claude Code stays signed in. Asked at most
# every LIMITS_EVERY seconds; the answer (never a token) is cached on disk.

LIMITS_FILE = os.path.join(HOME, 'Library/Caches/local.claude-cache-bar/limits.json')
LIMITS_EVERY = 180
KEYCHAIN_SERVICE = 'Claude Code-credentials'
USAGE_URL = 'https://api.anthropic.com/api/oauth/usage'
TOKEN_URL = 'https://console.anthropic.com/v1/oauth/token'
CLAUDE_CODE_CLIENT_ID = '9d1c250a-e61b-44d9-88ed-5944d1962f5e'
LIMIT_LABELS = {
    'five_hour': '5-hour session',
    'seven_day': 'Week · all models',
    'seven_day_opus': 'Week · Opus',
    'seven_day_sonnet': 'Week · Sonnet',
}


class LimitsError(Exception):
    pass


def keychain_read():
    out = subprocess.run(['security', 'find-generic-password', '-s', KEYCHAIN_SERVICE, '-w'],
                         capture_output=True, text=True, timeout=10)
    if out.returncode != 0:
        raise LimitsError('Sign in to Claude Code in Terminal (claude) to show your limits.')
    try:
        return json.loads(out.stdout)
    except ValueError:
        raise LimitsError("Couldn't read Claude Code's sign-in.")


def keychain_account():
    out = subprocess.run(['security', 'find-generic-password', '-s', KEYCHAIN_SERVICE],
                         capture_output=True, text=True, timeout=10)
    for line in out.stdout.splitlines():
        if '"acct"' in line and '=' in line:
            value = line.split('=', 1)[1].strip()
            if value.startswith('"') and value.endswith('"'):
                return value[1:-1]
    return os.environ.get('USER', '')


def keychain_write(creds):
    """Save the credentials back, hex-encoded the way Claude Code itself does,
    then read them back to be sure they arrived whole. (`security -i` reading
    from stdin is not an option: it cuts lines at 4 KB.)"""
    text = json.dumps(creds, separators=(',', ':'))
    out = subprocess.run(['security', 'add-generic-password', '-U', '-a', keychain_account(),
                          '-s', KEYCHAIN_SERVICE, '-X', text.encode().hex()],
                         capture_output=True, text=True, timeout=10)
    if out.returncode != 0 or keychain_read() != creds:
        raise LimitsError("Couldn't save the renewed sign-in: run claude in Terminal and /login.")


def post_json(url, body=None, headers=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method='POST' if data else 'GET', headers={
        'Content-Type': 'application/json', 'Accept': 'application/json', 'User-Agent': 'claude-cache',
        **(headers or {})})
    with urllib.request.urlopen(req, timeout=15) as r:
        return json.load(r)


def fresh_token():
    """Claude Code's access token, renewed first if it has expired (or nearly)."""
    creds = keychain_read()
    oauth = creds.get('claudeAiOauth') or {}
    if not oauth.get('accessToken'):
        raise LimitsError('Sign in to Claude Code in Terminal (claude) to show your limits.')
    if (oauth.get('expiresAt') or 0) / 1000 > time.time() + 120:
        return oauth['accessToken'], oauth.get('subscriptionType')
    if not oauth.get('refreshToken'):
        raise LimitsError('Your Claude Code sign-in expired: run claude in Terminal once.')
    try:
        got = post_json(TOKEN_URL, {'grant_type': 'refresh_token', 'refresh_token': oauth['refreshToken'],
                                    'client_id': CLAUDE_CODE_CLIENT_ID})
    except urllib.error.HTTPError:
        raise LimitsError('Your Claude Code sign-in expired: run claude in Terminal once.')
    # Claude Code may have renewed it meanwhile: never overwrite a newer sign-in.
    latest = keychain_read()
    if (latest.get('claudeAiOauth') or {}).get('refreshToken') != oauth['refreshToken']:
        return latest['claudeAiOauth']['accessToken'], oauth.get('subscriptionType')
    oauth = dict(oauth, accessToken=got['access_token'],
                 refreshToken=got.get('refresh_token') or oauth['refreshToken'],
                 expiresAt=int((time.time() + int(got.get('expires_in') or 3600)) * 1000))
    keychain_write(dict(latest, claudeAiOauth=oauth))
    return oauth['accessToken'], oauth.get('subscriptionType')


def fetch_limits():
    token, plan = fresh_token()
    try:
        usage = post_json(USAGE_URL, headers={'Authorization': 'Bearer ' + token,
                                              'anthropic-beta': 'oauth-2025-04-20'})
    except urllib.error.HTTPError as e:
        raise LimitsError(f'Anthropic answered {e.code} for your usage.')
    windows = []
    for key, value in usage.items():
        if not isinstance(value, dict) or value.get('utilization') is None:
            continue
        resets = value.get('resets_at')
        windows.append({
            'key': key,
            'label': LIMIT_LABELS.get(key, key.replace('_', ' ').capitalize()),
            'used': float(value['utilization']),
            'resets': datetime.fromisoformat(resets.replace('Z', '+00:00')).timestamp() if resets else None,
        })
    order = list(LIMIT_LABELS)
    windows.sort(key=lambda w: order.index(w['key']) if w['key'] in order else len(order))
    return {'windows': windows, 'plan': plan}


def limits():
    """The cached answer, asking again when it is older than LIMITS_EVERY."""
    try:
        cached = json.load(open(LIMITS_FILE))
    except (OSError, ValueError):
        cached = {}
    if time.time() - cached.get('checked', 0) < LIMITS_EVERY:
        return cached
    result = dict(cached, checked=time.time())
    try:
        result.update(fetch_limits(), fetched=time.time(), error=None)
    except (LimitsError, OSError, ValueError, KeyError, subprocess.SubprocessError) as e:
        result['error'] = str(e) if isinstance(e, LimitsError) else f"Couldn't reach Anthropic ({type(e).__name__})."
    try:
        os.makedirs(os.path.dirname(LIMITS_FILE), exist_ok=True)
        json.dump(result, open(LIMITS_FILE, 'w'))
    except OSError:
        pass
    return result


def analyze_all(count):
    """The `count` most recent conversations plus today's totals across every log.
    Results are remembered per file (size + modified time), so only logs that
    changed since the last scan are read again."""
    try:
        state = json.load(open(STATE_FILE))
        if state.get('version') != STATE_VERSION:
            state = {}
    except (OSError, ValueError):
        state = {}
    files = state.get('files', {})
    midnight = datetime.now().replace(hour=0, minute=0, second=0, microsecond=0).timestamp()
    paths = [p for pattern in LOG_GLOBS for p in glob.glob(pattern)]
    stats = {}
    for p in paths:
        try:
            st = os.stat(p)
        except OSError:
            continue
        stats[p] = st
    recent = sorted(stats, key=lambda p: stats[p].st_mtime, reverse=True)
    wanted = set(recent[:count * 3]) | {p for p in recent if stats[p].st_mtime >= midnight}
    fresh = {}
    for p in wanted:
        sig = [stats[p].st_size, stats[p].st_mtime]
        old = files.get(p)
        if old and old.get('sig') == sig:
            fresh[p] = old
            continue
        try:
            fresh[p] = {'sig': sig, 'conv': analyze(p)}
        except (OSError, RecursionError):
            continue
    try:
        os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
        tmp = STATE_FILE + '.tmp'
        json.dump({'version': STATE_VERSION, 'files': fresh}, open(tmp, 'w'))
        os.replace(tmp, STATE_FILE)
    except OSError:
        pass

    convs = [v['conv'] for v in fresh.values() if v.get('conv')]
    convs.sort(key=lambda c: c['when'], reverse=True)
    today = {'replies': 0, 'input': 0, 'written': 0, 'read': 0, 'output': 0,
             'restarts': 0, 'restart_tokens': 0, 'compactions': 0, 'conversations': 0}
    for c in convs:
        rows = [u for u in c['usage'] if u[0] >= midnight]
        if rows:
            today['conversations'] += 1
        for _, i, w, r, o in rows:
            today['replies'] += 1
            today['input'] += i
            today['written'] += w
            today['read'] += r
            today['output'] += o
        for t, n in c['restarts']:
            if t >= midnight:
                today['restarts'] += 1
                today['restart_tokens'] += n
        today['compactions'] += sum(1 for t in c['compactions'] if t >= midnight)
    shown = []
    for c in convs[:count]:
        c = {k: v for k, v in c.items() if k not in ('usage', 'restarts', 'compactions')}
        c['tips'] = tips_for(c)
        shown.append(c)
    return {'conversations': shown, 'today': today, 'tips': day_tips(today), 'limits': limits()}


def k(n):
    return f'{n / 1_000_000:.1f}M' if n >= 1_000_000 else f'{n / 1000:.1f}k' if n >= 1000 else str(int(n))


def tips_for(c):
    """What to do about this conversation's context, biggest win first."""
    ctx = c['context']
    parts = {p['key']: p['tokens'] for p in ctx['parts']}
    msgs = {p['key']: p['tokens'] for p in ctx['messages']}
    used, window = ctx['used'], ctx['window']
    tips = []
    if used > 0.6 * window:
        tips.append(f'Context is {used / window:.0%} full: /\u2060compact now, or start a new conversation for the next task.')
    elif used > 150_000:
        tips.append(f'{k(used)} goes with every message. Starting fresh for an unrelated task resets it to the baseline.')
    if msgs.get('images', 0) > 15_000:
        tips.append(f"Images take {k(msgs['images'])}. Read the page as text (read_page / get_page_text) instead of screenshots.")
    for g in ctx.get('groups', [])[:1]:
        if g['tokens'] > 20_000:
            hint = {
                'File reads': 'Read files with offset/limit, or grep for the part you need.',
                'Shell output': 'Pipe long output through head, tail or grep.',
                'Browser': 'Prefer find / get_page_text over full page reads and screenshots.',
                'Subagents': 'Ask subagents for a short summary.',
            }.get(g['label'], 'Ask for less output from it.')
            tips.append(f"{g['label']} hold {k(g['tokens'])}. {hint}")
    if parts.get('mcp', 0) > 10_000:
        tips.append(f"MCP tools cost {k(parts['mcp'])} on every request. Turn off servers this project doesn't use.")
    if parts.get('memory', 0) > 10_000:
        tips.append(f"Memory files are {k(parts['memory'])}. Trim CLAUDE.md or move rarely needed detail into linked docs.")
    if parts.get('skills', 0) > 8_000:
        tips.append(f"The skill list is {k(parts['skills'])}. Disable plugins you don't use.")
    if c['ttl'] == 300:
        tips.append('This conversation caches for only 5 minutes: a pause longer than that rewrites the whole context.')
    return tips[:3]


def day_tips(today):
    tips = []
    if today['restarts']:
        tips.append(f"{today['restarts']} cold restart{'s' if today['restarts'] != 1 else ''} today rewrote "
                    f"{k(today['restart_tokens'])}. Reply within the hour, or run /\u2060compact before a long break.")
    return tips


def scan(count):
    """The `count` conversations with the most recent replies."""
    files = [p for pattern in LOG_GLOBS for p in glob.glob(pattern)]
    # A log's modified time is its last activity; read a few spares in case
    # the newest-touched ones have no replies yet.
    files.sort(key=os.path.getmtime, reverse=True)
    found = []
    for path in files[:count * 3]:
        try:
            conv = read_conversation(path)
        except OSError:
            continue
        if conv:
            found.append(conv)
    found.sort(key=lambda c: c['when'], reverse=True)
    return found[:count]


def fmt_minutes(seconds):
    seconds = int(abs(seconds))
    return f'{seconds // 60}:{seconds % 60:02d}'


def put(win, y, x, text, attr=0):
    h, w = win.getmaxyx()
    if 0 <= y < h and x < w:
        win.addnstr(y, x, text, max(0, w - x - 1), attr)


def draw(win, convs, last_scan, every, colors):
    win.erase()
    h, w = win.getmaxyx()
    now = datetime.now(timezone.utc)
    put(win, 0, 1, 'Claude prompt cache', curses.A_BOLD)
    next_scan = max(0, every - (time.time() - last_scan))
    put(win, 0, 22, f'{len(convs)} most recent conversations · next scan in {int(next_scan)} s · r rescan · q quit',
        curses.A_DIM)
    if not convs:
        put(win, 2, 1, 'No conversation logs with replies found.')
    y = 2
    bar_w = max(10, min(40, w - 30))
    for c in convs:
        if y + 3 >= h:
            put(win, y, 1, '… enlarge the window to see more', curses.A_DIM)
            break
        left = c['ttl'] - (now - c['when']).total_seconds()
        if left <= 0:
            label, color = 'COLD', colors['cold']
            detail = f'expired {fmt_minutes(left)} ago; the next message rebuilds it'
        elif left < WARN_SECONDS:
            label, color = 'LOW ', colors['low']
            detail = f'{fmt_minutes(left)} left; send something soon to keep it'
        else:
            label, color = 'HOT ', colors['hot']
            detail = f'{fmt_minutes(left)} left'
        put(win, y, 1, f' {label} ', color | curses.A_BOLD | curses.A_REVERSE)
        put(win, y, 9, c['title'], curses.A_BOLD)
        put(win, y + 1, 9, f"{c['project']} · last reply {c['when'].astimezone():%b %d %H:%M:%S} · "
                           f"{c['ttl'] // 60}-min cache · {c['cached']:,} cached tokens", curses.A_DIM)
        filled = round(bar_w * max(0, left) / c['ttl'])
        put(win, y + 2, 9, '█' * filled, color)
        put(win, y + 2, 9 + filled, '░' * (bar_w - filled), curses.A_DIM)
        put(win, y + 2, 11 + bar_w, detail)
        y += 4
    win.refresh()


def main(stdscr, count, every):
    curses.curs_set(0)
    stdscr.timeout(1000)  # redraw the countdown every second
    colors = {'hot': 0, 'low': 0, 'cold': 0}
    if curses.has_colors():
        curses.use_default_colors()
        for i, (name, fg) in enumerate([('hot', curses.COLOR_GREEN), ('low', curses.COLOR_YELLOW),
                                        ('cold', curses.COLOR_RED)], start=1):
            curses.init_pair(i, fg, -1)
            colors[name] = curses.color_pair(i)
    convs, last_scan = scan(count), time.time()
    while True:
        if time.time() - last_scan >= every:
            convs, last_scan = scan(count), time.time()
        draw(stdscr, convs, last_scan, every, colors)
        key = stdscr.getch()
        if key in (ord('q'), ord('Q'), 27):
            return
        if key in (ord('r'), ord('R')):
            convs, last_scan = scan(count), time.time()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('-n', '--count', type=int, default=5, help='conversations to show (default 5)')
    parser.add_argument('-e', '--every', type=int, default=5, help='seconds between scans (default 5)')
    parser.add_argument('--json', action='store_true',
                        help='print one scan as JSON and exit (what the menu bar app reads)')
    args = parser.parse_args()
    if args.json:
        print(json.dumps(analyze_all(max(1, args.count))))
        raise SystemExit
    try:
        curses.wrapper(main, max(1, args.count), max(1, args.every))
    except KeyboardInterrupt:
        pass
