package redis

import (
	"context"
	"fmt"
	"log/slog"
	"strings"

	"github.com/redis/go-redis/v9"
)

const keySnapshotCurrent = "snapshot:current"

// Client wraps go-redis for CDC counter operations.
type Client struct {
	rdb *redis.Client
	log *slog.Logger
}

func New(addr string, log *slog.Logger) *Client {
	return &Client{
		rdb: redis.NewClient(&redis.Options{Addr: addr}),
		log: log,
	}
}

func (c *Client) Close() error {
	return c.rdb.Close()
}

func (c *Client) Ping(ctx context.Context) error {
	return c.rdb.Ping(ctx).Err()
}

// InitNamespace sets snapshot:current to "live" if not already set.
// Call once on startup.
func (c *Client) InitNamespace(ctx context.Context) error {
	return c.rdb.SetNX(ctx, keySnapshotCurrent, "live", 0).Err()
}

// CurrentNamespace returns the active namespace label.
func (c *Client) CurrentNamespace(ctx context.Context) (string, error) {
	v, err := c.rdb.Get(ctx, keySnapshotCurrent).Result()
	if err != nil {
		return "", fmt.Errorf("redis.CurrentNamespace: %w", err)
	}
	return v, nil
}

// CounterKey returns the Redis hash key for a user's counters.
func CounterKey(namespace, userID string) string {
	return fmt.Sprintf("counters:%s:%s", namespace, userID)
}

// VersionKey returns the Redis hash key storing per-row versions for a user.
// Field format: "<work_item_id>:<role>"
func VersionKey(namespace, userID string) string {
	return fmt.Sprintf("versions:%s:%s", namespace, userID)
}

// versionFencedDelta atomically:
//  1. checks the stored version for (userID, workItemID, role)
//  2. rejects if stored >= incoming (stale event)
//  3. updates the stored version
//  4. applies delta to counters:{ns}:{userID}  field active:{role}
//
// Returns 1 if applied, 0 if rejected.
//
// KEYS[1] = versions key   (versions:{ns}:{user})
// KEYS[2] = counters key   (counters:{ns}:{user})
// ARGV[1] = version field  (<work_item_id>:<role>)
// ARGV[2] = incoming version
// ARGV[3] = counter field  (active:<role>)
// ARGV[4] = delta          (+1 or -1)
const luaApplyDelta = `
local cur = tonumber(redis.call('HGET', KEYS[1], ARGV[1]) or -1)
if cur >= tonumber(ARGV[2]) then return 0 end
redis.call('HSET', KEYS[1], ARGV[1], ARGV[2])
if tonumber(ARGV[4]) ~= 0 then
  redis.call('HINCRBY', KEYS[2], ARGV[3], ARGV[4])
end
return 1
`

// ApplyDelta applies a counter delta for a single projection row event.
// delta: +1 (became active), -1 (became inactive/deleted), 0 (no change).
func (c *Client) ApplyDelta(
	ctx context.Context,
	namespace, userID, workItemID, role string,
	incomingVersion int64,
	delta int,
) error {
	if delta == 0 {
		// still need to advance the version fence
	}

	versionKey := VersionKey(namespace, userID)
	counterKey := CounterKey(namespace, userID)
	versionField := fmt.Sprintf("%s:%s", workItemID, role)
	counterField := fmt.Sprintf("active:%s", role)

	res, err := c.rdb.Eval(ctx, luaApplyDelta,
		[]string{versionKey, counterKey},
		versionField,
		incomingVersion,
		counterField,
		delta,
	).Int()
	if err != nil {
		return fmt.Errorf("redis.ApplyDelta: %w", err)
	}
	if res == 0 {
		c.log.Debug("version fence rejected stale event",
			"user", userID, "item", workItemID, "role", role,
			"version", incomingVersion)
	}
	return nil
}

// VotePartitionDone marks a partition as having crossed the resnapshot
// watermark. If this is the last partition, atomically flips
// snapshot:current and returns the new namespace. Returns "" if not done yet.
//
// KEYS[1] = snapshot:tx:{tx_id}:done
// KEYS[2] = snapshot:current
// ARGV[1] = partition id
// ARGV[2] = total partitions
// ARGV[3] = new namespace label  ("rs-" + snapshot_tx_id)
const luaVoteAndFlip = `
redis.call('SADD', KEYS[1], ARGV[1])
local done  = tonumber(redis.call('SCARD', KEYS[1]))
local total = tonumber(ARGV[2])
if done < total then return "" end
redis.call('SET', KEYS[2], ARGV[3])
return ARGV[3]
`

func (c *Client) VotePartitionDone(
	ctx context.Context,
	snapshotTxID string,
	partitionID int,
	totalPartitions int,
) (flipped bool, newNamespace string, err error) {
	doneKey := fmt.Sprintf("snapshot:tx:%s:done", snapshotTxID)
	newNS := "rs-" + snapshotTxID

	result, err := c.rdb.Eval(ctx, luaVoteAndFlip,
		[]string{doneKey, keySnapshotCurrent},
		partitionID,
		totalPartitions,
		newNS,
	).Text()
	if err != nil && err != redis.Nil {
		return false, "", fmt.Errorf("redis.VotePartitionDone: %w", err)
	}
	if result == "" {
		return false, "", nil
	}
	return true, result, nil
}

// CleanupSnapshotKeys removes the ephemeral coordination keys
// after a successful flip.
func (c *Client) CleanupSnapshotKeys(ctx context.Context, snapshotTxID string) error {
	key := fmt.Sprintf("snapshot:tx:%s:done", snapshotTxID)
	return c.rdb.Del(ctx, key).Err()
}

// NamespaceForSnapshot derives the Redis namespace from a snapshot tx id.
func NamespaceForSnapshot(snapshotTxID string) string {
	return "rs-" + snapshotTxID
}

// ExtractPgTxID extracts the Postgres transaction id from a Debezium
// transaction.id string of format "<pg_xact_id>:<lsn>".
func ExtractPgTxID(debeziumTxID string) string {
	if i := strings.Index(debeziumTxID, ":"); i > 0 {
		return debeziumTxID[:i]
	}
	return debeziumTxID
}
