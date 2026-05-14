package main

import (
	"context"
	"log/slog"
	"os"
	"os/signal"
	"syscall"

	"cdc-consumer/internal/config"
	kafkaclient "cdc-consumer/internal/kafka"
	redisclient "cdc-consumer/internal/redis"
)

func main() {
	log := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		Level: slog.LevelInfo,
	}))

	cfg, err := config.Load()
	if err != nil {
		log.Error("failed to load config", "err", err)
		os.Exit(1)
	}

	log.Info("starting kafka",
		"instance", cfg.InstanceID,
		"brokers", cfg.KafkaBrokers,
		"topic", cfg.KafkaTopic,
		"group", cfg.KafkaGroupID,
		"redis", cfg.RedisAddr,
		"total_partitions", cfg.TotalPartitions,
	)

	// redis
	rdb := redisclient.New(cfg.RedisAddr, log)
	defer rdb.Close()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	if err := rdb.Ping(ctx); err != nil {
		log.Error("redis unreachable", "err", err)
		os.Exit(1)
	}

	if err := rdb.InitNamespace(ctx); err != nil {
		log.Error("failed to init namespace", "err", err)
		os.Exit(1)
	}

	// kafka reader — kafka group handles partition assignment automatically
	// with 5 instances and 5 partitions each instance gets exactly 1 partition
	reader := kafkaclient.NewReader(cfg.KafkaBrokers, cfg.KafkaTopic, cfg.KafkaGroupID, log)
	defer reader.Close()

	// @TODO how versioning fence working?
	handler := kafkaclient.NewHandler(rdb, cfg.TotalPartitions, log)

	// graceful shutdown on SIGTERM / SIGINT
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGTERM, syscall.SIGINT)
	go func() {
		sig := <-sigCh
		log.Info("received signal, shutting down", "signal", sig)
		cancel()
	}()

	log.Info("kafka running")

	for {
		msg, err := reader.Read(ctx)
		if err != nil {
			if ctx.Err() != nil {
				// context cancelled — clean shutdown
				log.Info("kafka stopped")
				return
			}
			log.Error("kafka read error", "err", err)
			continue
		}

		if err := handler.Handle(ctx, msg); err != nil {
			// log and continue — do not crash on a single bad event
			// in production you'd send this to a DLQ
			log.Error("handle error",
				"err", err,
				"partition", msg.Partition,
				"offset", msg.Offset,
			)
		}
	}
}
