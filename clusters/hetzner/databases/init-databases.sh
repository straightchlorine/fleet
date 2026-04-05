#!/bin/bash
set -e

# Reads credentials from environment variables injected via Secret
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres <<-EOSQL
    CREATE USER $WP_DB_USER WITH PASSWORD '$WP_DB_PASSWORD';
    CREATE DATABASE $WP_DB_NAME OWNER $WP_DB_USER;
    ALTER USER $WP_DB_USER CONNECTION LIMIT 20;
    GRANT CONNECT ON DATABASE $WP_DB_NAME TO $WP_DB_USER;
EOSQL
