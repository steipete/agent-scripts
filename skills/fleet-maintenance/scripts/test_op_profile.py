import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


@unittest.skipUnless(sys.platform == "darwin", "audit uses macOS stat and ACL tools")
class TokenParentTests(unittest.TestCase):
    def test_writable_parent_is_rejected_and_repair_preserves_token(self):
        script = Path(__file__).with_name("op-profile-audit.sh")
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory).resolve()
            config = home / ".config"
            token_dir = config / "op"
            token_dir.mkdir(parents=True)
            token_dir.chmod(0o700)
            token = token_dir / "molty-service-account-token"
            token.write_text("synthetic-fixture")
            token.chmod(0o600)
            (home / ".profile").write_text("# fixture\n")
            (home / ".profile").chmod(0o600)
            (home / ".zprofile").write_text('source "$HOME/.profile"\n')
            (home / ".zprofile").chmod(0o600)
            environment = {**os.environ, "HOME": str(home)}
            environment.pop("OP_SERVICE_ACCOUNT_TOKEN", None)

            def run(*args):
                return subprocess.run(
                    ["/bin/bash", str(script), *args],
                    env=environment, capture_output=True, text=True, timeout=15,
                )

            config.chmod(0o777)
            self.assertIn("token_file=unsafe-path", run().stdout)
            repaired = run("--repair")
            # No CLI is installed in the fixture; repair must stop before the
            # compatibility-link step, after securing the token's parent.
            self.assertEqual(repaired.returncode, 2)
            self.assertIn("stable op is missing", repaired.stderr)
            self.assertEqual(config.stat().st_mode & 0o022, 0)
            self.assertEqual(token.read_text(), "synthetic-fixture")
            self.assertIn("token_file=current", run().stdout)


if __name__ == "__main__":
    unittest.main()
