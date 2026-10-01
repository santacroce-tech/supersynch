package stbridge

import (
	"encoding/json"
	"fmt"
	"time"

	"github.com/syncthing/syncthing/lib/config"
	"github.com/syncthing/syncthing/lib/protocol"
)

func (n *Node) modify(fn func(c *config.Configuration) error) error {
	_, cfg, err := n.running()
	if err != nil {
		return err
	}
	var inner error
	w, err := cfg.Modify(func(c *config.Configuration) { inner = fn(c) })
	if err != nil {
		return err
	}
	if inner != nil {
		return inner
	}
	w.Wait()
	return cfg.Save()
}

// SetFolderJSON adds or replaces a folder. The JSON is applied on top of the
// default folder config, so a partial object is enough.
func (n *Node) SetFolderJSON(folderJSON string) error {
	_, cfg, err := n.running()
	if err != nil {
		return err
	}
	folder := cfg.DefaultFolder()
	if existing, ok := cfg.Folders()[peekID(folderJSON, "id")]; ok {
		folder = existing.Copy()
	}
	if err := json.Unmarshal([]byte(folderJSON), &folder); err != nil {
		return fmt.Errorf("folder: %w", err)
	}
	if folder.ID == "" || folder.Path == "" {
		return fmt.Errorf("folder needs an id and a path")
	}
	if !folder.SharedWith(n.myID) {
		folder.Devices = append(folder.Devices, config.FolderDeviceConfiguration{DeviceID: n.myID})
	}
	return n.modify(func(c *config.Configuration) error {
		c.SetFolder(folder)
		return nil
	})
}

// SetDeviceJSON adds or replaces a device on top of the default device config.
func (n *Node) SetDeviceJSON(deviceJSON string) error {
	_, cfg, err := n.running()
	if err != nil {
		return err
	}
	device := cfg.DefaultDevice()
	if id, err := protocol.DeviceIDFromString(peekID(deviceJSON, "deviceID")); err == nil {
		if existing, ok := cfg.Device(id); ok {
			device = existing.Copy()
		}
	}
	if err := json.Unmarshal([]byte(deviceJSON), &device); err != nil {
		return fmt.Errorf("device: %w", err)
	}
	if device.DeviceID == protocol.EmptyDeviceID {
		return fmt.Errorf("device needs a valid deviceID")
	}
	return n.modify(func(c *config.Configuration) error {
		c.SetDevice(device)
		return nil
	})
}

func peekID(js, key string) string {
	var m map[string]any
	_ = json.Unmarshal([]byte(js), &m)
	s, _ := m[key].(string)
	return s
}

// RemoveFolder deletes a folder from the config. Files on disk are kept.
func (n *Node) RemoveFolder(id string) error {
	return n.modify(func(c *config.Configuration) error {
		folders := c.Folders[:0]
		for _, f := range c.Folders {
			if f.ID != id {
				folders = append(folders, f)
			}
		}
		c.Folders = folders
		return nil
	})
}

// RemoveDevice deletes a remote device from the config.
func (n *Node) RemoveDevice(id string) error {
	devID, err := protocol.DeviceIDFromString(id)
	if err != nil {
		return err
	}
	if devID == n.myID {
		return fmt.Errorf("can't remove this device")
	}
	return n.modify(func(c *config.Configuration) error {
		devices := c.Devices[:0]
		for _, d := range c.Devices {
			if d.DeviceID != devID {
				devices = append(devices, d)
			}
		}
		c.Devices = devices
		for i := range c.Folders {
			kept := c.Folders[i].Devices[:0]
			for _, fd := range c.Folders[i].Devices {
				if fd.DeviceID != devID {
					kept = append(kept, fd)
				}
			}
			c.Folders[i].Devices = kept
		}
		return nil
	})
}

// SetFolderPaused pauses or resumes a folder.
func (n *Node) SetFolderPaused(id string, paused bool) error {
	return n.modify(func(c *config.Configuration) error {
		for i := range c.Folders {
			if c.Folders[i].ID == id {
				c.Folders[i].Paused = paused
				return nil
			}
		}
		return fmt.Errorf("no folder %q", id)
	})
}

// SetDevicePaused pauses or resumes one device, or all remote devices when id is empty.
func (n *Node) SetDevicePaused(id string, paused bool) error {
	var target protocol.DeviceID
	if id != "" {
		var err error
		if target, err = protocol.DeviceIDFromString(id); err != nil {
			return err
		}
	}
	return n.modify(func(c *config.Configuration) error {
		for i := range c.Devices {
			d := c.Devices[i].DeviceID
			if d == n.myID {
				continue
			}
			if id == "" || d == target {
				c.Devices[i].Paused = paused
			}
		}
		return nil
	})
}

// Scan rescans one folder, or all folders when id is empty.
func (n *Node) Scan(id string) error {
	app, _, err := n.running()
	if err != nil {
		return err
	}
	if id == "" {
		for f, err := range app.Internals.ScanFolders() {
			if err != nil {
				return fmt.Errorf("%s: %w", f, err)
			}
		}
		return nil
	}
	return app.Internals.ScanFolderSubdirs(id, nil)
}

