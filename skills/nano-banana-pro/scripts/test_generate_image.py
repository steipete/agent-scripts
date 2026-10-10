"""Offline CLI regression tests with real Pillow and synthetic Gemini responses."""

import base64
import importlib.util
import io
import os
from pathlib import Path
import sys
import tempfile
import types
import unittest
from contextlib import redirect_stderr, redirect_stdout
from unittest.mock import patch

from PIL import Image


spec = importlib.util.spec_from_file_location(
    "generate_image", Path(__file__).with_name("generate_image.py")
)
generator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(generator)


class OutputTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.workspace = self.root / "workspace"
        self.workspace.mkdir()
        self.victim = self.root / "victim.txt"
        self.victim.write_bytes(b"SAFE SENTINEL\n")
        self.original_open = os.open

    def run_cli(self, output, modes=("RGB",), encoded=False):
        parts = [types.SimpleNamespace(text="synthetic response", inline_data=None)]
        for mode in modes:
            data = io.BytesIO()
            Image.new(mode, (2, 2)).save(data, "PNG")
            payload = data.getvalue()
            if encoded:
                payload = base64.b64encode(payload).decode("ascii")
            parts.append(types.SimpleNamespace(
                text=None, inline_data=types.SimpleNamespace(data=payload)
            ))
        client = types.SimpleNamespace(models=types.SimpleNamespace(
            generate_content=lambda **kwargs: types.SimpleNamespace(parts=parts)
        ))
        genai = types.ModuleType("google.genai")
        genai.Client = lambda **kwargs: client
        genai.types = types.SimpleNamespace(
            GenerateContentConfig=lambda **kwargs: kwargs,
            ImageConfig=lambda **kwargs: kwargs,
        )
        google = types.ModuleType("google")
        google.genai = genai
        output_log = io.StringIO()
        with patch.dict(sys.modules, {"google": google, "google.genai": genai}), \
                patch.object(sys, "argv", ["generate_image.py", "--prompt", "fixture",
                                          "--api-key", "synthetic", "--filename", str(output)]), \
                redirect_stdout(output_log), redirect_stderr(output_log):
            try:
                generator.main()
            except SystemExit as error:
                return error.code, output_log.getvalue()
        return 0, output_log.getvalue()

    def assert_rejected(self, output):
        code, log = self.run_cli(output)
        self.assertEqual(code, 1, log)
        self.assertNotIn("Image saved:", log)
        self.assertEqual(self.victim.read_bytes(), b"SAFE SENTINEL\n")

    def test_output_symlink_does_not_overwrite_target(self):
        output = self.workspace / "result.png"
        output.symlink_to(self.victim)
        self.assert_rejected(output)
        self.assertTrue(output.is_symlink())

    def test_dangling_output_symlink_does_not_create_target(self):
        missing = self.root / "missing.txt"
        output = self.workspace / "result.png"
        output.symlink_to(missing)
        self.assert_rejected(output)
        self.assertFalse(missing.exists())

    def test_parent_symlink_is_rejected(self):
        (self.workspace / "linked").symlink_to(self.root, target_is_directory=True)
        self.assert_rejected(self.workspace / "linked" / "victim.txt")

    def test_regular_file_and_hard_link_are_preserved(self):
        output = self.workspace / "result.png"
        os.link(self.victim, output)
        self.assert_rejected(output)
        self.assert_rejected(self.victim)

    def test_leaf_replaced_with_symlink_at_open_is_rejected(self):
        output = self.workspace / "result.png"

        def race(path, flags, *args, **kwargs):
            if flags & os.O_CREAT:
                output.symlink_to(self.victim)
            return self.original_open(path, flags, *args, **kwargs)

        with patch.object(generator.os, "open", side_effect=race):
            self.assert_rejected(output)

    def test_parent_replaced_before_open_is_rejected(self):
        parent = self.workspace / "nested"
        parent.mkdir()

        def race(path, flags, *args, **kwargs):
            if path == "nested":
                parent.rmdir()
                parent.symlink_to(self.root, target_is_directory=True)
            return self.original_open(path, flags, *args, **kwargs)

        with patch.object(generator.os, "open", side_effect=race):
            self.assert_rejected(parent / "victim.txt")

    def test_open_parent_stays_pinned_when_path_is_replaced(self):
        parent = self.workspace / "nested"
        parent.mkdir()
        moved = self.workspace / "moved"

        def race(path, flags, *args, **kwargs):
            if flags & os.O_CREAT:
                parent.rename(moved)
                parent.symlink_to(self.root, target_is_directory=True)
            return self.original_open(path, flags, *args, **kwargs)

        with patch.object(generator.os, "open", side_effect=race):
            code, log = self.run_cli(parent / "result.png")
        self.assertEqual(code, 0, log)
        self.assertTrue((moved / "result.png").is_file())
        self.assertFalse((self.root / "result.png").exists())

    def test_new_directories_explicit_paths_and_image_modes(self):
        for mode in ("RGB", "RGBA", "L"):
            with self.subTest(mode=mode):
                output = self.root / "explicit" / mode / "result.png"
                code, log = self.run_cli(output, modes=(mode,), encoded=mode == "L")
                self.assertEqual(code, 0, log)
                with Image.open(output) as image:
                    self.assertEqual(image.format, "PNG")
                    self.assertEqual(image.mode, "RGB")
                    self.assertEqual(image.size, (2, 2))

    def test_multiple_images_keep_last_response(self):
        output = self.workspace / "result.png"
        code, log = self.run_cli(output, modes=("RGB", "RGBA"))
        self.assertEqual(code, 0, log)
        with Image.open(output) as image:
            self.assertEqual(image.getpixel((0, 0)), (255, 255, 255))

    def test_relative_output_and_missing_image(self):
        previous = Path.cwd()
        try:
            os.chdir(self.workspace)
            code, log = self.run_cli(Path("nested/result.png"))
            self.assertEqual(code, 0, log)
            self.assertTrue((self.workspace / "nested/result.png").exists())
        finally:
            os.chdir(previous)
        code, log = self.run_cli(self.workspace / "absent.png", modes=())
        self.assertEqual(code, 1, log)
        self.assertFalse((self.workspace / "absent.png").exists())


if __name__ == "__main__":
    unittest.main()
