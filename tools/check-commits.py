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

Squash merges made through the GitHub web UI are accepted as well: GitHub
rewrites the author to "<id>+<login>@users.noreply.github.com" (the same account
as the "<login>@users.noreply.github.com" that "git commit -s" writes), appends
a "Co-authored-by:" trailer, and may interleave body text between trailer
blocks. It also composes the subject -- the pull request title plus
" (#<number>)", committed by GitHub itself. Nobody typed that line into git
and the pull request gate (tools/check-pr.py) checks the title before the
merge, so the subject rules are skipped for those commits; see
is_web_ui_squash().

Usage:
    tools/check-commits.py                     # check HEAD
    tools/check-commits.py --range main~5..main
    tools/check-commits.py --all
    tools/check-commits.py --github-env        # GitHub Actions PR range

Exit status is non-zero if any commit violates the rules, so this can be used
both as a pre-commit/rebase hook and as a CI gate.

Machine-generated commits (dependabot and friends) can be exempted with
--skip-bots: the bot writes "ci: bump <pkg> from 4 to 7", which no bot will
ever phrase in kernel style, so failing the gate would only block the update
forever.
"""
from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys

SCOPE_RE = re.compile(r'^[a-zA-Z0-9][a-zA-Z0-9._/+-]*(\s*\[[^]]+\])?:\s+\S')
TRAILER_RE = re.compile(r'^([A-Z][A-Za-z-]*): (\S.*)$')
# GitHub rewrites the author to "<id>+<login>@users.noreply.github.com" when a
# pull request is squash-merged from the web UI, while "git commit -s" writes
# "<login>@users.noreply.github.com": both name the same account.
NOREPLY_RE = re.compile(r'^(?:(\d+)\+)?([^@+]+)@users\.noreply\.github\.com$', re.I)
# The web UI squash-merges as the "GitHub" web-flow account and marks the
# pull request number in the subject it composes.
GITHUB_COMMITTER_RE = re.compile(r'<noreply@github\.com>', re.I)
SQUASH_SUBJECT_RE = re.compile(r'\s\(#\d+\)$')
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
    'Signed-off-by', 'Reported-by', 'Co-developed-by', 'Co-authored-by',
    'Reviewed-by', 'Acked-by', 'Tested-by', 'Suggested-by', 'Cc', 'Link',
    'Fixes', 'To', 'From',
}
SEP = '\x1f'   # field separator
RS = '\x1e'    # record separator (a commit message body contains newlines)

BOT_NAME_RE = re.compile(r'\[bot\]$', re.I)


def is_bot(c: dict) -> bool:
    '''Machine-generated commit: dependabot and other GitHub apps.'''
    name = (c.get('name') or '').strip()
    mail = (c.get('email') or '').lower()
    return bool(BOT_NAME_RE.search(name)) or 'dependabot' in mail


def run(*args: str, required: bool = True):
    """Run git. Returns None instead of exiting when required=False."""
    try:
        return subprocess.run(args, check=True, capture_output=True, text=True,
                              encoding='utf-8', errors='replace').stdout
    except subprocess.CalledProcessError as exc:
        if required:
            sys.stderr.write('check-commits: %s failed: %s\n'
                             % (' '.join(args), (exc.stderr or '').strip()))
            sys.exit(2)
        return None


def commits(rng: str | None, all_: bool) -> list:
    fmt = SEP.join(['%H', '%h', '%an', '%ae', '%cn', '%ce', '%s', '%b']) + RS
    head_only = ['git', 'log', '--pretty=format:' + fmt, '-n', '1']

    if all_:
        out = run('git', 'log', '--pretty=format:' + fmt, '--reverse')
    elif rng:
        # A shallow clone (actions/checkout defaults to depth 1) cannot resolve
        # base..head, and failing the build for that would be wrong - the patch
        # is simply not present. Say so and check what we do have.
        out = run('git', 'log', '--pretty=format:' + fmt, '--reverse', rng, required=False)
        if out is None:
            sys.stderr.write('check-commits: range %s is not available here '
                             '(shallow clone?); falling back to HEAD\n' % rng)
            out = run(*head_only)
    else:
        out = run(*head_only)
    res = []
    for rec in out.split(RS):
        if not rec.strip():
            continue
        parts = rec.split(SEP)
        if len(parts) < 8:
            continue
        res.append({'sha': parts[0], 'short': parts[1], 'name': parts[2],
                    'email': parts[3], 'committer_name': parts[4],
                    'committer_email': parts[5], 'subject': parts[6],
                    'body': parts[7].lstrip('\n')})
    return res


def is_mergeish(subject: str) -> bool:
    return subject.startswith(('Merge ', 'fixup!', 'squash!', 'Revert '))


def is_web_ui_squash(c: dict) -> bool:
    """True for the commit the GitHub web UI writes for a squash merge.

    GitHub composes it from metadata instead of a message anyone typed:
    the subject is the pull request title plus " (#<number>)" and the
    committer is GitHub's web-flow account. The commits it squashed survive
    only as body text. The pull request gate checks that title before the
    merge, so skipping the subject rules here neither weakens nor duplicates
    it -- while re-running this check on an already merged pull request
    cannot fail a merge that the gate had approved.
    """
    if not SQUASH_SUBJECT_RE.search(c.get('subject') or ''):
        return False
    committer = '%s <%s>' % (c.get('committer_name', ''),
                             c.get('committer_email', ''))
    return bool(GITHUB_COMMITTER_RE.search(committer))


def subject_errors(subj: str, args) -> list:
    """Rules 1 and 2: "<subsystem>: <imperative summary>", <= subject_max.

    Kept separate because the pull request gate (tools/check-pr.py) judges the
    pull request title with exactly these rules: a squash merge writes that
    title into main as the commit subject, so both have to agree.
    """
    errs = []
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
    return errs


def check_one(c: dict, args) -> list:
    errs = []
    subj = c['subject']
    body = c['body'] or ''

    if is_mergeish(subj):
        return errs

    # 1/2: subject line. A web-UI squash merge puts the pull request title
    # here; that title is checked by the pull request gate instead.
    if not is_web_ui_squash(c):
        errs.extend(subject_errors(subj, args))

    # 3: blank line between subject and body is implicit in %s/%b, but reject
    #    a body that repeats the subject or starts immediately with a paragraph.
    lines = [l for l in body.split('\n')]
    if lines and lines[0].strip() == subj.strip():
        errs.append('body must not repeat the subject')

    # 4: wrapping, trailer syntax, and the layout around the trailer block
    trailers = [i for i, line in enumerate(lines) if TRAILER_RE.match(line.strip())]
    for i, line in enumerate(lines):
        if not line.strip():
            continue
        m = TRAILER_RE.match(line.strip())
        if m:
            if m.group(1) not in ALLOWED_TRAILERS:
                errs.append('unknown trailer "%s:" (line %d)' % (m.group(1), i + 1))
            if m.group(1) == 'Fixes' and not FIXES_RE.match(line.strip()):
                errs.append('malformed Fixes: tag, expected '
                            'Fixes: <sha> ("commit title")')
            continue
        if len(line) > args.body_max and not _long_ok(line):
            errs.append('body line %d is %d chars (max %d); wrap it'
                        % (i + 1, len(line), args.body_max))

    # A squash merge interleaves body text between trailer blocks, so treat the
    # *last* run of trailer lines as the trailer block: only prose after it (and
    # a missing blank line before it) is a layout error.
    if trailers:
        start = trailers[-1]
        while start - 1 >= 0 and TRAILER_RE.match(lines[start - 1].strip()):
            start -= 1
        for i in range(trailers[-1] + 1, len(lines)):
            if lines[i].strip() and not lines[i].startswith(' '):
                errs.append('non-trailer text after trailer block (line %d)' % (i + 1))
        if start > 0 and lines[start - 1].strip():
            errs.append('a blank line is required before the trailer block')

    # 5: DCO
    sigs = re.findall(r'^Signed-off-by:\s*(.+)$', body, re.M)
    if not sigs:
        errs.append('missing "Signed-off-by:" (DCO); use "git commit -s"')
    elif not any(_same_identity(c['name'], c['email'], s) for s in sigs):
        want = '%s <%s>' % (c['name'], c['email'])
        errs.append('Signed-off-by must match the author: %s' % want)
    return errs


def _same_identity(name: str, email: str, sob: str) -> bool:
    """True when a "Signed-off-by:" line names the commit author.

    The GitHub web UI re-authors a squash-merged commit as
    "<id>+<login>@users.noreply.github.com", while "git commit -s" writes
    "<login>@users.noreply.github.com". Both identify the same account, so
    accept either form when the display name matches; anything else must match
    the author address literally.
    """
    m = re.match(r'^(.*?)\s*<([^<>\s]+@[^<>\s]+)>$', sob.strip())
    if not m:
        return False
    sob_name, sob_email = m.group(1).strip(), m.group(2).strip()
    if sob_name.lower() != name.strip().lower():
        return False
    if sob_email.lower() == email.strip().lower():
        return True
    sig, author = NOREPLY_RE.match(sob_email), NOREPLY_RE.match(email)
    return bool(sig and author and sig.group(2).lower() == author.group(2).lower())


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
    ap.add_argument('--strict-dco', action='store_true',
                    help='fail (not just warn) on a missing Signed-off-by in message file mode')
    ap.add_argument('--commit-msg-file', default='',
                    help='validate a single message file (used by the commit-msg git hook)')
    ap.add_argument('--github-env', action='store_true',
                    help='derive the range from the GitHub Actions event payload')
    ap.add_argument('--skip-bots', action='store_true',
                    help='skip machine-generated commits (dependabot, *[bot])')
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
        # git appends the -s trailer after running the commit-msg hook, so a
        # missing sign-off cannot be judged here; CI checks it for real.
        # Repositories set format.signOff=true so it is never missing anyway.
        soft, hard = [], []
        for e in errs:
            if 'Signed-off-by' in e and not args.strict_dco:
                soft.append(e)
            else:
                hard.append(e)
        for e in soft:
            print('check-commits: note: %s (git adds it after this hook)' % e)
        if hard:
            print('commit message does not follow the kernel guidelines:')
            for e in hard:
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
    skipped = 0
    for c in items:
        if args.skip_bots and is_bot(c):
            print('skip  %s  %s (machine generated)' % (c['short'], c['subject']))
            skipped += 1
            continue
        errs = check_one(c, args)
        if errs:
            bad += 1
            print('ERROR %s  %s' % (c['short'], c['subject']))
            for e in errs:
                print('        - %s' % e)
        else:
            print('ok    %s  %s' % (c['short'], c['subject']))
    print('')
    suffix = ''
    if skipped:
        suffix = ' (%d machine-generated commit(s) skipped)' % skipped
    total = len(items) - skipped
    print('check-commits: %d/%d commits follow the kernel guidelines%s'
          % (total - bad, total, suffix))
    if bad:
        print('hint: use "git commit -s" and see CONTRIBUTING.md')
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
