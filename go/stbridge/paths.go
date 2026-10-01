package stbridge

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// iOS moves an app's data container to a new path (new UUID) when the app is
// reinstalled or updated, e.g.
//
//	/var/mobile/Containers/Data/Application/<UUID>/Documents/Sync
//
// Absolute folder paths stored in config.xml then point at a container that
// no longer exists ("folder path missing"), even though the files were
// migrated. Syncthing expands "~" to $HOME (the current container) whenever
// it opens a folder, so paths inside the container are stored as "~/…".

var containerPrefix = regexp.MustCompile(`^.*/Containers/Data/Application/[0-9A-Fa-f-]{36}(/|$)`)

// portablePath rewrites a path inside any app data container (current or a
// previous one) to the "~/…" form. Other paths are returned unchanged.
func portablePath(p string) string {
	if p == "" || strings.HasPrefix(p, "~") {
		return p
	}
	if loc := containerPrefix.FindStringIndex(p); loc != nil {
		rest := strings.TrimSuffix(p[loc[1]:], "/")
		if rest == "" {
			return "~"
		}
		return "~/" + rest
	}
	if home, err := os.UserHomeDir(); err == nil && home != "" {
		home = filepath.Clean(home)
		if p == home {
			return "~"
		}
		if strings.HasPrefix(p, home+"/") {
			return "~/" + strings.TrimPrefix(p, home+"/")
		}
	}
	return p
}
