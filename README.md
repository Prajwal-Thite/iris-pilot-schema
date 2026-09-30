# IRIS Pilot — Canonical PostGIS Schema

Minimum reproducible PostgreSQL/PostGIS schema for the IRIS pilot: staging +
core schemas with country-aware keys, geometry contracts, source metadata,
and enough constraints to support the BESS and peatland verticals.

## Setup

Requires Docker and Python 3.12+ (developed against 3.14).

```bash
cd iris-pilot-schema
docker compose up -d                 # starts Postgres 16 + PostGIS 3.4 on localhost:5433
python -m venv .venv
.venv/Scripts/activate                # .venv/bin/activate on macOS/Linux
pip install -r requirements.txt
```

## Commands

```bash
python manage.py reset      # drop iris_core/iris_staging, replay all migrations, load seed fixtures
python manage.py migrate    # apply migrations only, no drop
python manage.py seed       # (re)load seed fixtures only

pytest tests/ -v             # automated tests (also runs `reset` once, see tests/conftest.py)

docker exec -i iris_pilot_db psql -U iris -d iris_pilot < docs/verification.sql   # manual acceptance-criteria checks
```

`manage.py` defaults to `postgresql://iris:iris@localhost:5433/iris_pilot`
(matching `docker-compose.yml`); override with the `DATABASE_URL` env var.

## Architecture

```
iris_staging   -- raw, loosely-typed landing tables (parcel_raw, substation_raw, peatland_raw)
                  geometry kept as unvalidated WKT text; mirrors what a source
                  adapter hands back before promotion.
iris_core      -- validated, constrained canonical tables the pilot queries against.
```

**Core tables:** `source_run`, `parcel`, `substation`, `peatland`,
`screening_layer`, `evidence`. See `docs/schema.mmd` for the full ER diagram.

- `source_run` is the source-metadata table: one row per ingestion event
  (source name, source date, country). Every other core table carries a
  `source_id` FK back to it, plus its own `source_date` (a denormalized
  snapshot for query convenience — see Simplifications).
- `parcel` / `substation` / `peatland` are the spatial entities: parcels
  being screened, grid connection points (BESS vertical), and mapped
  peatland areas (peatland vertical).
- `screening_layer` holds one row per `(parcel, vertical, metric)` — e.g.
  `(parcel_1, 'bess', 'nearest_substation_m', 278.6)`.
- `evidence` is a polymorphic justification table (`entity_type` +
  `entity_id`) attachable to any of the above without a join table per entity.

### Canonical contract

Every core business table (`parcel`, `substation`, `peatland`,
`screening_layer`) carries: `geom`, `country_code`, `region_code`,
`source_id`, `source_date`, `created_at`. The geometry column is always
`geom`, never `geometry`.

### Country-scoping

`country_code` is `NOT NULL` on every core table. Natural-key uniqueness is
always `UNIQUE (country_code, external_*_ref)`, never a bare global key —
so the same source reference number can exist independently in two
countries (proven by `test_same_external_ref_allowed_in_a_different_country`).

### CRS policy

All geometry is stored in **EPSG:4326** (WGS84 lat/lon) — the CRS almost
all open geospatial sources publish in, which minimises transform bugs at
ingestion. For metric operations (distance, area) that need to be
*accurate* rather than merely comparable, queries cast to `::geography`,
which PostGIS computes geodesically without needing to pick a per-region
projected SRID. `parcel.area_m2` is a generated column computed this way.

One consequence: a GiST index on the raw `geom` (geometry) column does
**not** accelerate operators applied to a `::geography` cast of it. The
index-friendly pattern used in `docs/verification.sql` is a bounding-box
prefilter on `geom` (`&&`, which the GiST index does accelerate) combined
with an accurate `::geography` distance as a plain filter — the standard
PostGIS "index-assisted, precisely-filtered" query shape.

### Geometry types

- `parcel`, `peatland`: `MultiPolygon` — real cadastral/habitat polygons
  are frequently multi-part.
- `substation`: `Point`.
- `screening_layer.geom`: generic `Geometry`, nullable — it's a derived
  result (e.g. an intersection) whose type depends on the inputs.

All geometry columns have a `CHECK (ST_IsValid(geom))` constraint and a
GiST index.

## Verifying acceptance criteria

1. **Rebuilds from empty DB without manual intervention** — `python
   manage.py reset` drops both schemas, replays migrations 001-003, and
   loads the seed fixture, all in one command (also exercised by
   `tests/conftest.py`'s session fixture before every test run).
2. **All required pilot query fields exist / canonical names** —
   `docs/verification.sql` §1 and `test_canonical_columns_present`.
3. **`country_code` cannot be null** — `docs/verification.sql` §3 and
   `test_parcel_country_code_cannot_be_null` /
   `test_source_run_country_code_cannot_be_null`.
4. **Spatial round trip and index usage** — `docs/verification.sql` §4-5
   and `test_spatial_round_trip`. Note on §5: with only two seed parcels,
   PostgreSQL's planner correctly costs a sequential scan as cheaper than
   an index scan — there isn't enough data for the index to pay off. The
   verification script sets `enable_seqscan = off` to force the planner
   onto the GiST indexes, proving they're present, valid, and usable
   (confirmed via `EXPLAIN ANALYZE`: `Index Scan using ix_parcel_geom` /
   `ix_peatland_geom`), not that the planner picks them at this data volume.

## Seed fixtures

`seed/001_seed.sql` is deterministic (assumes a fresh `reset`, so serial
PKs start at 1) and models one scenario per vertical:

- `PARCEL-001` (fictional, Bristol-area) sits ~279m from `SUB-001` →
  demonstrates the BESS `nearest_substation_m` metric.
- `PARCEL-002` (fictional, Lake District-area) overlaps `PEAT-001` by
  37.5% of its area → demonstrates the peatland `overlap_pct` metric.

Both metrics are computed in SQL from the actual geometries at seed time
(not hand-typed), so they double as a correctness check on the spatial
functions themselves.

## Deliberate simplifications (and how they'd evolve for production)

- **`evidence.entity_id` has no FK.** It's a polymorphic reference
  (`entity_type` + `entity_id` across four tables), and Postgres can't FK
  a column to different target tables conditionally. In production this
  moves to either one join table per entity type, or an application-layer
  check function via a trigger.
- **`source_date` is denormalized onto every core table** rather than
  requiring a join to `source_run`. This is intentional for query
  ergonomics (the pilot's "explainable spatial screening" queries need
  it directly), but it means `source_date` could in principle drift from
  its `source_run` if a row were re-sourced without updating both. A
  production version would either drop the denormalized column or add a
  trigger to keep them in sync.
- **No country→SRID/projection lookup table.** All accurate metric
  calculations use `::geography`, which avoids the problem entirely for
  distance and area, but is slower per-row than a properly indexed local
  projected CRS at national scale. If the pilot expands to
  heavier spatial workloads, add a `country_code -> projected_srid`
  reference table and generated projected-geometry columns.
- **Only two seed rows per table.** Enough to prove correctness
  deterministically and cheaply; not representative of production data
  volume or of the planner's real index-vs-seqscan behavior (see
  verification note above).
- **No migration-version tracking table** (e.g. no `schema_migrations`
  ledger). `manage.py migrate` just replays every `.sql` file in
  `migrations/` in filename order every time; fine for a from-scratch
  pilot rebuild, but a production tool would track which migrations have
  already run so `migrate` (as opposed to `reset`) is safe to run
  incrementally against a live, non-empty database.
