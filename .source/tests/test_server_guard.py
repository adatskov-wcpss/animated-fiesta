import unittest

from tests import support  # noqa: F401
from forge.server import Handler


class FakeHandler(object):
    """Just enough of a request for Handler._guard."""
    LOOPBACK_HOSTS = Handler.LOOPBACK_HOSTS
    _guard = Handler._guard

    def __init__(self, headers, loopback_only=True):
        self.headers = headers
        self.loopback_only = loopback_only


def guard(headers, post=False, exposed=False):
    return FakeHandler(headers, not exposed)._guard(post)


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

    def test_exposed_ui_answers_any_name_but_still_refuses_cross_site(self):
        h = {"Host": "abc.serveousercontent.com", "Origin": "https://abc.serveousercontent.com",
             "Content-Type": "application/json"}
        self.assertIsNone(guard(h, post=True, exposed=True))
        self.assertIsNone(guard({"Host": "100.66.153.83:8787"}, exposed=True))
        self.assertTrue(guard(dict(h, Origin="https://evil.example"), post=True, exposed=True))


if __name__ == "__main__":
    unittest.main()
