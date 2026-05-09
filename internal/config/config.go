package config

import (
	"fmt"
	"os"
	"strconv"
)

type Config struct {
	// Kafka
	KafkaBrokers    string
	KafkaTopic      string
	KafkaGroupID    string
	TotalPartitions int

	// Redis
	RedisAddr string

	// Consumer
	InstanceID string
}

func Load() (*Config, error) {
	cfg := &Config{
		KafkaBrokers: getEnv("KAFKA_BROKERS", "kafka:9092"),
		KafkaTopic:   getEnv("KAFKA_TOPIC", "cdc.public.user_items_projection"),
		KafkaGroupID: getEnv("KAFKA_GROUP_ID", "cdc-consumer"),
		RedisAddr:    getEnv("REDIS_ADDR", "redis:6379"),
		InstanceID:   getEnv("INSTANCE_ID", "consumer-0"),
	}

	partitions, err := strconv.Atoi(getEnv("KAFKA_TOTAL_PARTITIONS", "5"))
	if err != nil {
		return nil, fmt.Errorf("invalid KAFKA_TOTAL_PARTITIONS: %w", err)
	}
	cfg.TotalPartitions = partitions

	return cfg, nil
}

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
