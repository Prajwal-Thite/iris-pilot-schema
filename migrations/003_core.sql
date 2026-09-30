-- Migration 003: iris_core tables
--
-- CRS policy: all geometry is stored in EPSG:4326 (WGS84 lat/lon). This is
-- the CRS almost all open geospatial sources publish in, so it minimises
-- transform bugs at ingestion. For metric operations (distance, area) that
-- need to be accurate rather than merely comparable, queries cast to
-- ::geography, which PostGIS computes geodesically in meters without
-- picking a per-region projected SRID. See docs/verification.sql for
-- examples.
--
-- Geometry types: MultiPolygon for area features (parcel, peatland) since
-- real cadastral/habitat polygons are frequently multi-part; Point for
-- substation. screening_layer stores a generic Geometry because its geom
-- is a derived result (e.g. an intersection) whose type depends on the
-- inputs.

CREATE TABLE iris_core.source_run (
    source_id     BIGSERIAL PRIMARY KEY,
    country_code  TEXT NOT NULL,
    source_name   TEXT NOT NULL,
    source_date   DATE NOT NULL,
    retrieved_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX ix_source_run_country ON iris_core.source_run (country_code);

CREATE TABLE iris_core.parcel (
    parcel_id            BIGSERIAL PRIMARY KEY,
    country_code         TEXT NOT NULL,
    region_code          TEXT NOT NULL,
    external_parcel_ref  TEXT NOT NULL,
    geom                 geometry(MultiPolygon, 4326) NOT NULL,
    area_m2              NUMERIC GENERATED ALWAYS AS (ST_Area(geom::geography)) STORED,
    source_id            BIGINT NOT NULL REFERENCES iris_core.source_run (source_id),
    source_date          DATE NOT NULL,
    created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_parcel_country_ref UNIQUE (country_code, external_parcel_ref),
    CONSTRAINT chk_parcel_geom_valid CHECK (ST_IsValid(geom))
);

CREATE INDEX ix_parcel_geom ON iris_core.parcel USING GIST (geom);
CREATE INDEX ix_parcel_country_region ON iris_core.parcel (country_code, region_code);
CREATE INDEX ix_parcel_source ON iris_core.parcel (source_id);

CREATE TABLE iris_core.substation (
    substation_id            BIGSERIAL PRIMARY KEY,
    country_code             TEXT NOT NULL,
    region_code              TEXT NOT NULL,
    external_substation_ref  TEXT NOT NULL,
    name                     TEXT NOT NULL,
    voltage_kv               NUMERIC,
    geom                     geometry(Point, 4326) NOT NULL,
    source_id                BIGINT NOT NULL REFERENCES iris_core.source_run (source_id),
    source_date              DATE NOT NULL,
    created_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_substation_country_ref UNIQUE (country_code, external_substation_ref),
    CONSTRAINT chk_substation_geom_valid CHECK (ST_IsValid(geom))
);

CREATE INDEX ix_substation_geom ON iris_core.substation USING GIST (geom);
CREATE INDEX ix_substation_country_region ON iris_core.substation (country_code, region_code);
CREATE INDEX ix_substation_source ON iris_core.substation (source_id);

CREATE TABLE iris_core.peatland (
    peatland_id            BIGSERIAL PRIMARY KEY,
    country_code            TEXT NOT NULL,
    region_code             TEXT NOT NULL,
    external_peatland_ref   TEXT NOT NULL,
    geom                     geometry(MultiPolygon, 4326) NOT NULL,
    peat_depth_class         TEXT,
    eco_point_factor         NUMERIC NOT NULL DEFAULT 8,
    source_id                BIGINT NOT NULL REFERENCES iris_core.source_run (source_id),
    source_date              DATE NOT NULL,
    created_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_peatland_country_ref UNIQUE (country_code, external_peatland_ref),
    CONSTRAINT chk_peatland_geom_valid CHECK (ST_IsValid(geom))
);

CREATE INDEX ix_peatland_geom ON iris_core.peatland USING GIST (geom);
CREATE INDEX ix_peatland_country_region ON iris_core.peatland (country_code, region_code);
CREATE INDEX ix_peatland_source ON iris_core.peatland (source_id);

-- One row per (parcel, vertical, metric): e.g. (parcel_1, 'bess',
-- 'nearest_substation_m', 812.4) or (parcel_1, 'peatland',
-- 'overlap_pct', 63.2).
CREATE TABLE iris_core.screening_layer (
    screening_id  BIGSERIAL PRIMARY KEY,
    country_code  TEXT NOT NULL,
    region_code   TEXT NOT NULL,
    parcel_id     BIGINT NOT NULL REFERENCES iris_core.parcel (parcel_id),
    vertical      TEXT NOT NULL CHECK (vertical IN ('bess', 'peatland')),
    metric_name   TEXT NOT NULL,
    metric_value  NUMERIC NOT NULL,
    geom          geometry(Geometry, 4326),
    source_id     BIGINT NOT NULL REFERENCES iris_core.source_run (source_id),
    source_date   DATE NOT NULL,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_screening_parcel_metric UNIQUE (country_code, parcel_id, vertical, metric_name),
    CONSTRAINT chk_screening_geom_valid CHECK (geom IS NULL OR ST_IsValid(geom))
);

CREATE INDEX ix_screening_geom ON iris_core.screening_layer USING GIST (geom) WHERE geom IS NOT NULL;
CREATE INDEX ix_screening_parcel ON iris_core.screening_layer (parcel_id);
CREATE INDEX ix_screening_country_vertical ON iris_core.screening_layer (country_code, vertical);

-- entity_type/entity_id is a polymorphic reference (parcel, substation,
-- peatland or screening_layer). Postgres can't FK across multiple target
-- tables, so referential integrity here is enforced at the
-- application/loader layer, not the database layer -- documented
-- simplification, see README.
CREATE TABLE iris_core.evidence (
    evidence_id   BIGSERIAL PRIMARY KEY,
    country_code  TEXT NOT NULL,
    region_code   TEXT,
    entity_type   TEXT NOT NULL CHECK (entity_type IN ('parcel', 'substation', 'peatland', 'screening_layer')),
    entity_id     BIGINT NOT NULL,
    note          TEXT,
    confidence    NUMERIC CHECK (confidence BETWEEN 0 AND 1),
    source_id     BIGINT NOT NULL REFERENCES iris_core.source_run (source_id),
    source_date   DATE NOT NULL,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX ix_evidence_entity ON iris_core.evidence (entity_type, entity_id);
CREATE INDEX ix_evidence_country ON iris_core.evidence (country_code);
CREATE INDEX ix_evidence_source ON iris_core.evidence (source_id);
