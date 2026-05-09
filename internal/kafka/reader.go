package kafka

import (
	"context"
	"fmt"
	"log/slog"
	"time"

	kafkago "github.com/segmentio/kafka-go"
)

// Reader wraps kafka-go reader with sensible defaults for CDC consumption.
type Reader struct {
	r   *kafkago.Reader
	log *slog.Logger
}

func NewReader(brokers, topic, groupID string, log *slog.Logger) *Reader {
	r := kafkago.NewReader(kafkago.ReaderConfig{
		Brokers:        []string{brokers},
		Topic:          topic,
		GroupID:        groupID,
		MinBytes:       1,
		MaxBytes:       10 << 20,
		MaxWait:        500 * time.Millisecond,
		CommitInterval: time.Second,
		StartOffset:    kafkago.FirstOffset,
	})
	return &Reader{r: r, log: log}
}

type Message struct {
	Topic     string
	Partition int
	Offset    int64
	Key       []byte
	Value     []byte
}

func (r *Reader) Read(ctx context.Context) (Message, error) {
	msg, err := r.r.ReadMessage(ctx)
	if err != nil {
		return Message{}, fmt.Errorf("kafka.Read: %w", err)
	}
	return Message{
		Topic:     msg.Topic,
		Partition: msg.Partition,
		Offset:    msg.Offset,
		Key:       msg.Key,
		Value:     msg.Value,
	}, nil
}

func (r *Reader) Close() error {
	return r.r.Close()
}

func (r *Reader) Stats() kafkago.ReaderStats {
	return r.r.Stats()
}
