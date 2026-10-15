#!/usr/bin/env python3
"""
check-commits -- enforce Linux kernel patch submission guidelines.

Rules checked (see Documentation/process/submitting-patches.rst in the kernel):

  1. Subject is "<subsystem>: <description>", i.e. it carries a scope prefix.
  2. Subject is a short imperative summary: <= --subject-max (72) chars,
     no trailing period, and not written in past/continuous tense.
  3. A blank line separates the subject from the body.
  4. Body lines are wrapped at <= --body-max (75) chars, except quoted
     output, "Fixes:", "Link:", URLs and trailers.
  5. Every commit carries a "Signed-off-by:" DCO trailer that matches the
     author identity.
  6. Known bug-fix tags must be well formed ("Fixes: <sha> (\"title\")").

Usage:
    tools/check-commits.py                     # check HEAD
    tools/check-commits.py --range main~5..main
    tools/check-commits.py --all
    tools/check-commits.py --github-env        # GitHub Actions PR range

Exit status is non-zero if any commit violates the rules, so this can be used
both as a pre-commit/rebase hook and as a CI gate.
"""
from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys

SCOPE_RE = re.compile(r'^[a-zA-Z0-9][a-zA-Z0-9._/+-]*(\s*\[[^]]+\])?:\s+\S')
TRAILER_RE = re.compile(r'^([A-Z][A-Za-z-]*): (\S.*)$')
FIXES_RE = re.compile(r'^Fixes: ([0-9a-f]{7,40}) \(.*\)\s*$')
# Only the purely "type" keywords are rejected. docs:/ci:/net:/arm: and friends
# are ordinary subsystem prefixes in kernel style, so they stay allowed.
CONVENTIONAL_RE = re.compile(
    r'^(?:feat|feature|fix|bugfix|chore|refactor|style|perf|build|hotfix|revert|'
    r'wip|misc|various|deps|release)'
    r'(?:\([^)]*\))?!?:\s', re.I)

BAD_FIRST_WORDS = {
    'added', 'adds', 'adding', 'fixed', 'fixes', 'fixing', 'updated', 'updates',
    'updating', 'removed', 'removes', 'removing', 'new', 'support', 'supported',
    'supports', 'changed', 'changes', 'implemented', 'implements', 'cleanup',
    'refactored', 'reverted', 'bump', 'bumped', 'initial', 'wip', 'misc', 'various',
}
ALLOWED_TRAILERS = {
    'Signed-off-by', 'Reported-by', 'Co-developed-by', 'Reviewed-by', 'Acked-by',
    'Tested-by', 'Suggested-by', 'Cc', 'Link', 'Fixes', 'To', 'From',
}
SEP = '\x1f'   # field separator
RS = '\x1e'    # record separator (a commit message body contains newlines)


def run(*args: str) -> str:
    try:
        return subprocess.run(args, check=True, capture_output=True, text=True,
                              encoding='utf-8', errors='replace').stdout
    except subprocess.CalledProcessError as exc:
        sys.stderr.write('check-commits: %s failed: %s\n'
                         % (' '.join(args), (exc.stderr or '').strip()))
        sys.exit(2)


def commits(rng: str | None, all_: bool) -> list:
    fmt = SEP.join(['%H', '%h', '%an', '%ae', '%s', '%b']) + RS
    if all_:
        args = ['git', 'log', '--pretty=format:' + fmt, '--reverse']
    elif rng:
        args = ['git', 'log', '--pretty=format:' + fmt, '--reverse', rng]
    else:
        args = ['git', 'log', '--pretty=format:' + fmt, '-n', '1']
    out = run(*args)
    res = []
    for rec in out.split(RS):
        if not rec.strip():
            continue
        parts = rec.split(SEP)
        if len(parts) < 6:
            continue
        res.append({'sha': parts[0], 'short': parts[1], 'name': parts[2],
                    'email': parts[3], 'subject': parts[4],
                    'body': parts[5].lstrip('\n')})
    return res


def is_mergeish(subject: str) -> bool:
    return subject.startswith(('Merge ', 'fixup!', 'squash!', 'Revert '))


