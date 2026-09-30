-- Migration 002: iris_staging tables
--
-- Staging mirrors what a source adapter hands back before promotion into
-- iris_core: loosely typed, geometry kept as raw WKT text (not yet parsed or
-- validated), everything nullable except the columns needed to trace
-- provenance. Promotion into iris_core is where geometry gets parsed,
-- validated (ST_IsValid), and constraints get enforced.

CREATE TABLE iris_staging.parcel_raw (
    staging_id           BIGSERIAL PRIMARY KEY,
    country_code         TEXT,
    region_code          TEXT,
    external_parcel_ref  TEXT,
    geom_wkt             TEXT,
    source_id            BIGINT,
    source_date          DATE,
    raw_payload          JSONB,
    loaded_at            TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE iris_staging.substation_raw (
    staging_id               BIGSERIAL PRIMARY KEY,
    country_code             TEXT,
    region_code              TEXT,
    external_substation_ref  TEXT,
    name                     TEXT,
    voltage_kv               NUMERIC,
    geom_wkt                 TEXT,
    source_id                BIGINT,
    source_date              DATE,
    raw_payload              JSONB,
    loaded_at                TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE iris_staging.peatland_raw (
    staging_id              BIGSERIAL PRIMARY KEY,
    country_code            TEXT,
    region_code             TEXT,
    external_peatland_ref   TEXT,
    peat_depth_class        TEXT,
    eco_point_factor        NUMERIC,
    geom_wkt                TEXT,
    source_id               BIGINT,
    source_date             DATE,
    raw_payload             JSONB,
    loaded_at               TIMESTAMPTZ NOT NULL DEFAULT now()
);
