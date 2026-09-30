-- Migration 001: extensions and schemas
-- iris_staging: raw, loosely-typed landing area for source data before validation
-- iris_core: validated, constrained canonical tables the pilot queries against

CREATE EXTENSION IF NOT EXISTS postgis;

CREATE SCHEMA IF NOT EXISTS iris_staging;
CREATE SCHEMA IF NOT EXISTS iris_core;
