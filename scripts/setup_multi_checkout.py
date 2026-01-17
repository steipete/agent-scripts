#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""
Multi-Checkout Setup Script

Implements Peter Steinberger's (@steipete) local checkouts pattern for working on
multiple issues simultaneously without using git worktrees or branches.

What It Does:
- Clones a repository N times into separate directories (repo-1, repo-2, etc.)
- Creates a single shared .env file symlinked across all checkouts
- Generates shell aliases for quick switching between contexts
- Each checkout is fully isolated with its own node_modules, build artifacts, etc.

Usage:
    uv run setup_multi_checkout.py --repo REPO [--count N] [--base-dir DIR] [--shared-env FILE]

Example:
    uv run setup_multi_checkout.py --repo git@github.com:clawdbot/clawdbot --count 6

    # For a different repo:
    uv run setup_multi_checkout.py --repo git@github.com:user/myrepo.git --count 4

    # With custom paths:
    uv run setup_multi_checkout.py \
        --repo git@github.com:user/repo.git \
        --base-dir ~/dev \
        --shared-env ~/dev/.env.shared

Options:
    --repo       Git repository URL to clone (required)
    --count      Number of checkouts (default: 6)
    --base-dir   Base directory for checkouts (default: ~/Projects)
    --shared-env Shared environment file path (default: ~/.env.shared)
    --dry-run    Show what would be done without doing it
    --yes, -y    Skip confirmation prompts
"""

import argparse
import shlex
import shutil
import subprocess
import sys
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(
        description="Setup multiple isolated checkouts of a repository"
    )
    parser.add_argument("--repo", required=True, help="Git repository URL to clone")
    parser.add_argument("--count", type=int, default=6,
                        help="Number of checkouts to create")
    parser.add_argument("--base-dir", type=Path, default=Path("~/Projects").expanduser(),
                        help="Base directory for checkouts")
    parser.add_argument("--shared-env", type=Path, default=Path("~/.env.shared").expanduser(),
                        help="Shared environment file path")
    parser.add_argument("--dry-run", action="store_true",
                        help="Show what would be done without doing it")
    parser.add_argument("--yes", "-y", action="store_true",
                        help="Skip confirmation prompts")
    
    args = parser.parse_args()
    args.base_dir = args.base_dir.expanduser()
    args.shared_env = args.shared_env.expanduser()

    if args.count < 1:
        print("Error: --count must be at least 1.")
        sys.exit(2)

    # Determine repo name from URL
    repo_name = args.repo.rstrip("/").split("/")[-1].replace(".git", "")
    
    print(f"Setting up {args.count} checkouts of {repo_name}")
    print(f"Base directory: {args.base_dir}")
    print(f"Shared env: {args.shared_env}")
    print()

    # Ensure base directory exists
    if args.base_dir.exists() and not args.base_dir.is_dir():
        print(f"Error: base dir exists but is not a directory: {args.base_dir}")
        sys.exit(2)
    if not args.base_dir.exists():
        if args.dry_run:
            print(f"  Would create directory: {args.base_dir}")
        else:
            args.base_dir.mkdir(parents=True, exist_ok=True)
            print(f"Created: {args.base_dir}")

    # Check for existing checkouts
    existing = []
    for i in range(1, args.count + 1):
        checkout_dir = args.base_dir / f"{repo_name}-{i}"
        if checkout_dir.exists():
            existing.append((i, checkout_dir))

    def remove_path(path: Path) -> None:
        if path.is_symlink() or path.is_file():
            path.unlink()
            return
        if path.is_dir():
            shutil.rmtree(path)
            return
        path.unlink(missing_ok=True)

    if existing:
        print(f"Existing checkouts found:")
        for i, path in existing:
            print(f"  {repo_name}-{i}: {path}")
        if not args.yes:
            response = input("Remove and re-clone? [y/N]: ")
            if response.lower() != "y":
                print("Aborting.")
                return
        for _, path in existing:
            if args.dry_run:
                print(f"  Would remove: {path}")
            else:
                print(f"Removing: {path}")
                remove_path(path)

    # Create shared env file if it doesn't exist
    if args.shared_env.exists() and args.shared_env.is_dir():
        print(f"Error: shared env path is a directory: {args.shared_env}")
        sys.exit(2)
    if not args.shared_env.exists():
        if args.dry_run:
            print(f"  Would create: {args.shared_env}")
        else:
            args.shared_env.parent.mkdir(parents=True, exist_ok=True)
            default_env = f"""# Shared {repo_name} environment
