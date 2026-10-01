// Package stbridge embeds a Syncthing instance and exposes it to Swift via
// gomobile. Swift sees types prefixed with "Stbridge" (e.g. StbridgeNode).
//
// gomobile restricts signatures to basic types, so structured data crosses
// the boundary as JSON strings. Shapes deliberately mirror Syncthing's REST
// API responses so the Swift models and event reducer can be shared.
package stbridge

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"sync"
	"time"

	"github.com/syncthing/syncthing/lib/build"
	"github.com/syncthing/syncthing/lib/config"
	"github.com/syncthing/syncthing/lib/events"
	"github.com/syncthing/syncthing/lib/locations"
	"github.com/syncthing/syncthing/lib/model"
	"github.com/syncthing/syncthing/lib/protocol"
	"github.com/syncthing/syncthing/lib/svcutil"
	"github.com/syncthing/syncthing/lib/syncthing"
	"github.com/thejerf/suture/v4"
)

// Version is the embedded Syncthing version, set at build time via -ldflags.
var Version = "unknown"

const eventBufferSize = 1000

// Node is one embedded Syncthing device. Create with NewNode, then Start.
// A node may be stopped and started again (e.g. across app backgrounding).
type Node struct {
	configDir     string
	dataDir       string
	defaultFolder string

	// Options applied before every start (tests use it to stay off the
	// default ports); JSON in the same shape as SetOptionsJSON.
	startupOptions string

	mu        sync.Mutex
	cert      tls.Certificate
	myID      protocol.DeviceID
	cancel    context.CancelFunc
	cfg       config.Wrapper
	app       *syncthing.App
	evLogger  events.Logger
	sub       events.BufferedSubscription
	model     model.Model
	summary   model.FolderSummaryService
	startedAt time.Time

}

// NewNode prepares a node whose config, keys and database live under
// configDir/dataDir. New folders default to subdirectories of folderRoot.
// The device certificate is generated on first use.
func NewNode(configDir, dataDir, folderRoot string) (*Node, error) {
	for _, dir := range []string{configDir, dataDir, folderRoot} {
		if err := os.MkdirAll(dir, 0o700); err != nil {
			return nil, fmt.Errorf("create %s: %w", dir, err)
		}
	}
	if err := locations.SetBaseDir(locations.ConfigBaseDir, configDir); err != nil {
		return nil, err
	}
	if err := locations.SetBaseDir(locations.DataBaseDir, dataDir); err != nil {
		return nil, err
	}
	if Version != "unknown" {
		build.Version = Version
	}
	cert, err := syncthing.LoadOrGenerateCertificate(
		filepath.Join(configDir, "cert.pem"), filepath.Join(configDir, "key.pem"))
	if err != nil {
		return nil, fmt.Errorf("device certificate: %w", err)
	}
	return &Node{
		configDir:     configDir,
		dataDir:       dataDir,
		defaultFolder: folderRoot,
		cert:          cert,
		myID:          protocol.NewDeviceID(cert.Certificate[0]),
	}, nil
}

// DeviceID is this node's Syncthing device ID.
func (n *Node) DeviceID() string { return n.myID.String() }

// SetStartupOptionsJSON sets options applied on each Start before Syncthing
// begins listening. Must be called while stopped.
func (n *Node) SetStartupOptionsJSON(optionsJSON string) {
	n.mu.Lock()
	defer n.mu.Unlock()
	n.startupOptions = optionsJSON
}

// IsRunning reports whether Start has completed and Stop hasn't been called.
func (n *Node) IsRunning() bool {
	n.mu.Lock()
	defer n.mu.Unlock()
	return n.app != nil
}

// Start loads config, opens the database and starts syncing. deviceName is
// applied to this device's config entry if it has no name yet.
func (n *Node) Start(deviceName string) error {
	n.mu.Lock()
	defer n.mu.Unlock()
	if n.app != nil {
		return nil
	}

	ctx, cancel := context.WithCancel(context.Background())
	early := suture.New("early", svcutil.SpecWithDebugLogger())
	early.ServeBackground(ctx)

	evLogger := events.NewLogger()
	early.Add(evLogger)

	cfgPath := filepath.Join(n.configDir, "config.xml")
	_, statErr := os.Stat(cfgPath)
	firstRun := os.IsNotExist(statErr)
	cfg, err := syncthing.LoadConfigAtStartup(cfgPath, n.cert, evLogger, false, true)
	if err != nil {
		cancel()
		return fmt.Errorf("config: %w", err)
	}
	early.Add(cfg)
	if err := n.applyMobileDefaults(cfg, deviceName, firstRun); err != nil {
		cancel()
		return fmt.Errorf("config defaults: %w", err)
	}

	// Subscribe before starting so no event is missed.
	sub := events.NewBufferedSubscription(evLogger.Subscribe(defaultEventMask), eventBufferSize)

	sdb, err := syncthing.OpenDatabase(filepath.Join(n.dataDir, "index-v2"), 15*30*24*time.Hour)
	if err != nil {
		cancel()
		return fmt.Errorf("database: %w", err)
	}

	app, err := syncthing.New(cfg, sdb, evLogger, n.cert, syncthing.Options{NoUpgrade: true})
	if err != nil {
		_ = sdb.Close()
		cancel()
		return fmt.Errorf("syncthing: %w", err)
	}
	if err := app.Start(); err != nil {
		_ = sdb.Close()
		cancel()
		return fmt.Errorf("start: %w", err)
	}

	m, err := modelOf(app)
	if err != nil {
		app.Stop(svcutil.ExitError)
		app.Wait()
		cancel()
		return err
	}
	// Syncthing only starts the folder summary service (FolderSummary and
	// FolderCompletion events) together with its web GUI; run it ourselves.
	summary := model.NewFolderSummaryService(cfg, m, n.myID, evLogger)
	early.Add(summary)


	n.cancel = cancel
	n.cfg = cfg
	n.app = app
	n.evLogger = evLogger
	n.sub = sub
	n.model = m
	n.summary = summary
	n.startedAt = time.Now()
	return nil
}

