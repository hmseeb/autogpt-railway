#!/usr/bin/env python3
"""Extract every OAuth provider from the pinned upstream checkout.

The readme tells deployers which variables enable which integration. That list
was hand-written once and was wrong within a day: it came from upstream's
Secrets model, which only covers providers with hardcoded settings fields, and
silently missed every provider registered through the block SDK.

There are two registration paths and a version bump can add to either, so the
list is derived here and checked against the readme in CI. A release that adds
a provider fails the build instead of shipping documentation that quietly
omits it.

    python3 test/oauth-providers.py --upstream ./upstream          # print
    python3 test/oauth-providers.py --upstream ./upstream --check  # verify

Exit 1 on drift, with the difference printed.
"""
import argparse
import pathlib
import re
import sys

SKIP = {"__init__", "base"}


def find_providers(upstream: pathlib.Path) -> dict[str, str]:
    """Map provider name -> client id env var, across both registration paths."""
    backend = upstream / "autogpt_platform" / "backend" / "backend"
    if not backend.is_dir():
        sys.exit(f"not an upstream checkout: {backend} missing")

    providers: dict[str, str] = {}

    # Path 1: handler modules under integrations/oauth/. These read their
    # credentials through the Secrets model, whose env var is the field name
    # uppercased, i.e. <PROVIDER>_CLIENT_ID. Only modules defining a
    # BaseOAuthHandler subclass count: the directory also holds device-flow
    # handlers that ship a public client id, and shared helpers.
    for path in (backend / "integrations" / "oauth").glob("*.py"):
        if path.stem in SKIP or path.stem.endswith("_test"):
            continue
        if not re.search(r"^class \w+\(BaseOAuthHandler\)", path.read_text(), re.M):
            continue
        providers[path.stem] = f"{path.stem.upper()}_CLIENT_ID"

    # Path 2: providers registered through the block SDK. They may name their
    # own env var; when they don't, the SDK builder derives <NAME>_CLIENT_ID
    # (sdk/builder.py). Mirror that fallback rather than assuming it is set.
    for path in (backend / "blocks").glob("*/_config.py"):
        text = path.read_text()
        if ".with_oauth(" not in text:
            continue
        name = path.parent.name
        explicit = re.search(r'client_id_env_var\s*=\s*"([^"]+)"', text)
        providers[name] = explicit.group(1) if explicit else f"{name.upper()}_CLIENT_ID"

    return providers


def readme_providers(readme: pathlib.Path) -> set[str]:
    """Env vars named in the readme's integration table."""
    return set(re.findall(r"`([A-Z0-9_]+_CLIENT_ID)`", readme.read_text()))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--upstream", required=True, type=pathlib.Path)
    ap.add_argument("--readme", type=pathlib.Path, default=pathlib.Path("README.md"))
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()

    found = find_providers(args.upstream)
    if not found:
        sys.exit("found no OAuth providers at all; the extractor is broken, "
                 "not upstream")

    if not args.check:
        for name, env in sorted(found.items()):
            print(f"{name:12} {env}, {env.replace('_CLIENT_ID', '_CLIENT_SECRET')}")
        return 0

    documented = readme_providers(args.readme)
    expected = set(found.values())
    missing = expected - documented
    extra = documented - expected

    for env in sorted(missing):
        print(f"MISSING from readme: {env} "
              f"({[k for k, v in found.items() if v == env][0]})")
    for env in sorted(extra):
        print(f"STALE in readme: {env} (no longer in upstream)")

    if missing or extra:
        print(f"\nFAIL: readme lists {len(documented)} OAuth providers, "
              f"upstream has {len(expected)}. Update the table in README.md.")
        return 1

    print(f"PASS: readme documents all {len(expected)} OAuth providers")
    return 0


if __name__ == "__main__":
    sys.exit(main())
