package stbridge

import (
	"time"

	"github.com/syncthing/syncthing/lib/protocol"
)

// ConnectionsJSON mirrors GET /rest/system/connections. Per-device byte
// counters aren't reachable from outside the model, so only totals carry
// byte counts.
func (n *Node) ConnectionsJSON() (string, error) {
	app, cfg, err := n.running()
	if err != nil {
		return "", err
	}
	conns := map[string]any{}
	for id, dev := range cfg.Devices() {
		if id == n.myID {
			continue
		}
		ci, _ := n.cache.connection(id.String())
		connected := app.Internals.IsConnectedTo(id)
		entry := map[string]any{
			"connected": connected,
			"paused":    dev.Paused,
		}
		if connected {
			entry["address"] = ci.Address
			entry["clientVersion"] = ci.ClientVersion
			entry["type"] = ci.Type
			entry["startedAt"] = ci.StartedAt
		}
		conns[id.String()] = entry
	}
	in, out := protocol.TotalInOut()
	return marshal(map[string]any{
		"connections": conns,
		"total":       map[string]any{"inBytesTotal": in, "outBytesTotal": out, "at": time.Now()},
	})
}

// FoldersJSON mirrors GET /rest/config/folders.
func (n *Node) FoldersJSON() (string, error) {
	_, cfg, err := n.running()
	if err != nil {
		return "", err
	}
	return marshal(cfg.RawCopy().Folders)
}

// DevicesJSON mirrors GET /rest/config/devices.
func (n *Node) DevicesJSON() (string, error) {
	_, cfg, err := n.running()
	if err != nil {
		return "", err
	}
	return marshal(cfg.RawCopy().Devices)
}

// DefaultFolderJSON mirrors GET /rest/config/defaults/folder.
func (n *Node) DefaultFolderJSON() (string, error) {
	_, cfg, err := n.running()
	if err != nil {
		return "", err
	}
	return marshal(cfg.DefaultFolder())
}

// DefaultDeviceJSON mirrors GET /rest/config/defaults/device.
func (n *Node) DefaultDeviceJSON() (string, error) {
	_, cfg, err := n.running()
	if err != nil {
		return "", err
	}
	return marshal(cfg.DefaultDevice())
}

// FolderStatusJSON mirrors GET /rest/db/status. Uses the latest
// FolderSummary event when available, otherwise computes from the database.
func (n *Node) FolderStatusJSON(folder string) (string, error) {
	app, _, err := n.running()
	if err != nil {
		return "", err
	}
	if s, ok := n.cache.summary(folder); ok {
		return marshal(s)
	}
	summary, err := folderSummary(app, folder, n.cache)
	if err != nil {
		return "", err
	}
	return marshal(summary)
}

func completionMap(pct float64, globalBytes, needBytes int64, globalItems, needItems, needDeletes int, remoteState string) map[string]any {
	return map[string]any{
		"completion":  pct,
		"globalBytes": globalBytes,
		"needBytes":   needBytes,
		"globalItems": globalItems,
		"needItems":   needItems,
		"needDeletes": needDeletes,
		"remoteState": remoteState,
	}
}

// CompletionJSON mirrors GET /rest/db/completion. Empty folder aggregates
// over folders shared with the device; empty device means this device.
func (n *Node) CompletionJSON(folder, device string) (string, error) {
	app, cfg, err := n.running()
	if err != nil {
		return "", err
	}
	devID := protocol.LocalDeviceID
	if device != "" {
		if devID, err = protocol.DeviceIDFromString(device); err != nil {
			return "", err
		}
	}
	var folders []string
	if folder != "" {
		folders = []string{folder}
	} else {
		for id, f := range cfg.Folders() {
			if devID == protocol.LocalDeviceID || f.SharedWith(devID) {
				folders = append(folders, id)
			}
		}
	}
	var gb, nb int64
	var gi, ni, nd int
	state := "unknown"
	for _, f := range folders {
		c, err := app.Internals.Completion(devID, f)
		if err != nil {
			if folder != "" {
				return "", err
			}
			continue
		}
		gb += c.GlobalBytes
		nb += c.NeedBytes
		gi += c.GlobalItems
		ni += c.NeedItems
		nd += c.NeedDeletes
		state = c.RemoteState.String()
	}
	pct := 100.0
	if gb > 0 {
		pct = 100 * (1 - float64(nb)/float64(gb))
	}
	if nb == 0 && nd > 0 {
		pct = 95
	}
	return marshal(completionMap(pct, gb, nb, gi, ni, nd, state))
}