# Add your credentials here

# Required
ANTHROPIC_API_KEY=
OPENAI_API_KEY=

# Optional
DATABASE_URL=
"""
            args.shared_env.write_text(default_env)
            print(f"Created: {args.shared_env}")
            print(f"  Edit this file with your credentials!")

    # Clone repositories
    print("\nCloning repositories...")
    failed = []
    for i in range(1, args.count + 1):
        checkout_dir = args.base_dir / f"{repo_name}-{i}"
        
        if args.dry_run:
            print(f"  Would clone {repo_name} to {checkout_dir}")
            continue

        print(f"  Cloning {repo_name}-{i}...")
        result = subprocess.run(
            ["git", "clone", args.repo, str(checkout_dir)],
            capture_output=True,
            check=False
        )
        if result.returncode != 0:
            print(f"  Failed to clone {repo_name}-{i}: {result.stderr.decode()}")
            failed.append(i)

    # Create symlinks to shared env
    print("\nCreating .env.local symlinks...")
    for i in range(1, args.count + 1):
        checkout_dir = args.base_dir / f"{repo_name}-{i}"
        env_local = checkout_dir / ".env.local"

        if not checkout_dir.exists():
            print(f"  Skipping {repo_name}-{i}: checkout missing")
            continue
        
        # Remove existing .env.local if it exists
        if env_local.exists() or env_local.is_symlink():
            if args.dry_run:
                print(f"  Would remove: {env_local}")
            else:
                remove_path(env_local)
        
        # Create symlink to shared env
        if args.dry_run:
            print(f"  Would symlink: {env_local} -> {args.shared_env}")
        else:
            env_local.symlink_to(args.shared_env)
            print(f"  Symlinked: {env_local.name} -> {args.shared_env.name}")

    # Generate shell aliases
    print("\nShell aliases:")
    aliases = []
    quote = shlex.quote
    safe_repo_name = "".join(
        c if (c.isalnum() or c == "_") else "_" for c in repo_name
    )
    sync_fn = f"sync_{safe_repo_name}"
    aliases.append(f"# {repo_name} multi-checkout aliases")
    aliases.append(
        f"alias {repo_name}='cd {quote(str(args.base_dir / f'{repo_name}-1'))}'"
    )
    for i in range(1, args.count + 1):
        aliases.append(
            f"alias {repo_name}{i}='cd {quote(str(args.base_dir / f'{repo_name}-{i}'))}'"
        )
    aliases.append("")
    aliases.append(f"# Sync all {repo_name} checkouts")
    aliases.append(f"{sync_fn}() {{")
    aliases.append(f"  for i in {' '.join(str(i) for i in range(1, args.count + 1))}; do")
    base_dir_q = quote(str(args.base_dir))
    repo_name_q = quote(repo_name)
    aliases.append(
        f"    (cd {base_dir_q}/{repo_name_q}-$i && git pull) &"
    )
    aliases.append("  done")
    aliases.append("  wait")
    aliases.append("}")
    aliases.append(f"alias sync-{repo_name}='{sync_fn}'")

    for line in aliases:
        print(f"  {line}")

    # Save aliases to file
    aliases_file = args.base_dir / f".{repo_name}-aliases"
    if args.dry_run:
        print(f"\n  Would save aliases to: {aliases_file}")
    else:
        aliases_file.write_text("\n".join(aliases) + "\n")
        print(f"\nSaved aliases to: {aliases_file}")
        print(f"  Add to ~/.zshrc: source {aliases_file}")

    if failed:
        print(f"\n✗ Setup completed with errors in checkouts: {', '.join(map(str, failed))}")
        sys.exit(1)

    print("\n✓ Setup complete!")
    print(f"\nNext steps:")
    print(f"  1. Edit shared env: code {args.shared_env}")
    print(f"  2. Source aliases: source {aliases_file}")
    print(f"  3. Start working: {repo_name}1")


if __name__ == "__main__":
    main()
