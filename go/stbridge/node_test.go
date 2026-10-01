package stbridge

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func newTestNode(t *testing.T) (*Node, string) {
	t.Helper()
	dir := t.TempDir()
	n, err := NewNode(filepath.Join(dir, "config"), filepath.Join(dir, "data"), filepath.Join(dir, "folders"))
	if err != nil {
		t.Fatal(err)
	}
	if err := n.Start("test-phone"); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(n.Stop)
	// Keep tests local: no discovery/relays, loopback listener.
	if err := n.SetOptionsJSON(`{"listenAddresses":["tcp://127.0.0.1:22100"],"globalAnnounceEnabled":false,
		"localAnnounceEnabled":false,"relaysEnabled":false,"natEnabled":false}`); err != nil {
		t.Fatal(err)
	}
	return n, dir
}

// decode[T](t)(n.SomeJSON()) unmarshals a bridge result, failing on error.
func decode[T any](t *testing.T) func(string, error) T {
	return func(js string, err error) T {
		t.Helper()
		if err != nil {
			t.Fatal(err)
		}
		var v T
		if err := json.Unmarshal([]byte(js), &v); err != nil {
			t.Fatalf("%v: %s", err, js)
		}
		return v
	}
}

func TestNodeLifecycleAndQueries(t *testing.T) {
	n, dir := newTestNode(t)

	status := decode[map[string]any](t)(n.StatusJSON())
	if status["myID"] != n.DeviceID() {
		t.Fatalf("myID mismatch: %v", status["myID"])
	}
	devices := decode[[]map[string]any](t)(n.DevicesJSON())
	if len(devices) != 1 || devices[0]["name"] != "test-phone" {
		t.Fatalf("expected only this device, named test-phone: %v", devices)
	}

	opts := decode[map[string]any](t)(n.OptionsJSON())
	if opts["urAccepted"].(float64) != -1 || opts["crashReportingEnabled"] != false {
		t.Fatalf("telemetry must be off: %v", opts)
	}

	// Folder defaults point inside the app's folder root.
	def := decode[map[string]any](t)(n.DefaultFolderJSON())
	if def["path"] != filepath.Join(dir, "folders") {
		t.Fatalf("default folder path = %v", def["path"])
	}

	path := filepath.Join(dir, "folders", "docs")
	if err := n.SetFolderJSON(fmt.Sprintf(`{"id":"docs","label":"Docs","path":%q}`, path)); err != nil {
		t.Fatal(err)
	}
	folders := decode[[]map[string]any](t)(n.FoldersJSON())
	if len(folders) != 1 || folders[0]["id"] != "docs" {
		t.Fatalf("folders = %v", folders)
	}
	waitFor(t, 10*time.Second, func() bool {
		s := decode[map[string]any](t)(n.FolderStatusJSON("docs"))
		return s["state"] == "idle"
	})
	if err := n.SetFolderPaused("docs", true); err != nil {
		t.Fatal(err)
	}
	if err := n.Scan(""); err != nil {
		t.Logf("scan all with paused folder: %v", err)
	}

	evs := decode[[]map[string]any](t)(n.Events(0, 1, 1))
	if len(evs) != 1 {
		t.Fatalf("expected latest event, got %v", evs)
	}

	// Restart in-process (app backgrounded and foregrounded).
	n.Stop()
	if n.IsRunning() {
		t.Fatal("still running")
	}
	if _, err := n.StatusJSON(); err == nil {
		t.Fatal("expected not-running error")
	}
	if err := n.Start("test-phone"); err != nil {
		t.Fatal(err)
	}
	folders = decode[[]map[string]any](t)(n.FoldersJSON())
	if len(folders) != 1 || folders[0]["paused"] != true {
		t.Fatalf("config not persisted across restart: %v", folders)
	}
}

func waitFor(t *testing.T, timeout time.Duration, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatal("timed out")
		}
		time.Sleep(200 * time.Millisecond)
	}
}

// --- End-to-end against a separate Syncthing process (the "Mac") ---

type peer struct {
	url, key string
}

