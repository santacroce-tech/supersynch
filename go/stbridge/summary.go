package stbridge

import (
	"context"
	"sync"
	"time"

	"github.com/syncthing/syncthing/lib/config"
	"github.com/syncthing/syncthing/lib/events"
	"github.com/syncthing/syncthing/lib/protocol"
	"github.com/syncthing/syncthing/lib/syncthing"
)

// summaryService re-implements lib/model's folderSummaryService, which
// Syncthing only starts together with its web GUI (disabled here). It emits
// the same FolderSummary and FolderCompletion events, so consumers of the
// event stream can't tell the difference.
type summaryService struct {
	app      *syncthing.App
	cfg      config.Wrapper
	evLogger events.Logger
	myID     protocol.DeviceID
	cache    *eventCache

	mu        sync.Mutex
	dirty     map[string]struct{}
	immediate chan string
}

const summaryMask = events.LocalIndexUpdated | events.RemoteIndexUpdated | events.StateChanged |
	events.RemoteDownloadProgress | events.DeviceConnected | events.ClusterConfigReceived |
	events.FolderWatchStateChanged | events.DownloadProgress

func startSummaryService(ctx context.Context, app *syncthing.App, cfg config.Wrapper, evLogger events.Logger, myID protocol.DeviceID, cache *eventCache) {
	s := &summaryService{
		app: app, cfg: cfg, evLogger: evLogger, myID: myID, cache: cache,
		dirty: map[string]struct{}{}, immediate: make(chan string, 1),
	}
	// Initial summaries for every folder, like the GUI gets on load.
	for id := range cfg.Folders() {
		s.dirty[id] = struct{}{}
	}
	go s.listen(ctx)
	go s.pump(ctx)
}

func (s *summaryService) listen(ctx context.Context) {
	sub := s.evLogger.Subscribe(summaryMask)
	defer sub.Unsubscribe()
	for {
		select {
		case <-ctx.Done():
			return
		case ev, ok := <-sub.C():
			if !ok {
				return
			}
			s.process(ev)
		}
	}
}

func (s *summaryService) markDevice(device string) {
	id, err := protocol.DeviceIDFromString(device)
	if err != nil {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	for fid, f := range s.cfg.Folders() {
		if f.SharedWith(id) {
			s.dirty[fid] = struct{}{}
		}
	}
}

func (s *summaryService) process(ev events.Event) {
	data := normalize(ev.Data)
	switch ev.Type {
	case events.DeviceConnected:
		s.markDevice(str(data, "id"))
		return
	case events.ClusterConfigReceived:
		s.markDevice(str(data, "device"))
		return
	case events.DownloadProgress:
		// Keyed by folder ID.
		s.mu.Lock()
		for folder := range data {
			s.dirty[folder] = struct{}{}
		}
		s.mu.Unlock()
		return
	case events.StateChanged:
		if str(data, "to") != "idle" {
			return
		}
		if from := str(data, "from"); from != "syncing" && from != "sync-preparing" && from != "scanning" {
			return
		}
		// A folder that just finished gets its summary right away.
		folder := str(data, "folder")
		select {
		case s.immediate <- folder:
			s.mu.Lock()
			delete(s.dirty, folder)
			s.mu.Unlock()
			return
		default:
		}
		s.mu.Lock()
		s.dirty[folder] = struct{}{}
		s.mu.Unlock()
	default:
		if folder := str(data, "folder"); folder != "" {
			s.mu.Lock()
			s.dirty[folder] = struct{}{}
			s.mu.Unlock()
		}
	}
}

func (s *summaryService) pump(ctx context.Context) {
	const interval = 2 * time.Second
	timer := time.NewTimer(500 * time.Millisecond)
	defer timer.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case folder := <-s.immediate:
			s.send(ctx, folder)
		case <-timer.C:
			t0 := time.Now()
			s.mu.Lock()
			folders := make([]string, 0, len(s.dirty))
			for f := range s.dirty {
				folders = append(folders, f)
			}
			s.dirty = map[string]struct{}{}
			s.mu.Unlock()
			for _, f := range folders {
				if ctx.Err() != nil {
					return
				}
				s.send(ctx, f)
			}
			timer.Reset(2*time.Since(t0) + interval)
		}
	}
}

func (s *summaryService) send(ctx context.Context, folder string) {
	fcfg, ok := s.cfg.Folders()[folder]
	if !ok {
		return
	}
	summary, err := folderSummary(s.app, folder, s.cache)
	if err != nil {
		return
	}
	s.evLogger.Log(events.FolderSummary, map[string]any{"folder": folder, "summary": summary})

	if fcfg.Paused {
		return
	}
	for _, dev := range fcfg.Devices {
		if ctx.Err() != nil {
			return
		}
		if dev.DeviceID == s.myID {
			continue
		}
		c, err := s.app.Internals.Completion(dev.DeviceID, folder)
		if err != nil {
			continue
		}
		ev := completionMap(c.CompletionPct, c.GlobalBytes, c.NeedBytes, c.GlobalItems, c.NeedItems, c.NeedDeletes, c.RemoteState.String())
		ev["folder"] = folder
		ev["device"] = dev.DeviceID.String()
		ev["sequence"] = c.Sequence
		s.evLogger.Log(events.FolderCompletion, ev)
	}
}

// folderSummary builds the same object as GET /rest/db/status.
func folderSummary(app *syncthing.App, folder string, cache *eventCache) (map[string]any, error) {
	state, changed, stateErr := app.Internals.FolderState(folder)
	global, err := app.Internals.GlobalSize(folder)
	if err != nil {
		return nil, err
	}
	local, err := app.Internals.LocalSize(folder)
	if err != nil {
		return nil, err
	}
	need, err := app.Internals.NeedSize(folder, protocol.LocalDeviceID)
	if err != nil {
		return nil, err
	}
	pullErrors := 0
	if errs, ok := cache.errorsFor(folder).([]any); ok {
		pullErrors = len(errs)
	}
	errText := ""
	if stateErr != nil {
		errText = stateErr.Error()
	}
	return map[string]any{
		"state":             state,
		"stateChanged":      changed,
		"error":             errText,
		"errors":            pullErrors,
		"pullErrors":        pullErrors,
		"globalFiles":       global.Files,
		"globalDirectories": global.Directories,
		"globalSymlinks":    global.Symlinks,
		"globalDeleted":     global.Deleted,
		"globalBytes":       global.Bytes,
		"globalTotalItems":  global.Files + global.Directories + global.Symlinks,
		"localFiles":        local.Files,
		"localDirectories":  local.Directories,
		"localSymlinks":     local.Symlinks,
		"localDeleted":      local.Deleted,
		"localBytes":        local.Bytes,
		"localTotalItems":   local.Files + local.Directories + local.Symlinks,
		"needFiles":         need.Files,
		"needDirectories":   need.Directories,
		"needSymlinks":      need.Symlinks,
		"needDeletes":       need.Deleted,
		"needBytes":         max(need.Bytes, 0),
		"needTotalItems":    need.Files + need.Directories + need.Symlinks,
		"inSyncFiles":       global.Files - need.Files,
		"inSyncBytes":       global.Bytes - need.Bytes,
	}, nil
}
