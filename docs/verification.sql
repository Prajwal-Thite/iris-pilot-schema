-- Manual verification queries for acceptance criteria.
-- Run with: docker exec -i iris_pilot_db psql -U iris -d iris_pilot < docs/verification.sql
-- (assumes `python manage.py reset` has already been run)

\pset pager off

-- === 1. Canonical columns present on every core business table ===
SELECT table_name, column_name
FROM information_schema.columns
WHERE table_schema = 'iris_core'
  AND column_name IN ('geom','country_code','region_code','source_id','source_date','created_at')
ORDER BY table_name, column_name;

-- === 2. No column literally named 'geometry' anywhere in iris_core ===
SELECT table_name, column_name
FROM information_schema.columns
WHERE table_schema = 'iris_core' AND column_name = 'geometry';
-- expect: 0 rows

-- === 3. country_code is NOT NULL on every core table ===
SELECT table_name, is_nullable
FROM information_schema.columns
WHERE table_schema = 'iris_core' AND column_name = 'country_code';
-- expect: is_nullable = 'NO' on every row

-- === 4. Spatial round trip: write a geometry, read it back losslessly ===
BEGIN;

INSERT INTO iris_core.source_run (country_code, source_name, source_date)
VALUES ('GB', 'verification_probe', CURRENT_DATE)
RETURNING source_id AS probe_source_id \gset

INSERT INTO iris_core.substation (country_code, region_code, external_substation_ref, name, geom, source_id, source_date)
VALUES ('GB', 'ENG-SW', 'SUB-PROBE', 'Round-trip probe',
        ST_GeomFromText('POINT(-2.6000 51.4600)', 4326), :probe_source_id, CURRENT_DATE)
RETURNING substation_id AS probe_substation_id \gset

SELECT ST_AsText(geom) AS round_trip_wkt, ST_SRID(geom) AS srid
FROM iris_core.substation WHERE substation_id = :probe_substation_id;
-- expect: round_trip_wkt = 'POINT(-2.6 51.46)', srid = 4326

ROLLBACK; -- probe data must not persist

-- === 5. Spatial index usage on the two pilot verticals ===
-- Note: with only two seed parcels, PostgreSQL's planner correctly costs a
-- sequential scan as cheaper than an index scan -- there just isn't enough
-- data for the index to pay off. enable_seqscan=off forces the planner to
-- use the GiST index where one exists, which is what this check is for:
-- proving the index is present, valid, and usable, not that the planner
-- picks it at production data volumes.
SET enable_seqscan = off;

-- Note: a GiST index on the raw `geom` (geometry) column does not
-- accelerate operators applied to a ::geography cast of it -- that would
-- need its own expression index. The index-friendly pattern is a bbox
-- prefilter on geometry (&&, which IS accelerated by ix_substation_geom)
-- followed by an accurate geography distance as a plain filter.
EXPLAIN ANALYZE
SELECT p.parcel_id
FROM iris_core.parcel p
JOIN iris_core.substation s
  ON s.country_code = p.country_code
 AND p.geom && ST_Expand(s.geom, 0.02)               -- ~2km bbox prefilter, index-accelerated
 AND ST_DWithin(p.geom::geography, s.geom::geography, 1000)  -- exact distance, meters
WHERE p.country_code = 'GB';
-- expect: plan references ix_substation_geom (GiST) via a bbox (&&) index condition

EXPLAIN ANALYZE
SELECT p.parcel_id, pl.peatland_id
FROM iris_core.parcel p
JOIN iris_core.peatland pl
  ON pl.country_code = p.country_code
 AND ST_Intersects(p.geom, pl.geom)
WHERE p.country_code = 'GB';
-- expect: plan references ix_parcel_geom / ix_peatland_geom (GiST)

RESET enable_seqscan;