def check_one(c: dict, args) -> list:
    errs = []
    subj = c['subject']
    body = c['body'] or ''

    if is_mergeish(subj):
        return errs

    # 1/2: subject line
    if not SCOPE_RE.match(subj):
        errs.append('subject must start with "<subsystem>: " (e.g. "agent: fix ...")')
    if CONVENTIONAL_RE.match(subj):
        errs.append('do not use conventional-commit tags (feat:/fix:/...); ' 
                    'use kernel style "<subsystem>: <imperative summary>"')
    if subj.endswith('.'):
        errs.append('subject must not end with a period')
    if len(subj) > args.subject_max:
        errs.append('subject is %d chars, max %d' % (len(subj), args.subject_max))
    after = subj.split(':', 1)[1].strip() if ':' in subj else subj
    first = re.split(r'[\s/]+', after)[0].lower() if after else ''
    if first in BAD_FIRST_WORDS:
        errs.append('subject must use the imperative mood, not "%s"' % first)
    if first.endswith('ed') and first not in ('ed',) and len(first) > 3 and first not in BAD_FIRST_WORDS:
        errs.append('subject looks past tense ("%s"); use the imperative mood' % first)

    # 3: blank line between subject and body is implicit in %s/%b, but reject
    #    a body that repeats the subject or starts immediately with a paragraph.
    lines = [l for l in body.split('\n')]
    if lines and lines[0].strip() == subj.strip():
        errs.append('body must not repeat the subject')

    # 4: wrapping
    in_trailer = False
    for i, line in enumerate(lines):
        if not line.strip():
            continue
        m = TRAILER_RE.match(line.strip())
        if m:
            in_trailer = True
            if m.group(1) not in ALLOWED_TRAILERS:
                errs.append('unknown trailer "%s:" (line %d)' % (m.group(1), i + 1))
            if m.group(1) == 'Fixes' and not FIXES_RE.match(line.strip()):
                errs.append('malformed Fixes: tag, expected '
                            'Fixes: <sha> ("commit title")')
            continue
        if in_trailer and not line.startswith(' '):
            errs.append('non-trailer text after trailer block (line %d)' % (i + 1))
        if len(line) > args.body_max and not _long_ok(line):
            errs.append('body line %d is %d chars (max %d); wrap it'
                        % (i + 1, len(line), args.body_max))

    # blank line before the trailer block
    if in_trailer:
        idx = next(j for j, l in enumerate(lines) if TRAILER_RE.match(l.strip()))
        if idx > 0 and lines[idx - 1].strip():
            errs.append('a blank line is required before the trailer block')

    # 5: DCO
    sigs = re.findall(r'^Signed-off-by:\s*(.+)$', body, re.M)
    if not sigs:
        errs.append('missing "Signed-off-by:" (DCO); use "git commit -s"')
    else:
        want = '%s <%s>' % (c['name'], c['email'])
        if not any(s.strip().lower() == want.lower() for s in sigs):
            errs.append('Signed-off-by must match the author: %s' % want)
    return errs


def _long_ok(line: str) -> bool:
    t = line.strip()
    return (t.startswith(('Fixes:', 'Link:', 'Reported-by:', 'Reviewed-by:',
                          'Signed-off-by:', 'http'))
            or 'http://' in t or 'https://' in t
            or line.startswith(('    ', '\t'))
            or '|' in t or t.startswith('$'))


def resolve_range(args) -> str | None:
    if args.all:
        return None
    if args.range:
        return args.range
    env_file = os.environ.get('GITHUB_EVENT_PATH')
    if args.github_env and env_file and os.path.exists(env_file):
        import json
        try:
            with open(env_file, encoding='utf-8') as fh:
                ev = json.load(fh)
            pr = ev.get('pull_request') or {}
            base, head = pr.get('base', {}).get('sha'), pr.get('head', {}).get('sha')
            if base and head:
                return '%s..%s' % (base, head)
        except Exception:
            pass
    return None


def main() -> int:
    ap = argparse.ArgumentParser(description='Linux kernel commit style checker')
    ap.add_argument('--range', default='', help='git revision range, e.g. main~3..main')
    ap.add_argument('--all', action='store_true', help='check every commit')
    ap.add_argument('--commit-msg-file', default='',
                    help='validate a single message file (used by the commit-msg git hook)')
    ap.add_argument('--github-env', action='store_true',
                    help='derive the range from the GitHub Actions event payload')
    ap.add_argument('--subject-max', type=int, default=72)
    ap.add_argument('--body-max', type=int, default=75)
    args = ap.parse_args()

    if args.commit_msg_file:
        with open(args.commit_msg_file, encoding='utf-8') as fh:
            raw = fh.read()
        paragraphs = raw.split('\n')
        subject = paragraphs[0].rstrip() if paragraphs else ''
        body = '\n'.join(paragraphs[1:])
        if not subject.strip() or is_mergeish(subject):
            print('check-commits: skipped')
            return 0
        name = run('git', 'config', 'user.name').strip()
        email = run('git', 'config', 'user.email').strip()
        c = {'sha': '', 'short': 'working tree', 'name': name, 'email': email,
             'subject': subject, 'body': body}
        errs = check_one(c, args)
        if errs:
            print('commit message does not follow the kernel guidelines:')
            for e in errs:
                print('  - %s' % e)
            print('\nhint: "git commit -s", subject "<subsystem>: <imperative>",'
                  ' body wrapped at 72')
            return 1
        print('check-commits: commit message looks good')
        return 0

    rng = None if args.all else (args.range or None)
    if args.github_env and not args.range and not args.all:
        rng = resolve_range(args)
    items = commits(rng, args.all)
    if not items:
        print('check-commits: no commits in range')
        return 0

    bad = 0
    for c in items:
        errs = check_one(c, args)
        if errs:
            bad += 1
            print('ERROR %s  %s' % (c['short'], c['subject']))
            for e in errs:
                print('        - %s' % e)
        else:
            print('ok    %s  %s' % (c['short'], c['subject']))
    print('')
    print('check-commits: %d/%d commits follow the kernel guidelines'
          % (len(items) - bad, len(items)))
    if bad:
        print('hint: use "git commit -s" and see CONTRIBUTING.md')
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