type neededFile struct {
	Name     string    `json:"name"`
	Size     int64     `json:"size"`
	Modified time.Time `json:"modified"`
	Deleted  bool      `json:"deleted"`
}

func toNeeded(fs []protocol.FileInfo) []neededFile {
	out := make([]neededFile, 0, len(fs))
	for _, f := range fs {
		out = append(out, neededFile{Name: f.Name, Size: f.Size, Modified: f.ModTime(), Deleted: f.IsDeleted()})
	}
	return out
}

// NeedJSON mirrors GET /rest/db/need.
func (n *Node) NeedJSON(folder string, page, perPage int) (string, error) {
	app, _, err := n.running()
	if err != nil {
		return "", err
	}
	progress, queued, rest, err := app.Internals.NeedFolderFiles(folder, page, perPage)
	if err != nil {
		return "", err
	}
	return marshal(map[string]any{
		"progress": toNeeded(progress), "queued": toNeeded(queued), "rest": toNeeded(rest),
		"page": page, "perpage": perPage,
	})
}

// FolderErrorsJSON mirrors GET /rest/folder/errors (from FolderErrors events).
func (n *Node) FolderErrorsJSON(folder string) (string, error) {
	return marshal(map[string]any{"folder": folder, "errors": n.cache.errorsFor(folder)})
}

// DeviceStatsJSON mirrors GET /rest/stats/device.
func (n *Node) DeviceStatsJSON() (string, error) {
	app, _, err := n.running()
	if err != nil {
		return "", err
	}
	stats, err := app.Internals.DeviceStatistics()
	if err != nil {
		return "", err
	}
	out := make(map[string]any, len(stats))
	for id, s := range stats {
		out[id.String()] = s
	}
	return marshal(out)
}

// FolderStatsJSON mirrors GET /rest/stats/folder (last scan only).
func (n *Node) FolderStatsJSON() (string, error) {
	out := map[string]any{}
	for id, t := range n.cache.scanTimes() {
		out[id] = map[string]any{"lastScan": t}
	}
	return marshal(out)
}

// PendingDevicesJSON mirrors GET /rest/cluster/pending/devices for devices
// seen since the node started.
func (n *Node) PendingDevicesJSON() (string, error) {
	_, cfg, err := n.running()
	if err != nil {
		return "", err
	}
	out := map[string]pendingDevice{}
	for id, p := range n.cache.pending() {
		if devID, err := protocol.DeviceIDFromString(id); err == nil {
			if _, known := cfg.Device(devID); known {
				continue
			}
		}
		out[id] = p
	}
	return marshal(out)
}

// PendingFoldersJSON mirrors GET /rest/cluster/pending/folders.
func (n *Node) PendingFoldersJSON() (string, error) {
	app, _, err := n.running()
	if err != nil {
		return "", err
	}
	pending, err := app.Internals.PendingFolders(protocol.EmptyDeviceID)
	if err != nil {
		return "", err
	}
	return marshal(pending)
}

// BrowseJSON lists the global (cluster-wide) tree of a folder below prefix,
// mirroring GET /rest/db/browse.
func (n *Node) BrowseJSON(folder, prefix string, levels int) (string, error) {
	app, _, err := n.running()
	if err != nil {
		return "", err
	}
	tree, err := app.Internals.GlobalTree(folder, prefix, levels, false)
	if err != nil {
		return "", err
	}
	return marshal(tree)
}
