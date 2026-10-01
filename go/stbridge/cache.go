package stbridge

import (
	"context"
	"encoding/json"
	"sync"
	"time"

	"github.com/syncthing/syncthing/lib/events"
)

// eventCache tracks state that Syncthing exposes only through its REST
// layer (which we don't run): per-device connection details, folder error
// lists, latest folder summaries, pending devices and last scan times.
type eventCache struct {
	mu             sync.Mutex
	conns          map[string]connInfo
	folderErrors   map[string]any
	summaries      map[string]any
	pendingDevices map[string]pendingDevice
	lastScan       map[string]time.Time
}

type connInfo struct {
	Address       string    `json:"address"`
	ClientVersion string    `json:"clientVersion"`
	Type          string    `json:"type"`
	StartedAt     time.Time `json:"startedAt"`
}

type pendingDevice struct {
	Time    time.Time `json:"time"`
	Name    string    `json:"name"`
	Address string    `json:"address"`
}

func newEventCache() *eventCache {
	c := &eventCache{}
	c.reset()
	return c
}

func (c *eventCache) reset() {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.conns = map[string]connInfo{}
	c.folderErrors = map[string]any{}
	c.summaries = map[string]any{}
	if c.pendingDevices == nil {
		c.pendingDevices = map[string]pendingDevice{}
	}
	if c.lastScan == nil {
		c.lastScan = map[string]time.Time{}
	}
}

const cacheMask = events.DeviceConnected | events.DeviceDisconnected | events.FolderErrors |
	events.FolderSummary | events.PendingDevicesChanged | events.StateChanged | events.FolderScanProgress

func (c *eventCache) follow(ctx context.Context, logger events.Logger) {
	sub := logger.Subscribe(cacheMask)
	go func() {
		defer sub.Unsubscribe()
		for {
			select {
			case <-ctx.Done():
				return
			case ev, ok := <-sub.C():
				if !ok {
					return
				}
				c.apply(ev)
			}
		}
	}()
}

func str(m map[string]any, key string) string {
	if v, ok := m[key].(string); ok {
		return v
	}
	return ""
}

// normalize converts any event payload to the generic JSON form REST
// clients see, since payload Go types vary (map[string]string, structs, …).
func normalize(data any) map[string]any {
	b, err := json.Marshal(data)
	if err != nil {
		return nil
	}
	var m map[string]any
	if json.Unmarshal(b, &m) != nil {
		return nil
	}
	return m
}

func (c *eventCache) apply(ev events.Event) {
	data := normalize(ev.Data)
	if data == nil {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	switch ev.Type {
	case events.DeviceConnected:
		c.conns[str(data, "id")] = connInfo{Address: str(data, "addr"), ClientVersion: str(data, "clientVersion"),
			Type: str(data, "type"), StartedAt: ev.Time}
	case events.DeviceDisconnected:
		delete(c.conns, str(data, "id"))
	case events.FolderErrors:
		c.folderErrors[str(data, "folder")] = data["errors"]
	case events.FolderSummary:
		c.summaries[str(data, "folder")] = data["summary"]
	case events.StateChanged:
		folder := str(data, "folder")
		if str(data, "from") == "scanning" {
			c.lastScan[folder] = ev.Time
		}
		if str(data, "to") == "syncing" {
			delete(c.folderErrors, folder)
		}
	case events.PendingDevicesChanged:
		added, _ := data["added"].([]any)
		for _, a := range added {
			if m, ok := a.(map[string]any); ok {
				c.pendingDevices[str(m, "deviceID")] = pendingDevice{Time: ev.Time, Name: str(m, "name"), Address: str(m, "address")}
			}
		}
		removed, _ := data["removed"].([]any)
		for _, r := range removed {
			if m, ok := r.(map[string]any); ok {
				delete(c.pendingDevices, str(m, "deviceID"))
			}
		}
	}
}

func (c *eventCache) connection(id string) (connInfo, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	ci, ok := c.conns[id]
	return ci, ok
}

func (c *eventCache) summary(folder string) (any, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	s, ok := c.summaries[folder]
	return s, ok
}

func (c *eventCache) errorsFor(folder string) any {
	c.mu.Lock()
	defer c.mu.Unlock()
	if e, ok := c.folderErrors[folder]; ok && e != nil {
		return e
	}
	return []any{}
}

func (c *eventCache) pending() map[string]pendingDevice {
	c.mu.Lock()
	defer c.mu.Unlock()
	out := make(map[string]pendingDevice, len(c.pendingDevices))
	for k, v := range c.pendingDevices {
		out[k] = v
	}
	return out
}

func (c *eventCache) removePending(id string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	delete(c.pendingDevices, id)
}

func (c *eventCache) scanTimes() map[string]time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	out := make(map[string]time.Time, len(c.lastScan))
	for k, v := range c.lastScan {
		out[k] = v
	}
	return out
}
