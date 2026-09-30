"""Highest-risk correctness conditions for the IRIS pilot schema.

Each test opens its own connection (see conftest.conn) and rolls back at
teardown, so tests never see each other's writes and never mutate the
seed fixtures loaded once per session.
"""
import psycopg
import pytest

VALID_SQUARE = "MULTIPOLYGON(((-1 51, -1 51.001, -1.001 51.001, -1.001 51, -1 51)))"
SELF_INTERSECTING = "MULTIPOLYGON(((0 0, 2 2, 2 0, 0 2, 0 0)))"


def test_parcel_country_code_cannot_be_null(conn, any_source_id):
    with pytest.raises(psycopg.errors.NotNullViolation):
        with conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO iris_core.parcel
                    (country_code, region_code, external_parcel_ref, geom, source_id, source_date)
                VALUES (NULL, 'ENG-SW', 'PARCEL-NULLTEST', ST_GeomFromText(%s, 4326), %s, CURRENT_DATE)
                """,
                (VALID_SQUARE, any_source_id),
            )


def test_source_run_country_code_cannot_be_null(conn):
    with pytest.raises(psycopg.errors.NotNullViolation):
        with conn.cursor() as cur:
            cur.execute(
                "INSERT INTO iris_core.source_run (country_code, source_name, source_date) "
                "VALUES (NULL, 'bad_source', CURRENT_DATE)"
            )


def test_duplicate_external_ref_rejected_within_same_country(conn, any_source_id):
    # PARCEL-001/GB already exists in the seed fixture.
    with pytest.raises(psycopg.errors.UniqueViolation):
        with conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO iris_core.parcel
                    (country_code, region_code, external_parcel_ref, geom, source_id, source_date)
                VALUES ('GB', 'ENG-SW', 'PARCEL-001', ST_GeomFromText(%s, 4326), %s, CURRENT_DATE)
                """,
                (VALID_SQUARE, any_source_id),
            )


def test_same_external_ref_allowed_in_a_different_country(conn, any_source_id):
    # Proves uniqueness is country-scoped, not a bare global key on external_parcel_ref.
    with conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO iris_core.parcel
                (country_code, region_code, external_parcel_ref, geom, source_id, source_date)
            VALUES ('IE', 'LEI', 'PARCEL-001', ST_GeomFromText(%s, 4326), %s, CURRENT_DATE)
            """,
            (VALID_SQUARE, any_source_id),
        )
        cur.execute(
            "SELECT count(*) FROM iris_core.parcel WHERE external_parcel_ref = 'PARCEL-001'"
        )
        assert cur.fetchone()[0] == 2  # GB and IE both have a PARCEL-001


def test_invalid_geometry_rejected(conn, any_source_id):
    with pytest.raises(psycopg.errors.CheckViolation):
        with conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO iris_core.parcel
                    (country_code, region_code, external_parcel_ref, geom, source_id, source_date)
                VALUES ('GB', 'ENG-SW', 'PARCEL-INVALID', ST_GeomFromText(%s, 4326), %s, CURRENT_DATE)
                """,
                (SELF_INTERSECTING, any_source_id),
            )


def test_geom_column_never_named_geometry(conn):
    with conn.cursor() as cur:
        cur.execute(
            "SELECT count(*) FROM information_schema.columns "
            "WHERE table_schema = 'iris_core' AND column_name = 'geometry'"
        )
        assert cur.fetchone()[0] == 0


@pytest.mark.parametrize("table", ["parcel", "substation", "peatland", "screening_layer"])
def test_canonical_columns_present(conn, table):
    required = {"geom", "country_code", "region_code", "source_id", "source_date", "created_at"}
    with conn.cursor() as cur:
        cur.execute(
            "SELECT column_name FROM information_schema.columns "
            "WHERE table_schema = 'iris_core' AND table_name = %s",
            (table,),
        )
        cols = {row[0] for row in cur.fetchall()}
        assert required <= cols, f"{table} missing: {required - cols}"


def test_spatial_round_trip(conn, any_source_id):
    with conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO iris_core.substation
                (country_code, region_code, external_substation_ref, name, geom, source_id, source_date)
            VALUES ('GB', 'ENG-SW', 'SUB-ROUNDTRIP', 'Round trip test',
                    ST_GeomFromText('POINT(-2.6 51.46)', 4326), %s, CURRENT_DATE)
            RETURNING substation_id
            """,
            (any_source_id,),
        )
        sub_id = cur.fetchone()[0]
        cur.execute(
            "SELECT ST_AsText(geom), ST_SRID(geom) FROM iris_core.substation WHERE substation_id = %s",
            (sub_id,),
        )
        wkt, srid = cur.fetchone()
        assert wkt == "POINT(-2.6 51.46)"
        assert srid == 4326


def test_seed_screening_metrics_are_correct(conn):
    # Sanity check on the seed fixture itself: proves the spatial functions
    # used to derive these numbers behave as documented, not just that they run.
    with conn.cursor() as cur:
        cur.execute(
            "SELECT metric_value FROM iris_core.screening_layer "
            "WHERE vertical = 'bess' AND metric_name = 'nearest_substation_m'"
        )
        nearest_m = float(cur.fetchone()[0])
        assert 0 < nearest_m < 1000  # SUB-001 is a few hundred meters from PARCEL-001

        cur.execute(
            "SELECT metric_value FROM iris_core.screening_layer "
            "WHERE vertical = 'peatland' AND metric_name = 'overlap_pct'"
        )
        overlap_pct = float(cur.fetchone()[0])
        assert overlap_pct == pytest.approx(37.5, abs=0.1)
