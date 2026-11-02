import os
import unittest
from unittest import mock

from tests import support  # noqa: F401
from forge import network

DEFAULT = "0" * 32 + " 00 " + "0" * 32 + " 00 " + "fe80" + "0" * 28 + " 00000400 00000001 00000000 %s %s\n"


def proc(forwarding="0", disabled="0", **accept_ra):
    def read(path):
        if path.endswith("all/disable_ipv6"):
            return disabled
        if path.endswith("all/forwarding"):
            return forwarding
        return accept_ra.get(path.split("/")[-2])
    return read


class HostTest(unittest.TestCase):
    def test_default_routes_skip_loopback_and_reject(self):
        text = DEFAULT % ("00450003", "eth0") + DEFAULT % ("00200200", "lo") + DEFAULT % ("00000200", "wlan0")
        self.assertEqual(network.default_routes(text), ["eth0"])

    def test_no_route_or_ipv6_off(self):
        self.assertIn("no IPv6 route", network.host_problem([], proc())[0])
        self.assertIn("turned off", network.host_problem(["eth0"], proc(disabled="1"))[0])

    def test_kernel_router_advertisements_are_protected(self):
        # turning forwarding on would cost this machine its own route
        reason, fix = network.host_problem(["eth0"], proc(eth0="1"))
        self.assertIn("eth0", reason)
        self.assertIn("net.ipv6.conf.eth0.accept_ra=2", fix)

    def test_safe_setups(self):
        self.assertIsNone(network.host_problem(["eth0"], proc(eth0="0")))     # networkd handles RAs itself
        self.assertIsNone(network.host_problem(["eth0"], proc(eth0="2")))
        self.assertIsNone(network.host_problem(["eth0"], proc(forwarding="1", eth0="1")))


class DockerTest(unittest.TestCase):
    def setUp(self):
        network._state.update(ok=None, reason="", fix=None, at=0.0)
        network._synced.update(names=None, at=0.0)
        self.env = mock.patch.dict(os.environ, {"FORGE_IPV6": "1"})
        self.env.start()
        self.addCleanup(self.env.stop)

    def docker(self, have=False, version="29.1.0"):
        calls = []

        def run(args, timeout=None):
            calls.append(args)
            if args[1:3] == ["network", "inspect"]:
                if "{{.EnableIPv6}}" in args:
                    return (0, "true\n", "") if have else (1, "", "not found")
                return 0, "forge-a ", ""
            if args[1] == "version":
                return 0, version + "\n", ""
            return 0, "", ""
        patcher = mock.patch.object(network, "run", run)
        patcher.start()
        self.addCleanup(patcher.stop)
        return calls

    def test_creates_the_network_once(self):
        calls = self.docker()
        with mock.patch.object(network, "host_problem", return_value=None):
            self.assertTrue(network.ensure())
            self.assertTrue(network.ensure())
        made = [c for c in calls if c[1:3] == ["network", "create"]]
        self.assertEqual(len(made), 1)
        self.assertIn("--ipv6", made[0])

    def test_old_docker_is_left_alone(self):
        calls = self.docker(version="27.5.1")
        self.assertFalse(network.ensure())
        self.assertFalse([c for c in calls if c[1:3] == ["network", "create"]])
        self.assertIn("Docker 28", network._state["reason"])

    def test_host_problem_stops_it(self):
        calls = self.docker()
        with mock.patch.object(network, "host_problem", return_value=("kept off", "the fix")):
            self.assertFalse(network.ensure())
        self.assertFalse([c for c in calls if c[1:3] == ["network", "create"]])
        self.assertEqual(network._state["fix"], "the fix")

    def test_attach_keeps_ipv4_on_the_bridge(self):
        calls = self.docker(have=True)
        self.assertTrue(network.attach("forge-a"))
        self.assertEqual(calls[-1], ["docker", "network", "connect", "--gw-priority", "-1", network.NET, "forge-a"])

    def test_sync_joins_only_the_missing(self):
        calls = self.docker(have=True)
        self.assertEqual(network.sync(["forge-a", "forge-b"]), ["forge-b"])
        self.assertEqual(network.sync(["forge-a", "forge-b"]), [])       # checked a moment ago
        self.assertEqual(len([c for c in calls if c[2] == "connect"]), 1)

    def test_switched_off(self):
        calls = self.docker()
        with mock.patch.dict(os.environ, {"FORGE_IPV6": "0"}):
            self.assertFalse(network.attach("forge-a"))
        self.assertEqual(calls, [])

    def test_address(self):
        c = {"NetworkSettings": {"Networks": {"bridge": {"GlobalIPv6Address": ""}, network.NET: {"GlobalIPv6Address": "fd53::2"}}}}
        self.assertEqual(network.address(c), "fd53::2")
        self.assertIsNone(network.address({}))


if __name__ == "__main__":
    unittest.main()
