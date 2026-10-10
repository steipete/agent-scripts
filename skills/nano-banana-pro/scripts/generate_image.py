#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = [
#     "google-genai>=1.0.0",
#     "pillow>=10.0.0",
# ]
# ///
"""
Generate images using Google's Nano Banana 2 (Gemini 3.1 Flash Image) API.

Usage:
    uv run generate_image.py --prompt "your image description" --filename "output.png" [--resolution 512|1K|2K|4K] [--api-key KEY]
"""

import argparse
import os
import sys
from contextlib import ExitStack, contextmanager
from pathlib import Path


def get_api_key(provided_key: str | None) -> str | None:
    """Get API key from argument first, then environment."""
    if provided_key:
        return provided_key
    return os.environ.get("GEMINI_API_KEY")


def normalize_resolution(value: str) -> str:
    normalized = value.strip().upper()
    aliases = {
        "0.5K": "512",
        "512PX": "512",
        "512P": "512",
    }
    normalized = aliases.get(normalized, normalized)
    if normalized not in {"512", "1K", "2K", "4K"}:
        raise argparse.ArgumentTypeError("choose from 512, 1K, 2K, or 4K")
    return normalized


@contextmanager
def create_output(path: Path):
    """Create a new output without following leaf or parent symlinks."""
    if not path.name or path.name == "..":
        raise ValueError("Output must name a new file")
    if not hasattr(os, "O_NOFOLLOW") or not hasattr(os, "O_DIRECTORY"):
        raise OSError("Safe image output requires POSIX directory handles")

    directory_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    with ExitStack() as stack:
        directory = os.open(path.anchor or ".", directory_flags)
        stack.callback(os.close, directory)
        parents = path.parts[1:-1] if path.is_absolute() else path.parts[:-1]
        for component in parents:
            try:
                child = os.open(component, directory_flags, dir_fd=directory)
            except FileNotFoundError:
                try:
                    os.mkdir(component, dir_fd=directory)
                except FileExistsError:
                    pass
                child = os.open(component, directory_flags, dir_fd=directory)
            stack.callback(os.close, child)
            directory = child

        # Exclusive creation rejects existing files, hard links and dangling links.
        descriptor = os.open(
            path.name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
            0o666, dir_fd=directory,
        )
        with os.fdopen(descriptor, "wb") as output:
            yield output


def main():
    parser = argparse.ArgumentParser(
        description="Generate images using Nano Banana 2 (Gemini 3.1 Flash Image)"
    )
    parser.add_argument(
        "--prompt", "-p",
        required=True,
        help="Image description/prompt"
    )
    parser.add_argument(
        "--filename", "-f",
        required=True,
        help="New output filename; existing files and symlink paths are rejected"
    )
    parser.add_argument(
        "--input-image", "-i",
        help="Optional input image path for editing/modification"
    )
    parser.add_argument(
        "--resolution", "-r",
        type=normalize_resolution,
        default="1K",
        metavar="{512,1K,2K,4K}",
        help="Output resolution: 512, 1K (default), 2K, or 4K"
    )
    parser.add_argument(
        "--api-key", "-k",
        help="Gemini API key (overrides GEMINI_API_KEY env var)"
    )

    args = parser.parse_args()

    # Get API key
    api_key = get_api_key(args.api_key)
    if not api_key:
        print("Error: No API key provided.", file=sys.stderr)
        print("Please either:", file=sys.stderr)
        print("  1. Provide --api-key argument", file=sys.stderr)
        print("  2. Set GEMINI_API_KEY environment variable", file=sys.stderr)
        sys.exit(1)

    # Import here after checking API key to avoid slow import on error
    from google import genai
    from google.genai import types
    from PIL import Image as PILImage

    # Initialise client
    client = genai.Client(api_key=api_key)

    # Set up output path
    output_path = Path(args.filename)

    # Load input image if provided
    input_image = None
    output_resolution = args.resolution
    if args.input_image:
        try:
            input_image = PILImage.open(args.input_image)
            print(f"Loaded input image: {args.input_image}")

            # Auto-detect resolution if not explicitly set by user
            if args.resolution == "1K":  # Default value
                # Map input image size to resolution
                width, height = input_image.size
                max_dim = max(width, height)
                if max_dim >= 3000:
                    output_resolution = "4K"
                elif max_dim >= 1500:
                    output_resolution = "2K"
                else:
                    output_resolution = "1K"
                print(f"Auto-detected resolution: {output_resolution} (from input {width}x{height})")
        except Exception as e:
            print(f"Error loading input image: {e}", file=sys.stderr)
            sys.exit(1)

    # Build contents (image first if editing, prompt only if generating)
    if input_image:
        contents = [input_image, args.prompt]
        print(f"Editing image with resolution {output_resolution}...")
    else:
        contents = args.prompt
        print(f"Generating image with resolution {output_resolution}...")

    try:
        response = client.models.generate_content(
            model="gemini-3.1-flash-image-preview",
            contents=contents,
            config=types.GenerateContentConfig(
                response_modalities=["TEXT", "IMAGE"],
                image_config=types.ImageConfig(
                    image_size=output_resolution
                )
            )
        )

        # Process response and convert to PNG
        output_image = None
        for part in response.parts:
            if part.text is not None:
                print(f"Model response: {part.text}")
            elif part.inline_data is not None:
                # Convert inline data to PIL Image and save as PNG
                from io import BytesIO

                # inline_data.data is already bytes, not base64
                image_data = part.inline_data.data
                if isinstance(image_data, str):
                    # If it's a string, it might be base64
                    import base64
                    image_data = base64.b64decode(image_data)

                image = PILImage.open(BytesIO(image_data))

                # Ensure RGB mode for PNG (convert RGBA to RGB with white background if needed)
                if image.mode == 'RGBA':
                    rgb_image = PILImage.new('RGB', image.size, (255, 255, 255))
                    rgb_image.paste(image, mask=image.split()[3])
                    output_image = rgb_image
                elif image.mode == 'RGB':
                    output_image = image
                else:
                    output_image = image.convert('RGB')

        if output_image is not None:
            with create_output(output_path) as output:
                output_image.save(output, 'PNG')
            full_path = output_path.absolute()
            print(f"\nImage saved: {full_path}")
        else:
            print("Error: No image was generated in the response.", file=sys.stderr)
            sys.exit(1)

    except Exception as e:
        print(f"Error generating image: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
