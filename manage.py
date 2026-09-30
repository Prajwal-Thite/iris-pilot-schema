#!/usr/bin/env python
"""Reproducible reset/migrate/seed CLI for the IRIS pilot schema.

Usage:
    python manage.py reset     # drop iris_core/iris_staging, replay migrations, load seed data
    python manage.py migrate   # apply migrations only (idempotent-ish, no drop)
    python manage.py seed      # load seed fixtures only
"""
import argparse
import os
import sys
from pathlib import Path

import psycopg

ROOT = Path(__file__).parent
MIGRATIONS_DIR = ROOT / "migrations"
SEED_DIR = ROOT / "seed"

DEFAULT_DSN = "postgresql://iris:iris@localhost:5433/iris_pilot"


def get_dsn() -> str:
    return os.environ.get("DATABASE_URL", DEFAULT_DSN)


def run_sql_file(conn: psycopg.Connection, path: Path) -> None:
    sql = path.read_text(encoding="utf-8")
    with conn.cursor() as cur:
        cur.execute(sql)
    conn.commit()
    print(f"applied {path.relative_to(ROOT)}")


def drop_schemas(conn: psycopg.Connection) -> None:
    with conn.cursor() as cur:
        cur.execute("DROP SCHEMA IF EXISTS iris_core CASCADE;")
        cur.execute("DROP SCHEMA IF EXISTS iris_staging CASCADE;")
    conn.commit()
    print("dropped iris_core and iris_staging schemas")


def migrate(conn: psycopg.Connection) -> None:
    for path in sorted(MIGRATIONS_DIR.glob("*.sql")):
        run_sql_file(conn, path)


def seed(conn: psycopg.Connection) -> None:
    for path in sorted(SEED_DIR.glob("*.sql")):
        run_sql_file(conn, path)


def cmd_reset(args: argparse.Namespace) -> None:
    with psycopg.connect(get_dsn(), autocommit=False) as conn:
        drop_schemas(conn)
        migrate(conn)
        seed(conn)
    print("reset complete: empty DB -> migrations -> seed data")


def cmd_migrate(args: argparse.Namespace) -> None:
    with psycopg.connect(get_dsn(), autocommit=False) as conn:
        migrate(conn)


def cmd_seed(args: argparse.Namespace) -> None:
    with psycopg.connect(get_dsn(), autocommit=False) as conn:
        seed(conn)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("reset", help="drop schemas, replay migrations, load seed data")
    sub.add_parser("migrate", help="apply migrations only")
    sub.add_parser("seed", help="load seed fixtures only")

    args = parser.parse_args()
    {
        "reset": cmd_reset,
        "migrate": cmd_migrate,
        "seed": cmd_seed,
    }[args.command](args)
    return 0


if __name__ == "__main__":
    sys.exit(main())
