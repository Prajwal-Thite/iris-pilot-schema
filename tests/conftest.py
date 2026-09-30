import os
import pathlib
import subprocess
import sys

import psycopg
import pytest

ROOT = pathlib.Path(__file__).parent.parent
DSN = os.environ.get("DATABASE_URL", "postgresql://iris:iris@localhost:5433/iris_pilot")


@pytest.fixture(scope="session", autouse=True)
def reset_db():
    subprocess.run([sys.executable, str(ROOT / "manage.py"), "reset"], check=True, cwd=ROOT)


@pytest.fixture()
def conn():
    connection = psycopg.connect(DSN, autocommit=False)
    yield connection
    connection.rollback()
    connection.close()


@pytest.fixture()
def any_source_id(conn):
    with conn.cursor() as cur:
        cur.execute("SELECT source_id FROM iris_core.source_run LIMIT 1")
        return cur.fetchone()[0]
