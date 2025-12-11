package entities

import (
	"encoding/base64"
	"encoding/json"
	"testing"
	"time"
)

func TestStreamUpdateAndFlags(t *testing.T) {
	stream := NewStream()
	if !stream.UpdateRequired() {
		t.Fatalf("new stream should require update")
	}

	tagID := "drop-tag"
	game := map[string]interface{}{"displayName": "Game"}
	stream.Update("id", "title", game, []map[string]interface{}{{"id": tagID}}, 100, tagID)

	if stream.Title != "title" || stream.BroadcastID != "id" {
		t.Fatalf("unexpected stream fields: %#v", stream)
	}
	if stream.DropsTags != true {
		t.Fatalf("expected drops tag detection")
	}
	if stream.UpdateRequired() {
		t.Fatalf("recent update should not require refresh")
	}
}

func TestStreamWatchProgress(t *testing.T) {
	stream := NewStream()
	stream.lastMinuteUpdate = time.Now().Add(-2 * time.Minute)
	stream.UpdateMinuteWatched()
	if stream.MinuteWatched < 1.9 || stream.MinuteWatched > 2.1 {
		t.Fatalf("minute watched out of range: %f", stream.MinuteWatched)
	}

	stream.ResetWatchProgress()
	if stream.MinuteWatched != 0 || !stream.lastMinuteUpdate.IsZero() {
		t.Fatalf("reset should clear progress")
	}
}

func TestStreamEncodePayload(t *testing.T) {
	stream := NewStream()
	stream.Payload = []map[string]interface{}{
		{"k": "v"},
	}

	encoded, err := stream.EncodePayload()
	if err != nil {
		t.Fatalf("encode payload error: %v", err)
	}
	data, ok := encoded["data"]
	if !ok || data == "" {
		t.Fatalf("expected base64 payload")
	}
	raw, err := base64.StdEncoding.DecodeString(data)
	if err != nil {
		t.Fatalf("base64 decode failed: %v", err)
	}
	var decoded []map[string]interface{}
	if err := json.Unmarshal(raw, &decoded); err != nil {
		t.Fatalf("json decode failed: %v", err)
	}
	if len(decoded) != 1 || decoded[0]["k"] != "v" {
		t.Fatalf("unexpected decoded payload: %#v", decoded)
	}
}

func TestStreamGameName(t *testing.T) {
	stream := NewStream()
	if stream.GameName() != "" {
		t.Fatalf("expected empty name for nil game")
	}
	stream.Game = map[string]interface{}{"displayName": "My Game"}
	if stream.GameName() != "My Game" {
		t.Fatalf("displayName not used")
	}
	stream.Game = map[string]interface{}{"name": "Other"}
	if stream.GameName() != "Other" {
		t.Fatalf("fallback name not used")
	}
}
