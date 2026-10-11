#!/usr/bin/env python3
"""Run a command with DATABASE_URL built from the five TIGER_* secrets.

Usage: python3 .github/scripts/with_tiger_url.py <command> [args...]

GitHub masks each secret on its own, not a string built from them, so the assembled URL and the
percent-encoded user and password are masked with ::add-mask:: before the command starts. The URL
is passed to the command's environment only; it is never printed or written to $GITHUB_ENV.
"""
import os
import sys
from urllib.parse import quote

NAMES = ("TIGER_HOST", "TIGER_PORT", "TIGER_DB_NAME", "TIGER_USERNAME", "TIGER_PASSWORD")


def mask(value: str) -> None:
    # Workflow command data unescapes %25, %0D and %0A, so escape them or the runner masks a
    # different string (a password with "%" encodes to "%25...").
    escaped = value.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
    print(f"::add-mask::{escaped}", flush=True)


def build_url(env: dict) -> str:
    missing = [n for n in NAMES if not env.get(n)]
    if missing:
        sys.exit(f"missing secrets: {', '.join(missing)}")
    port = env["TIGER_PORT"].strip()
    if not port.isdigit():
        sys.exit("TIGER_PORT is not a number")
    user = quote(env["TIGER_USERNAME"], safe="")
    password = quote(env["TIGER_PASSWORD"], safe="")
    db = quote(env["TIGER_DB_NAME"], safe="")
    url = f"postgres://{user}:{password}@{env['TIGER_HOST'].strip()}:{port}/{db}?sslmode=require"
    for value in (user, password, url):
        mask(value)
    return url


def main() -> None:
    if len(sys.argv) < 2:
        sys.exit(__doc__.strip().splitlines()[2])
    env = dict(os.environ)
    env["DATABASE_URL"] = build_url(env)
    for n in NAMES:
        env.pop(n, None)
    os.execvpe(sys.argv[1], sys.argv[1:], env)


if __name__ == "__main__":
    main()