// IgnoreDevice permanently ignores a pending device (web GUI "Ignore").
func (n *Node) IgnoreDevice(id string) error {
	devID, err := protocol.DeviceIDFromString(id)
	if err != nil {
		return err
	}
	m, _, err := n.runningModel()
	if err != nil {
		return err
	}
	pending, _ := m.PendingDevices()
	p := pending[devID]
	if err := n.modify(func(c *config.Configuration) error {
		c.IgnoredDevices = append(c.IgnoredDevices, config.ObservedDevice{
			Time: time.Now(), ID: devID, Name: p.Name, Address: p.Address,
		})
		return nil
	}); err != nil {
		return err
	}
	return m.DismissPendingDevice(devID)
}

// DismissPendingDevice forgets a pending device request; it reappears if the
// device connects again (DELETE /rest/cluster/pending/devices).
func (n *Node) DismissPendingDevice(id string) error {
	devID, err := protocol.DeviceIDFromString(id)
	if err != nil {
		return err
	}
	m, _, err := n.runningModel()
	if err != nil {
		return err
	}
	return m.DismissPendingDevice(devID)
}

// DismissPendingFolder forgets a folder offer from one device, or from all
// devices when deviceID is empty (DELETE /rest/cluster/pending/folders).
func (n *Node) DismissPendingFolder(folderID, deviceID string) error {
	devID := protocol.EmptyDeviceID
	if deviceID != "" {
		var err error
		if devID, err = protocol.DeviceIDFromString(deviceID); err != nil {
			return err
		}
	}
	m, _, err := n.runningModel()
	if err != nil {
		return err
	}
	return m.DismissPendingFolder(devID, folderID)
}

// IgnoreFolder dismisses a folder offered by a device.
func (n *Node) IgnoreFolder(folderID, label, deviceID string) error {
	devID, err := protocol.DeviceIDFromString(deviceID)
	if err != nil {
		return err
	}
	return n.modify(func(c *config.Configuration) error {
		for i := range c.Devices {
			if c.Devices[i].DeviceID == devID {
				c.Devices[i].IgnoredFolders = append(c.Devices[i].IgnoredFolders,
					config.ObservedFolder{Time: time.Now(), ID: folderID, Label: label})
				return nil
			}
		}
		return fmt.Errorf("unknown device %s", deviceID)
	})
}

// SetDeviceName renames this device.
func (n *Node) SetDeviceName(name string) error {
	return n.modify(func(c *config.Configuration) error {
		for i := range c.Devices {
			if c.Devices[i].DeviceID == n.myID {
				c.Devices[i].Name = name
			}
		}
		return nil
	})
}

// OptionsJSON returns the options config (GET /rest/config/options).
func (n *Node) OptionsJSON() (string, error) {
	_, cfg, err := n.running()
	if err != nil {
		return "", err
	}
	return marshal(cfg.Options())
}

// SetOptionsJSON applies a partial options object (PATCH /rest/config/options).
func (n *Node) SetOptionsJSON(optionsJSON string) error {
	return n.modify(func(c *config.Configuration) error {
		return json.Unmarshal([]byte(optionsJSON), &c.Options)
	})
}

// FolderVersionsJSON mirrors GET /rest/folder/versions: archived versions
// per file path for folders with versioning enabled.
func (n *Node) FolderVersionsJSON(folder string) (string, error) {
	m, _, err := n.runningModel()
	if err != nil {
		return "", err
	}
	versions, err := m.GetFolderVersions(folder)
	if err != nil {
		return "", err
	}
	return marshal(versions)
}

// RestoreVersionsJSON mirrors POST /rest/folder/versions. The input maps
// file paths to the versionTime to restore; the result maps paths to errors.
func (n *Node) RestoreVersionsJSON(folder, versionsJSON string) (string, error) {
	m, _, err := n.runningModel()
	if err != nil {
		return "", err
	}
	var versions map[string]time.Time
	if err := json.Unmarshal([]byte(versionsJSON), &versions); err != nil {
		return "", fmt.Errorf("versions: %w", err)
	}
	failed, err := m.RestoreFolderVersions(folder, versions)
	if err != nil {
		return "", err
	}
	out := make(map[string]string, len(failed))
	for path, e := range failed {
		out[path] = e.Error()
	}
	return marshal(out)
}

// IgnoresJSON mirrors GET /rest/db/ignores: {"ignore": [...], "expanded": [...]}.
func (n *Node) IgnoresJSON(folder string) (string, error) {
	m, _, err := n.runningModel()
	if err != nil {
		return "", err
	}
	lines, expanded, err := m.LoadIgnores(folder)
	if err != nil {
		return "", err
	}
	if lines == nil {
		lines = []string{}
	}
	if expanded == nil {
		expanded = []string{}
	}
	return marshal(map[string]any{"ignore": lines, "expanded": expanded})
}

// SetIgnoresJSON mirrors POST /rest/db/ignores with a JSON array of lines.
func (n *Node) SetIgnoresJSON(folder, linesJSON string) error {
	app, _, err := n.running()
	if err != nil {
		return err
	}
	var lines []string
	if err := json.Unmarshal([]byte(linesJSON), &lines); err != nil {
		return fmt.Errorf("ignores: %w", err)
	}
	return app.Internals.SetIgnores(folder, lines)
}

// Override makes a send-only folder's local state authoritative
// (POST /rest/db/override).
func (n *Node) Override(folder string) error {
	m, _, err := n.runningModel()
	if err != nil {
		return err
	}
	m.Override(folder)
	return nil
}

// Revert discards local changes in a receive-only folder (POST /rest/db/revert).
func (n *Node) Revert(folder string) error {
	m, _, err := n.runningModel()
	if err != nil {
		return err
	}
	m.Revert(folder)
	return nil
}
