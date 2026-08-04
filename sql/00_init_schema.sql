/*
===============================================================================
 Project      : Walmart Data Warehouse
 Author       : Nitin
 Description  : Initializes the Walmart database and creates the Medallion
                Architecture schemas.
 Created On   : 2026-08-04
===============================================================================
*/

-- Create the database if it does not already exist.
SELECT 'CREATE DATABASE walmart_db'
WHERE NOT EXISTS (
    SELECT 1
    FROM pg_database
    WHERE datname = 'walmart_db'
)\gexec

-- Connect to the database.
\c walmart_db

-- ============================================================================
-- Create Medallion Architecture Schemas
-- Bronze : Raw data ingested from source systems.
-- Silver : Cleaned, validated, and standardized data.
-- Gold   : Business-ready dimensional models and fact tables.
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS bronze;
CREATE SCHEMA IF NOT EXISTS silver;
CREATE SCHEMA IF NOT EXISTS gold;
