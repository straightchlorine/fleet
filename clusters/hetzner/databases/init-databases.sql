-- Woodpecker CI database and user
CREATE USER woodpecker WITH PASSWORD 'CHANGE_ME';
CREATE DATABASE woodpecker OWNER woodpecker;
ALTER USER woodpecker CONNECTION LIMIT 20;

-- Grant only what's needed
GRANT CONNECT ON DATABASE woodpecker TO woodpecker;

-- Future services: add more CREATE USER / CREATE DATABASE blocks here