// Stop shuts the node down and waits for it to exit. Safe to call when stopped.
func (n *Node) Stop() {
	n.mu.Lock()
	app, cancel := n.app, n.cancel
	n.app, n.cancel, n.cfg, n.sub, n.evLogger, n.model, n.summary = nil, nil, nil, nil, nil, nil, nil
	n.mu.Unlock()
	if app == nil {
		return
	}
	app.Stop(svcutil.ExitSuccess)
	app.Wait()
	cancel()
}

// applyMobileDefaults enforces settings that make sense for an embedded,
// privacy-respecting mobile node. The web GUI/REST server is disabled (the
// app talks to Syncthing in-process) and telemetry/upgrades are off.
func (n *Node) applyMobileDefaults(cfg config.Wrapper, deviceName string, firstRun bool) error {
	var optErr error
	w, err := cfg.Modify(func(c *config.Configuration) {
		if n.startupOptions != "" {
			optErr = json.Unmarshal([]byte(n.startupOptions), &c.Options)
		}
		c.GUI.Enabled = false
		c.Options.StartBrowser = false
		c.Options.URAccepted = -1
		c.Options.CREnabled = false
		c.Options.AutoUpgradeIntervalH = 0
		if c.Defaults.Folder.Path == "" || c.Defaults.Folder.Path == "~" {
			c.Defaults.Folder.Path = n.defaultFolder
		}
		dev, ok := c.DeviceMap()[n.myID]
		if !ok {
			dev = c.Defaults.Device.Copy()
			dev.DeviceID = n.myID
		}
		if deviceName != "" && (firstRun || dev.Name == "" || dev.Name == "localhost") {
			dev.Name = deviceName
		}
		c.SetDevice(dev)
	})
	if err != nil {
		return err
	}
	if optErr != nil {
		return fmt.Errorf("startup options: %w", optErr)
	}
	w.Wait()
	return cfg.Save()
}

func (n *Node) running() (*syncthing.App, config.Wrapper, error) {
	n.mu.Lock()
	defer n.mu.Unlock()
	if n.app == nil {
		return nil, nil, errors.New("syncthing is not running")
	}
	return n.app, n.cfg, nil
}

func (n *Node) runningModel() (model.Model, config.Wrapper, error) {
	n.mu.Lock()
	defer n.mu.Unlock()
	if n.app == nil {
		return nil, nil, errors.New("syncthing is not running")
	}
	return n.model, n.cfg, nil
}

func marshal(v any) (string, error) {
	b, err := json.Marshal(v)
	if err != nil {
		return "", err
	}
	return string(b), nil
}

// StatusJSON mirrors GET /rest/system/status (subset).
func (n *Node) StatusJSON() (string, error) {
	if _, _, err := n.running(); err != nil {
		return "", err
	}
	var ms runtime.MemStats
	runtime.ReadMemStats(&ms)
	n.mu.Lock()
	started := n.startedAt
	n.mu.Unlock()
	return marshal(map[string]any{
		"myID":          n.myID.String(),
		"uptime":        int(time.Since(started).Seconds()),
		"startTime":     started,
		"pathSeparator": string(filepath.Separator),
		"goroutines":    runtime.NumGoroutine(),
		"alloc":         ms.Alloc,
		"sys":           ms.Sys,
	})
}

// VersionJSON mirrors GET /rest/system/version.
func (n *Node) VersionJSON() (string, error) {
	return marshal(map[string]any{
		"version":     build.Version,
		"longVersion": build.LongVersion,
		"os":          runtime.GOOS,
		"arch":        runtime.GOARCH,
	})
}

// Events mirrors GET /rest/events: events after `since`, blocking up to
// timeoutSeconds when there are none. limit > 0 keeps only the last n.
func (n *Node) Events(since, limit, timeoutSeconds int) (string, error) {
	n.mu.Lock()
	sub := n.sub
	n.mu.Unlock()
	if sub == nil {
		return "", errors.New("syncthing is not running")
	}
	evs := sub.Since(since, nil, time.Duration(timeoutSeconds)*time.Second)
	if limit > 0 && len(evs) > limit {
		evs = evs[len(evs)-limit:]
	}
	if evs == nil {
		evs = []events.Event{}
	}
	return marshal(evs)
}

// Same default as the REST API: everything except per-file disk events.
const defaultEventMask = events.AllEvents &^ events.LocalChangeDetected &^ events.RemoteChangeDetected
