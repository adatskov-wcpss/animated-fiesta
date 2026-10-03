import unittest

from tests import support  # noqa: F401
from forge.server import Handler


class FakeHandler(object):
    """Just enough of a request for Handler._guard."""
    LOOPBACK_HOSTS = Handler.LOOPBACK_HOSTS
    _guard = Handler._guard

    def __init__(self, headers, require_token=False):
        self.headers = headers
        self.require_token = require_token


def guard(headers, post=False, token=False):
    return FakeHandler(headers, token)._guard(post)


class GuardTest(unittest.TestCase):
    def test_same_origin_ui_is_allowed(self):
        h = {"Host": "localhost:8787", "Origin": "http://localhost:8787",
             "Content-Type": "application/json"}
        self.assertIsNone(guard(h, post=True))
        self.assertIsNone(guard({"Host": "127.0.0.1:8787"}))
        self.assertIsNone(guard({"Host": "[::1]:8787"}))

    def test_scripts_without_a_browser_are_allowed(self):
        self.assertIsNone(guard({"Host": "localhost:8787", "Content-Type": "application/json"}, post=True))

    def test_cross_site_requests_are_refused(self):
        self.assertTrue(guard({"Host": "localhost:8787", "Origin": "https://evil.example"}))
        self.assertTrue(guard({"Host": "localhost:8787", "Origin": "null"}, post=False))
        self.assertTrue(guard({"Host": "localhost:8787", "Origin": "http://localhost:9999",
                               "Content-Type": "application/json"}, post=True))

    def test_non_json_posts_are_refused(self):
        self.assertTrue(guard({"Host": "localhost:8787", "Content-Type": "text/plain"}, post=True))
        self.assertTrue(guard({"Host": "localhost:8787"}, post=True))

    def test_dns_rebinding_is_refused_on_localhost(self):
        self.assertTrue(guard({"Host": "attacker.example:8787"}))

    def test_exposed_ui_relies_on_its_token(self):
        h = {"Host": "abc.serveousercontent.com", "Origin": "https://abc.serveousercontent.com",
             "Content-Type": "application/json"}
        self.assertIsNone(guard(h, post=True, token=True))
        self.assertTrue(guard(dict(h, Origin="https://evil.example"), post=True, token=True))


if __name__ == "__main__":
    unittest.main()
