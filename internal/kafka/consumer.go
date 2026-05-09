package kafka

import (
	"context"
	"fmt"
	"log/slog"

	"cdc-consumer/internal/event"
	rdb "cdc-consumer/internal/redis"
)

// Handler processes a single CDC event and applies counter deltas to Redis.
type Handler struct {
	redis           *rdb.Client
	totalPartitions int
	log             *slog.Logger
}

func NewHandler(redis *rdb.Client, totalPartitions int, log *slog.Logger) *Handler {
	return &Handler{
		redis:           redis,
		totalPartitions: totalPartitions,
		log:             log,
	}
}

// Handle processes one Kafka message.
func (h *Handler) Handle(ctx context.Context, msg Message) error {
	// tombstone — null value produced after a hard delete
	if len(msg.Value) == 0 {
		h.log.Debug("tombstone received, skipping", "partition", msg.Partition, "offset", msg.Offset)
		return nil
	}

	env, err := event.Parse(msg.Value)
	if err != nil {
		return fmt.Errorf("handler.Handle parse: %w", err)
	}

	// determine write namespace
	namespace, err := h.resolveNamespace(ctx, env)
	if err != nil {
		return fmt.Errorf("handler.Handle namespace: %w", err)
	}

	// compute and apply counter delta
	if err := h.applyDelta(ctx, env, namespace); err != nil {
		return fmt.Errorf("handler.Handle delta: %w", err)
	}

	// resnapshot watermark check
	if err := h.checkWatermark(ctx, env, msg.Partition); err != nil {
		return fmt.Errorf("handler.Handle watermark: %w", err)
	}

	h.log.Debug("event processed",
		"op", env.Op,
		"partition", msg.Partition,
		"offset", msg.Offset,
		"namespace", namespace,
	)
	return nil
}

// resolveNamespace returns the Redis namespace to write to for this event.
func (h *Handler) resolveNamespace(ctx context.Context, env *event.Envelope) (string, error) {
	snapTx := env.SnapshotTxID()
	if snapTx != "" {
		// bump event — always goes to its own snapshot namespace
		return rdb.NamespaceForSnapshot(snapTx), nil
	}
	// live event — goes to whatever is currently live
	return h.redis.CurrentNamespace(ctx)
}

// applyDelta computes the counter delta from the event and writes it to Redis.
func (h *Handler) applyDelta(ctx context.Context, env *event.Envelope, namespace string) error {
	// need at least an after row for non-delete events
	after := env.After
	before := env.Before

	var userID, workItemID, role string
	var incomingVersion int64
	var delta int

	switch env.Op {
	case event.OpCreate, event.OpRead:
		// new row — no before state
		if after == nil {
			return nil
		}
		userID, workItemID, role = after.UserID, after.WorkItemID, after.Role
		incomingVersion = after.Version
		if event.IsActive(after) {
			delta = 1
		}

	case event.OpDelete:
		// row deleted — no after state
		if before == nil {
			return nil
		}
		userID, workItemID, role = before.UserID, before.WorkItemID, before.Role
		incomingVersion = before.Version
		if event.IsActive(before) {
			delta = -1
		}

	case event.OpUpdate:
		if after == nil {
			return nil
		}
		userID, workItemID, role = after.UserID, after.WorkItemID, after.Role
		incomingVersion = after.Version

		// role change — before and after have different roles
		// treat as: remove old role contribution, add new role contribution
		if before != nil && before.Role != after.Role {
			// decrement old role if it was active
			if event.IsActive(before) {
				if err := h.redis.ApplyDelta(ctx,
					namespace, before.UserID, before.WorkItemID, before.Role,
					before.Version, -1,
				); err != nil {
					return err
				}
			}
			// increment new role if now active
			if event.IsActive(after) {
				delta = 1
			}
		} else {
			// same role — compute transition
			wasActive := event.IsActive(before)
			nowActive := event.IsActive(after)
			switch {
			case !wasActive && nowActive:
				delta = 1
			case wasActive && !nowActive:
				delta = -1
			}
		}

	default:
		h.log.Warn("unknown op", "op", env.Op)
		return nil
	}

	return h.redis.ApplyDelta(ctx, namespace, userID, workItemID, role, incomingVersion, delta)
}

// checkWatermark detects whether this event crosses the resnapshot
// watermark for its partition and votes accordingly.
func (h *Handler) checkWatermark(ctx context.Context, env *event.Envelope, partition int) error {
	if !env.IsBumpEvent() {
		return nil
	}

	snapTx := env.SnapshotTxID()
	pgTxID := rdb.ExtractPgTxID(env.TxID())

	// only vote when the event's transaction matches the bump transaction
	// (IsBumpEvent already checks this, but being explicit)
	if pgTxID != snapTx {
		return nil
	}

	flipped, newNS, err := h.redis.VotePartitionDone(ctx, snapTx, partition, h.totalPartitions)
	if err != nil {
		return err
	}

	if flipped {
		h.log.Info("resnapshot complete — namespace flipped",
			"snapshot_tx_id", snapTx,
			"new_namespace", newNS,
		)
		// clean up coordination keys asynchronously
		go func() {
			if err := h.redis.CleanupSnapshotKeys(context.Background(), snapTx); err != nil {
				h.log.Error("cleanup snapshot keys failed", "err", err)
			}
		}()
	} else {
		h.log.Info("partition voted ready for resnapshot",
			"snapshot_tx_id", snapTx,
			"partition", partition,
		)
	}
	return nil
}
