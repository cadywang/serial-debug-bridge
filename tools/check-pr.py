#!/usr/bin/env python3
"""
check-pr -- the pull request gate: title style and the merge checklist.

The commit style gate (tools/check-commits.py) judges the commits a branch
carries. Two things exist only on the pull request itself:

  1. the title. The GitHub web UI writes it into main as the subject of the
     squash commit, so a sloppy title lands in permanent history; and because
     that only happens at merge time, the commit gate can do nothing but
     complain afterwards, on a branch that cannot be rewritten.
  2. the checklist. .github/pull_request_template.md promises that the
     self-tests ran, that the four implementations were kept in sync and so
     on, and nothing forced anyone to actually tick those boxes.

The title is judged with the same rules as a commit subject -- literally the
same function, so "kernel style" has one definition -- and the checklist is
read out of the template: every item of its "合并前清单" section has to be
ticked in the pull request body. Changing that list means changing the
template, and the template has to pass this gate as well, so the list cannot
be softened in passing.

Usage:
    tools/check-pr.py --title "agent: fix the framing" --body-file pr.md
    tools/check-pr.py --github-env              # in CI, from the event payload

Exit status is non-zero when the pull request cannot be merged as it stands.

Machine-generated pull requests (dependabot and friends) are exempt: they can
neither write a kernel-style title nor tick a checklist, so failing them would
only park the dependency update forever (tools/check-commits.py has the same
allowance).
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
DEFAULT_TEMPLATE = ROOT / '.github' / 'pull_request_template.md'
SECTION_RE = re.compile(r'^#{2,4}\s*合并前清单\s*$')
HEADING_RE = re.compile(r'^#{2,4}\s+\S')
ITEM_RE = re.compile(r'^\s*[-*]\s*\[( |x|X)\]\s*(.+?)\s*$')
BOT_RE = re.compile(r'\[bot\]$', re.I)


def load_check_commits():
    """Import tools/check-commits.py (its name cannot be imported directly)."""
    spec = importlib.util.spec_from_file_location(
        'check_commits', ROOT / 'tools' / 'check-commits.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def normalize(text: str) -> str:
    """Compare checklist items by their words, not by their spacing."""
    return re.sub(r'\s+', ' ', str(text or '')).strip().lower()


def checklist(template: str) -> list:
    """Items of the template's "合并前清单" section, or None if it is gone."""
    lines = template.replace('\r\n', '\n').replace('\r', '\n').split('\n')
    start = -1
    for i, line in enumerate(lines):
        if SECTION_RE.match(line):
            start = i
            break
    if start < 0:
        return None
    items = []
    for line in lines[start + 1:]:
        if HEADING_RE.match(line):
            break
        m = ITEM_RE.match(line)
        if m:
            items.append(normalize(m.group(2)))
    return items


def ticked_items(body: str) -> set:
    """Normalized text of every ticked checkbox line in a pull request body."""
    ticked = set()
    for line in str(body or '').replace('\r\n', '\n').replace('\r', '\n').split('\n'):
        m = ITEM_RE.match(line)
        if m and m.group(1).lower() == 'x':
            ticked.add(normalize(m.group(2)))
    return ticked


def main() -> int:
    ap = argparse.ArgumentParser(description='pull request title + checklist gate')
    ap.add_argument('--title', default='', help='pull request title')
    ap.add_argument('--body', default='', help='pull request body')
    ap.add_argument('--body-file', default='', help='read the body from this file')
    ap.add_argument('--author', default='', help='pull request author login')
    ap.add_argument('--template', default=str(DEFAULT_TEMPLATE),
                    help='pull request template to read the checklist from')
    ap.add_argument('--github-env', action='store_true',
                    help='take title/body/author from the GitHub Actions event payload')
    ap.add_argument('--subject-max', type=int, default=72,
                    help='maximum title length (same default as check-commits.py)')
    args = ap.parse_args()

    title, body, author = args.title, args.body, args.author
    if args.github_env:
        event_path = os.environ.get('GITHUB_EVENT_PATH', '')
        if not event_path or not os.path.exists(event_path):
            sys.stderr.write('check-pr: GITHUB_EVENT_PATH is not set\n')
            return 2
        with open(event_path, encoding='utf-8') as fh:
            event = json.load(fh)
        pr = event.get('pull_request') or {}
        title = pr.get('title') or ''
        body = pr.get('body') or ''
        author = (pr.get('user') or {}).get('login') or ''
    if args.body_file:
        body = pathlib.Path(args.body_file).read_text(encoding='utf-8')
    if not title and not body:
        sys.stderr.write('check-pr: nothing to check: pass --title/--body, '
                         '--body-file or --github-env\n')
        return 2

    if BOT_RE.search(author.strip()):
        print('check-pr: author is a bot (%s); skipped' % author)
        return 0

    bad = 0

    # 1) The title is what a squash merge writes into main, so it follows the
    #    commit subject rules -- the same function the commit gate uses.
    checker = load_check_commits()
    shared = argparse.Namespace(subject_max=args.subject_max, body_max=75)
    title = title.strip()
    if not title:
        print('::error::pull request has no title; use '
              '"<subsystem>: <imperative summary>"')
        bad = 1
    else:
        for err in checker.subject_errors(title, shared):
            print('::error::title: %s' % err)
            bad = 1

    # 2) Every checklist item the template promises has to be ticked.
    expected = checklist(pathlib.Path(args.template).read_text(encoding='utf-8'))
    if not expected:
        print('::error::no "合并前清单" section found in %s; the gate has nothing '
              'to read' % args.template)
        bad = 1
    elif not normalize(body):
        print('::error::pull request body is empty; fill in the template and tick '
              'the "合并前清单" items')
        bad = 1
    else:
        ticked = ticked_items(body)
        missing = [item for item in expected if item not in ticked]
        if missing:
            print('::error::"合并前清单" still has %d unticked item(s), so this '
                  'pull request cannot merge:' % len(missing))
            for item in missing:
                print('::error::unticked: %s' % item)
            bad = 1

    if bad:
        print('')
        print('check-pr: see CONTRIBUTING.md (PR flow) and REVIEW_POLICY.md '
              '(gates, sync list)')
        return 1
    print('check-pr: title and "%d" checklist items look fine' % len(expected))
    return 0


if __name__ == '__main__':
    sys.exit(main())