func (p peer) do(t *testing.T, method, path string, body any) []byte {
	t.Helper()
	var r io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		r = bytes.NewReader(b)
	}
	req, _ := http.NewRequest(method, p.url+path, r)
	req.Header.Set("X-API-Key", p.key)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	out, _ := io.ReadAll(resp.Body)
	if resp.StatusCode >= 300 {
		t.Fatalf("%s %s: %d %s", method, path, resp.StatusCode, out)
	}
	return out
}

// TestSyncWithPeer requires a running Syncthing listening for sync on
// tcp://127.0.0.1:22001 with its REST API at PEER_URL (see scripts/e2e-peer.sh).
func TestSyncWithPeer(t *testing.T) {
	url, key := os.Getenv("PEER_URL"), os.Getenv("PEER_API_KEY")
	if url == "" {
		t.Skip("set PEER_URL and PEER_API_KEY to run")
	}
	mac := peer{url, key}
	var macStatus map[string]any
	json.Unmarshal(mac.do(t, "GET", "/rest/system/status", nil), &macStatus)
	macID := macStatus["myID"].(string)

	phone, dir := newTestNode(t)
	phoneID := phone.DeviceID()
	folderID := fmt.Sprintf("e2e-%d", time.Now().UnixNano())
	macDir := t.TempDir()
	phoneDir := filepath.Join(dir, "folders", "shared")

	// Pair both ways.
	if err := phone.SetDeviceJSON(fmt.Sprintf(`{"deviceID":%q,"name":"mac","addresses":["tcp://127.0.0.1:22001"]}`, macID)); err != nil {
		t.Fatal(err)
	}
	mac.do(t, "POST", "/rest/config/devices", map[string]any{
		"deviceID": phoneID, "name": "phone", "addresses": []string{"tcp://127.0.0.1:22100"},
	})
	t.Cleanup(func() {
		mac.do(t, "DELETE", "/rest/config/folders/"+folderID, nil)
		mac.do(t, "DELETE", "/rest/config/devices/"+phoneID, nil)
	})

	// Share a folder.
	mac.do(t, "POST", "/rest/config/folders", map[string]any{
		"id": folderID, "label": "Shared", "path": macDir, "fsWatcherEnabled": false, "rescanIntervalS": 5,
		"devices": []map[string]string{{"deviceID": phoneID}},
	})
	if err := phone.SetFolderJSON(fmt.Sprintf(`{"id":%q,"label":"Shared","path":%q,"fsWatcherEnabled":false,
		"rescanIntervalS":5,"devices":[{"deviceID":%q}]}`, folderID, phoneDir, macID)); err != nil {
		t.Fatal(err)
	}

	waitFor(t, 30*time.Second, func() bool {
		c := decode[map[string]any](t)(phone.ConnectionsJSON())
		conn, _ := c["connections"].(map[string]any)[macID].(map[string]any)
		return conn["connected"] == true
	})

	// Mac → phone.
	if err := os.WriteFile(filepath.Join(macDir, "from-mac.txt"), []byte("hello phone"), 0o644); err != nil {
		t.Fatal(err)
	}
	mac.do(t, "POST", "/rest/db/scan?folder="+folderID, nil)
	waitFor(t, 60*time.Second, func() bool {
		b, err := os.ReadFile(filepath.Join(phoneDir, "from-mac.txt"))
		return err == nil && string(b) == "hello phone"
	})

	// Phone → mac.
	if err := os.WriteFile(filepath.Join(phoneDir, "from-phone.txt"), []byte("hello mac"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := phone.Scan(folderID); err != nil {
		t.Fatal(err)
	}
	waitFor(t, 60*time.Second, func() bool {
		b, err := os.ReadFile(filepath.Join(macDir, "from-phone.txt"))
		return err == nil && string(b) == "hello mac"
	})

	// Completion and events reflect the sync.
	comp := decode[map[string]any](t)(phone.CompletionJSON(folderID, macID))
	if comp["completion"].(float64) < 99.9 {
		t.Fatalf("remote completion %v", comp)
	}
	evs, err := phone.Events(0, 0, 0)
	if err != nil || !strings.Contains(evs, "ItemFinished") {
		t.Fatalf("expected ItemFinished events (err=%v)", err)
	}
}
