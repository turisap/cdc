package event

import "encoding/json"

// Op represents the Debezium operation type.
type Op string

const (
	OpCreate Op = "c"
	OpUpdate Op = "u"
	OpDelete Op = "d"
	OpRead   Op = "r" // snapshot read
)

// Row is the shape of a single user_items_projection row
// as it appears in both before and after fields.
type Row struct {
	UserID       string  `json:"user_id"`
	WorkItemID   string  `json:"work_item_id"`
	Role         string  `json:"role"`
	Status       string  `json:"status"`
	DueAt        *string `json:"due_at"`
	CreatedAt    string  `json:"created_at"`
	UpdatedAt    string  `json:"updated_at"`
	Version      int64   `json:"version"`
	SnapshotTxID *string `json:"snapshot_tx_id"`
	ServiceID    string  `json:"service_id"`
}

// Source contains Debezium source metadata.
type Source struct {
	DB    string `json:"db"`
	Table string `json:"table"`
	TxID  int64  `json:"txId"`
	LSN   int64  `json:"lsn"`
	TsMs  int64  `json:"ts_ms"`
}

// Transaction contains transaction metadata.
// ID format from Debezium: "<tx_id>:<lsn>"
type Transaction struct {
	ID                  string `json:"id"`
	TotalOrder          int64  `json:"total_order"`
	DataCollectionOrder int64  `json:"data_collection_order"`
}

// Envelope is the raw Debezium message envelope (no unwrap SMT).
type Envelope struct {
	Before      *Row         `json:"before"`
	After       *Row         `json:"after"`
	Op          Op           `json:"op"`
	TsMs        int64        `json:"ts_ms"`
	Source      Source       `json:"source"`
	Transaction *Transaction `json:"transaction"`
}

// Parse deserialises a raw Kafka message value into an Envelope.
func Parse(data []byte) (*Envelope, error) {
	var env Envelope
	if err := json.Unmarshal(data, &env); err != nil {
		return nil, err
	}
	return &env, nil
}

// IsActive returns true if the given row represents an active work item.
func IsActive(r *Row) bool {
	return r != nil && r.Status == "active"
}

// SnapshotTxID extracts the snapshot tx id from the after row, if any.
func (e *Envelope) SnapshotTxID() string {
	if e.After != nil && e.After.SnapshotTxID != nil {
		return *e.After.SnapshotTxID
	}
	return ""
}

// TxID extracts the raw transaction id string from the envelope.
// Debezium format: "<pg_tx_id>:<lsn>"
func (e *Envelope) TxID() string {
	if e.Transaction != nil {
		return e.Transaction.ID
	}
	return ""
}

// IsBumpEvent returns true when this event belongs to a resnapshot
// bump transaction — i.e. after.snapshot_tx_id is set and the
// transaction id starts with that value.
func (e *Envelope) IsBumpEvent() bool {
	snapTx := e.SnapshotTxID()
	if snapTx == "" {
		return false
	}
	txID := e.TxID()
	if txID == "" {
		return false
	}
	// transaction.id format: "<pg_xact_id>:<lsn>"
	// snapshot_tx_id is just the pg_xact_id part
	return len(txID) >= len(snapTx) && txID[:len(snapTx)] == snapTx
}
