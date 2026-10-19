#!/usr/bin/env python3
"""Self-test for tools/check-pr.py.

The pull request gate is the only thing standing between a sloppy pull request
title -- which the GitHub web UI writes into main as the subject of the squash
commit -- and a red, unrewritable history; and between an unticked checklist
and a merge. Feed it the shapes it meets in practice, including the event
payload GitHub hands the workflow.

No third-party dependency: run with "python tests/test_check_pr.py".
"""
from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
import pathlib
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
_spec = importlib.util.spec_from_file_location('check_pr', ROOT / 'tools' / 'check-pr.py')
checker = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(checker)

TITLE = 'agent: free the serial port'
TEMPLATE = '''## 变更说明

## 合并前清单

- [ ] 本地 mock 自测已全部通过
- [ ] 四个实现已同步

## 关联 Issue

- [ ] 这一条在别的小节里，不参与校验
'''
NO_SECTION = '''## 变更说明

- [ ] 模板被人改坏了，找不到清单小节
'''

PASS = 0
FAIL = 0


def check(desc, ok, detail=''):
    global PASS, FAIL
    print('  [%s] %s' % ('PASS' if ok else 'FAIL', desc))
    if not ok:
        print('         %s' % detail)
    if ok:
        PASS += 1
    else:
        FAIL += 1


def make_body(missing=()):
    """A body that ticks every template item except the ones in `missing`."""
    lines = []
    for item in checker.checklist(TEMPLATE):
        lines.append('- [%s] %s' % (' ' if item in missing else 'x', item))
    return '\n'.join(lines) + '\n'


def run(args):
    """Run main() with argv replaced. Returns (status, stdout+stderr)."""
    out = io.StringIO()
    old = sys.argv
    sys.argv = ['check-pr.py'] + args
    try:
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
            status = checker.main()
    finally:
        sys.argv = old
    return status, out.getvalue()


def main():
    tmp = pathlib.Path(tempfile.mkdtemp(prefix='check-pr-'))
    template = tmp / 'template.md'
    template.write_text(TEMPLATE, encoding='utf-8')
    broken = tmp / 'broken.md'
    broken.write_text(NO_SECTION, encoding='utf-8')
    full = tmp / 'full.md'
    full.write_text(make_body(), encoding='utf-8')
    partial = tmp / 'partial.md'
    partial.write_text(make_body(missing=('四个实现已同步',)), encoding='utf-8')
    empty = tmp / 'empty.md'
    empty.write_text('', encoding='utf-8')

    def with_body(path, title=TITLE, extra=()):
        return run(['--title', title, '--body-file', str(path),
                    '--template', str(template)] + list(extra))

    print('title')
    status, _ = with_body(full)
    check('kernel-style title with the checklist ticked', status == 0, 'status=%d' % status)
    status, out = with_body(full, title='Free the serial port')
    check('title without a "<subsystem>: " prefix is rejected',
          status == 1 and 'title' in out, 'status=%d' % status)
    status, _ = with_body(full, title='fix: free the serial port')
    check('conventional-commit title is rejected', status == 1, 'status=%d' % status)
    status, _ = with_body(full, title=TITLE + '.')
    check('title ending with a period is rejected', status == 1, 'status=%d' % status)
    status, _ = with_body(full, title='agent: free ' + 'x' * 80)
    check('over-long title is rejected', status == 1, 'status=%d' % status)
    status, _ = with_body(full, title='agent: freed the serial port')
    check('past-tense title is rejected', status == 1, 'status=%d' % status)

    print('checklist')
    status, out = with_body(partial)
    check('an unticked item fails the gate', status == 1, 'status=%d' % status)
    check('the failure names the item that is missing',
          '四个实现已同步' in out, out.strip())
    status, _ = with_body(empty)
    check('an empty body fails the gate', status == 1, 'status=%d' % status)
    status, _ = with_body(full, extra=['--author', 'dependabot[bot]'])
    check('a bot author is skipped', status == 0, 'status=%d' % status)
    nolist = tmp / 'nolist.md'
    nolist.write_text('## 变更说明\n\n写了说明，但一条都没勾。\n', encoding='utf-8')
    status, out = with_body(nolist)
    check('a body with no ticked box at all fails',
          status == 1 and 'unticked' in out, out.strip())

    print('template and body must agree on the wording')
    reworded = tmp / 'reworded.md'
    reworded.write_text('- [x] mock self-tests passed\n- [x] four implementations updated\n',
                        encoding='utf-8')
    status, out = run(['--title', TITLE, '--body-file', str(reworded),
                       '--template', str(template)])
    check('re-wording a template item does not count as ticking it',
          status == 1, out.strip())
    extra = tmp / 'extra.md'
    extra.write_text(make_body() + '- [x] 顺手勾了一条不存在的项\n', encoding='utf-8')
    status, _ = with_body(extra)
    check('extra ticked boxes are ignored', status == 0, 'status=%d' % status)
    status, out = run(['--title', TITLE, '--body-file', str(full),
                       '--template', str(broken)])
    check('a template without the checklist section is an error',
          status == 1 and '合并前清单' in out, out.strip())

    print('GitHub Actions payload')
    event = tmp / 'event.json'
    event.write_text(json.dumps({'pull_request': {
        'title': TITLE, 'body': make_body(), 'user': {'login': 'cadywang'}}}), encoding='utf-8')
    old_env = os.environ.get('GITHUB_EVENT_PATH')
    os.environ['GITHUB_EVENT_PATH'] = str(event)
    try:
        status, out = run(['--github-env', '--template', str(template)])
        check('a good pull request passes through the event payload',
              status == 0, 'status=%d %s' % (status, out.strip()))
        event.write_text(json.dumps({'pull_request': {
            'title': 'Agent/shutdown op', 'body': make_body(),
            'user': {'login': 'cadywang'}}}), encoding='utf-8')
        status, out = run(['--github-env', '--template', str(template)])
        check('the event payload title is judged too', status == 1, out.strip())
        event.write_text(json.dumps({'pull_request': {
            'title': TITLE, 'body': make_body(missing=('本地 mock 自测已全部通过',)),
            'user': {'login': 'cadywang'}}}), encoding='utf-8')
        status, out = run(['--github-env', '--template', str(template)])
        check('a payload with an unticked box fails', status == 1, out.strip())
    finally:
        if old_env is None:
            os.environ.pop('GITHUB_EVENT_PATH', None)
        else:
            os.environ['GITHUB_EVENT_PATH'] = old_env

    print('usage')
    status, _ = run([])
    check('no input at all is a usage error', status == 2, 'status=%d' % status)

    print('')
    print('RESULT: %d passed, %d failed' % (PASS, FAIL))
    return 1 if FAIL else 0


if __name__ == '__main__':
    sys.exit(main())