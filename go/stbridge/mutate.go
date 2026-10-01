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
	n.cache.removePending(device.DeviceID.String())
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

// IgnoreDevice dismisses a pending device permanently (as the web GUI's "Ignore").
func (n *Node) IgnoreDevice(id string) error {
	devID, err := protocol.DeviceIDFromString(id)
	if err != nil {
		return err
	}
	p := n.cache.pending()[id]
	n.cache.removePending(id)
	return n.modify(func(c *config.Configuration) error {
		c.IgnoredDevices = append(c.IgnoredDevices, config.ObservedDevice{
			Time: time.Now(), ID: devID, Name: p.Name, Address: p.Address,
		})
		return nil
	})
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
