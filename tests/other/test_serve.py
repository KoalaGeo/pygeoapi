# =================================================================
#
# Copyright (c) 2026 pygeoapi development team
#
# Permission is hereby granted, free of charge, to any person
# obtaining a copy of this software and associated documentation
# files (the "Software"), to deal in the Software without
# restriction, including without limitation the rights to use,
# copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the
# Software is furnished to do so, subject to the following
# conditions:
#
# The above copyright notice and this permission notice shall be
# included in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
# OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
# NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
# HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
# WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
# FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
# OTHER DEALINGS IN THE SOFTWARE.
#
# =================================================================

from unittest import mock

from click.testing import CliRunner
import pytest

from pygeoapi import cli


@pytest.mark.parametrize('args,debug', [
    (['serve'], False),
    (['serve', '--flask'], False),
    (['serve', '--debug'], True),
    (['serve', '--flask', '-d'], True),
])
def test_serve_flask_debug_is_opt_in(args, debug):
    from pygeoapi import flask_app

    with mock.patch.object(flask_app.APP, 'run') as run:
        result = CliRunner().invoke(cli, args)

    assert result.exit_code == 0, result.output
    run.assert_called_once()
    assert run.call_args.kwargs['debug'] is debug
