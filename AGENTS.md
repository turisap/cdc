# cdc

Pet project for CDC (Change Data Capture) - deriving data from Postgres to Redis via Kafka and Debezium.

## Project Structure

- `docker-compose.yml` - Docker services: Postgres, Kafka, Redis, Kafka UI (Debezium commented out)
- `.env` - Environment variables for all services
- `taskfile.yml` - Global task file loading .env
- `scripts/dev.yml` - Dev tasks for docker compose operations
- `debezium-config/` - Debezium configuration (not currently working)

## Services

| Service  | Port | Description |
|----------|------|-------------|
| Postgres | 5432 | Source database |
| Kafka    | 9092 | Message broker |
| Redis    | 6379 | Target cache |
| Kafka UI | 8080 | Web UI for Kafka cluster management |

## Tasks

- `task dev:up` - Start all services
- `task dev:down` - Stop all services  
- `task dev:restart` - Restart all services

## Notes

- Kafka UI available at http://localhost:8080
- Debezium is currently disabled due to kafka serializer configuration issues
- Kafka uses single-node configuration (KAFKA_NODE_ID=1, replication factor=1)