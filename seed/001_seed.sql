-- Deterministic seed fixtures for the IRIS pilot.
-- Assumes a freshly reset DB (serial PKs start at 1) -- see README "assumptions".
--
-- Two scenarios are modeled, one per vertical:
--   PARCEL-001 (Bristol-area, fictional) sits ~300-6000m from two substations
--     -> demonstrates the BESS "nearest substation" screening metric.
--   PARCEL-002 (Lake District-area, fictional) partially overlaps PEAT-001
--     -> demonstrates the peatland "overlap_pct" screening metric.

INSERT INTO iris_core.source_run (country_code, source_name, source_date) VALUES
    ('GB', 'land_registry_extract',   '2026-01-15'),
    ('GB', 'peatland_survey_2025',    '2025-11-01'),
    ('GB', 'grid_substation_register','2026-02-01');

INSERT INTO iris_core.parcel (country_code, region_code, external_parcel_ref, geom, source_id, source_date) VALUES
    ('GB', 'ENG-SW', 'PARCEL-001',
     ST_GeomFromText('MULTIPOLYGON(((-2.5800 51.4500, -2.5786 51.4500, -2.5786 51.4509, -2.5800 51.4509, -2.5800 51.4500)))', 4326),
     1, '2026-01-15'),
    ('GB', 'ENG-NW', 'PARCEL-002',
     ST_GeomFromText('MULTIPOLYGON(((-3.4980 54.5000, -3.4900 54.5000, -3.4900 54.5009, -3.4980 54.5009, -3.4980 54.5000)))', 4326),
     1, '2026-01-15');

INSERT INTO iris_core.substation (country_code, region_code, external_substation_ref, name, voltage_kv, geom, source_id, source_date) VALUES
    ('GB', 'ENG-SW', 'SUB-001', 'Fictional Grid Point A', 33,
     ST_GeomFromText('POINT(-2.5750 51.4520)', 4326),
     3, '2026-02-01'),
    ('GB', 'ENG-SW', 'SUB-002', 'Fictional Grid Point B', 132,
     ST_GeomFromText('POINT(-2.6300 51.4700)', 4326),
     3, '2026-02-01');

INSERT INTO iris_core.peatland (country_code, region_code, external_peatland_ref, geom, peat_depth_class, eco_point_factor, source_id, source_date) VALUES
    ('GB', 'ENG-NW', 'PEAT-001',
     ST_GeomFromText('MULTIPOLYGON(((-3.5050 54.4990, -3.4950 54.4990, -3.4950 54.5060, -3.5050 54.5060, -3.5050 54.4990)))', 4326),
     'deep', 8,
     2, '2025-11-01');

-- BESS vertical: nearest substation distance (meters), computed geodesically.
INSERT INTO iris_core.screening_layer (country_code, region_code, parcel_id, vertical, metric_name, metric_value, source_id, source_date)
SELECT
    p.country_code,
    p.region_code,
    p.parcel_id,
    'bess',
    'nearest_substation_m',
    (SELECT MIN(ST_Distance(p.geom::geography, s.geom::geography))
     FROM iris_core.substation s
     WHERE s.country_code = p.country_code),
    3,
    '2026-02-01'
FROM iris_core.parcel p
WHERE p.external_parcel_ref = 'PARCEL-001';

-- Peatland vertical: % of parcel area overlapping mapped peatland.
INSERT INTO iris_core.screening_layer (country_code, region_code, parcel_id, vertical, metric_name, metric_value, geom, source_id, source_date)
SELECT
    p.country_code,
    p.region_code,
    p.parcel_id,
    'peatland',
    'overlap_pct',
    (SELECT ST_Area(ST_Intersection(p.geom, pl.geom)::geography) / ST_Area(p.geom::geography) * 100
     FROM iris_core.peatland pl
     WHERE pl.external_peatland_ref = 'PEAT-001'),
    (SELECT ST_Intersection(p.geom, pl.geom)
     FROM iris_core.peatland pl
     WHERE pl.external_peatland_ref = 'PEAT-001'),
    2,
    '2025-11-01'
FROM iris_core.parcel p
WHERE p.external_parcel_ref = 'PARCEL-002';

INSERT INTO iris_core.evidence (country_code, region_code, entity_type, entity_id, note, confidence, source_id, source_date)
SELECT p.country_code, p.region_code, 'parcel', p.parcel_id,
       'Parcel boundary taken directly from cadastral extract.', 0.95, 1, '2026-01-15'
FROM iris_core.parcel p WHERE p.external_parcel_ref = 'PARCEL-001';

INSERT INTO iris_core.evidence (country_code, region_code, entity_type, entity_id, note, confidence, source_id, source_date)
SELECT sl.country_code, sl.region_code, 'screening_layer', sl.screening_id,
       'Overlap percentage computed from peatland survey polygon intersection.', 0.8, 2, '2025-11-01'
FROM iris_core.screening_layer sl WHERE sl.metric_name = 'overlap_pct';
