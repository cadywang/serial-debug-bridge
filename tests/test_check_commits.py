#!/usr/bin/env python3
"""Self-test for tools/check-commits.py.

The gate fails real merges when it only knows the shape of a locally authored
commit. Feed it the shapes it meets in practice: a local commit, and the
commits the GitHub web UI creates when a pull request is squash-merged
(author re-written to the "<id>+<login>@users.noreply.github.com" form, an
extra "Co-authored-by:" trailer, body text interleaved between trailers).

No third-party dependency: run with "python tests/test_check_commits.py".
"""
from __future__ import annotations

import argparse
import importlib.util
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
ARGS = argparse.Namespace(subject_max=72, body_max=75)

_spec = importlib.util.spec_from_file_location(
    'check_commits', ROOT / 'tools' / 'check-commits.py')
checker = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(checker)

PLAIN = 'cadywang@users.noreply.github.com'
ID_FORM = '109458837+cadywang@users.noreply.github.com'
SUBJECT = 'agent: keep the final serial chunk undrained'

PASS = 0
FAIL = 0


def commit(subject, body, email=PLAIN, name='cadywang', committer=None):
    """One commit record, shaped the way commits() builds them.

    committer defaults to the author: a commit someone wrote locally. Pass
    ('GitHub', 'noreply@github.com') for what the web UI commits when it
    squash-merges a pull request.
    """
    cname, cemail = committer if committer else (name, email)
    return {'sha': '0' * 40, 'short': 'abcdef1', 'name': name, 'email': email,
            'committer_name': cname, 'committer_email': cemail,
            'subject': subject, 'body': body}


def check(desc, c, want_ok):
    global PASS, FAIL
    errs = checker.check_one(c, ARGS)
    ok = not errs if want_ok else bool(errs)
    print('  [%s] %s' % ('PASS' if ok else 'FAIL', desc))
    if not ok:
        for e in errs:
            print('         %s' % e)
    if ok:
        PASS += 1
    else:
        FAIL += 1


def main():
    print('locally authored commit')
    check('plain sign-off matches the author',
          commit(SUBJECT, '\nExplain why the chunk must be drained.\n\n'
                          'Signed-off-by: cadywang <%s>\n' % PLAIN), True)
    check('sign-off wrapped in extra spaces is accepted',
          commit(SUBJECT, '\nExplain why.\n\n'
                          'Signed-off-by:   cadywang   <%s>  \n' % PLAIN), True)
    check('missing sign-off is rejected',
          commit(SUBJECT, '\nExplain why.\n'), False)
    check('sign-off for another account is rejected',
          commit(SUBJECT, '\nExplain why.\n\n'
                          'Signed-off-by: someone <someone@example.com>\n'), False)
    check('same login on an unrelated domain is rejected',
          commit(SUBJECT, '\nExplain why.\n\n'
                          'Signed-off-by: cadywang <cadywang@example.com>\n'), False)
    check('same login under a different display name is rejected',
          commit(SUBJECT, '\nExplain why.\n\n'
                          'Signed-off-by: someone <%s>\n' % PLAIN), False)

    print('GitHub web UI squash merge')
    check('id-form author with a plain sign-off',
          commit(SUBJECT, '\nExplain why.\n\n'
                          'Signed-off-by: cadywang <%s>\n'
                          'Co-authored-by: cadywang <%s>\n' % (PLAIN, PLAIN),
                 email=ID_FORM), True)
    check('subject keeps the "(#7)" suffix the web UI adds',
          commit('%s (#7)' % SUBJECT,
                 '\nExplain why.\n\n'
                 'Signed-off-by: cadywang <%s>\n' % PLAIN, email=ID_FORM), True)
    check('body text interleaved between trailer blocks',
          commit('%s (#7)' % SUBJECT,
                 '\n* agent: keep the chunk undrained\n\nExplain why.\n\n'
                 'Signed-off-by: cadywang <%s>\n\n'
                 '* tests: cover the drained tail\n\nExplain that too.\n\n'
                 '---------\n\n'
                 'Signed-off-by: cadywang <%s>\n'
                 'Co-authored-by: cadywang <%s>\n'
                 % (PLAIN, PLAIN, ID_FORM), email=ID_FORM), True)

    print('web-UI squash merge composes the subject itself')
    GITHUB = ('GitHub', 'noreply@github.com')
    SQUASH_BODY = ('\n* agent: keep the chunk undrained\n\nExplain why.\n\n'
                   'Signed-off-by: cadywang <%s>\n\n'
                   '* tests: cover the drained tail\n\nExplain that too.\n\n'
                   '---------\n\n'
                   'Signed-off-by: cadywang <%s>\n'
                   'Co-authored-by: cadywang <%s>\n' % (PLAIN, PLAIN, ID_FORM))
    check('a pull request title that is not kernel style is accepted',
          commit('Agent/shutdown op (#7)', SQUASH_BODY, email=ID_FORM,
                 committer=GITHUB), True)
    check('the same subject written locally is still rejected',
          commit('Agent/shutdown op (#7)',
                 '\nExplain why.\n\n'
                 'Signed-off-by: cadywang <%s>\n' % PLAIN,
                 committer=('cadywang', PLAIN)), False)
    check('a GitHub committer without " (#n)" keeps the subject rules',
          commit('Agent/shutdown op',
                 '\nExplain why.\n\n'
                 'Signed-off-by: cadywang <%s>\n' % PLAIN,
                 committer=GITHUB), False)

    print('layout and subject rules still bite')
    check('prose after the final trailer block is rejected',
          commit(SUBJECT, '\nExplain why.\n\n'
                          'Signed-off-by: cadywang <%s>\n\n'
                          'Stray prose.\n' % PLAIN), False)
    check('no blank line before the trailer block is rejected',
          commit(SUBJECT, '\nExplain why.\n'
                          'Signed-off-by: cadywang <%s>\n' % PLAIN), False)
    check('unknown trailer is rejected',
          commit(SUBJECT, '\nExplain why.\n\n'
                          'Signed-off-by: cadywang <%s>\n'
                          'Whatever-by: nobody <nobody@example.com>\n' % PLAIN), False)
    check('conventional-commit tag is rejected',
          commit('feat: keep the final serial chunk undrained',
                 '\nExplain why.\n\n'
                 'Signed-off-by: cadywang <%s>\n' % PLAIN), False)
    check('past-tense subject is rejected',
          commit('agent: drained the final serial chunk',
                 '\nExplain why.\n\n'
                 'Signed-off-by: cadywang <%s>\n' % PLAIN), False)
    check('body line over the limit is rejected',
          commit(SUBJECT, '\n' + 'x' * 90 + '\n\n'
                          'Signed-off-by: cadywang <%s>\n' % PLAIN), False)

    print('')
    print('RESULT: %d passed, %d failed' % (PASS, FAIL))
    return 1 if FAIL else 0


if __name__ == '__main__':
    sys.exit(main())