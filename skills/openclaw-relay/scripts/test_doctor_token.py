#!/usr/bin/env python3
"""Exercise local doctor without starting a gateway or reading real credentials."""
import contextlib
import importlib.util
import io
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("relay", Path(__file__).with_name("openclaw_relay.py"))
relay = importlib.util.module_from_spec(spec)
spec.loader.exec_module(relay)


class DoctorTokenTest(unittest.TestCase):
    def test_local_token_readiness(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / ".acpxrc.json").write_text("{}")
            token = root / "token"
            token.write_text("synthetic")
            args = relay.build_parser().parse_args(["doctor", "--transport", "local",
                "--cwd", str(root), "--acpx-repo", str(root)])
            args.targets_file = str(root / "absent-targets.json")
            proc = subprocess.CompletedProcess([], 0, "", "")
            with patch.object(relay, "run_acpx", return_value=proc), patch.object(relay, "run_openclaw", return_value=proc):
                for value, expected in [(None, False), ("", False), (str(root / "missing"), False), (str(token), True)]:
                    with self.subTest(token_file=value):
                        args.gateway_token_file = value
                        output = io.StringIO()
                        with contextlib.redirect_stdout(output):
                            relay.cmd_doctor(args)
                        self.assertIs(json.loads(output.getvalue())["ready"], expected)


if __name__ == "__main__":
    unittest.main()
